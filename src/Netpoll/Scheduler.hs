-- Scheduler.hs
{-
Scheduler
---------
This maintains one or more schedules,
where a schedule is just a list of poll requests,
all with the same poll interval.
The idea is that each request is in the list once,
and the poller traverses the entire list once each poll cycle.

So we might have schedules at: 30s, 60s, 300s, 3600s, 1day

Each schedule could be a array of lists;
each element in the array is a timeslice (1 sec?) of
the poll period, and the list is the set of polls
which must be done in this timeslice.
The array gives us O(1) (or is it O(log n)?) indexing,
which is important for selecting the current poll request.

For each schedule we need to keep track of the last position
from which requests were sent, so that we know exactly
which bins to include between then and now.

We also want a way to constrain the range of slots a request
can go in. For Adva binned data we do not want to send a
request for the most recent bin at the end of the poll cycle
i.e. just as the bins are about to roll over. So we need to
allow clients to specify a range of bins which are acceptable.
Some clients may want the poll to happen at a specific time
in the cycle e.g. as close as possible to the start.

Database design
---------------
schedule:
PK: interval, slot
  0 <= slot < interval

-- To enforce that a request may only be in a single
-- slot we could use this structure:
request_slot:
PK: request_id
  (interval, slot) FK to schedule
  0 <= slot < interval

request:
PK: request_id
address, auth_token, routing_token, poller_type,
interval, timeout, retries

request_measurement:
PK: request_id, dataseries_id
calculator
  request_id FK to request

request_measurement_value:
PK: request_id, dataseries_id, value
  (request_id, dataseries_id) FK to request_measurement
-}

module Netpoll.Scheduler where

import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TVar as TVar
import qualified Control.Concurrent.STM.TBQueue as TBQueue
import qualified Data.Array.IO as IOArray
import qualified Data.Foldable as Foldable
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Time.Clock.POSIX as POSIX
import qualified Data.Traversable as Traversable
import qualified Data.Word as Word

import qualified Netpoll.Poller as Poller


-- A schedule is a pair of the last slot sent and an array of slots.
-- We have a TVar around the last slot sent as it will be updated constantly.
-- The schedule array will be updated when new requests are submitted.
-- Do we need TVars if the entire scheduler runs in a single thread?
-- Perhaps they should just be IORefs.
-- Wrap the PollRequest list in a TVar so we can ensure
-- only one thread at a time can update a given slot.
type SlotArray = IOArray.IOArray Word.Word16 (TVar.TVar [Poller.PollRequest])
-- (last slot sent, IO array)
newtype Schedule = Schedule (TVar.TVar Word.Word16, SlotArray)
-- Map from frequency (seconds) to Schedules.
-- Only updated when a new frequency is introduced.
newtype Schedules = Schedules
    (TVar.TVar (Map.Map Word.Word16 Schedule))


-- If the request interval already exists in the map,
-- then we need to search the array for the best slot
-- (subject to any constraints in the request).
-- If it does not exist then we could:
--   1. make a new schedule
--   2. reject if it is not one of the existing schedules
-- Hard to say which behaviour should be supported.
-- Also add to database.
--
-- What do we do when the request is already in the schedule?
-- If we can then we should just replace it in-place.
-- However, if the replacement request has different constraints
-- that demand a different slot then we must delete
-- and re-insert.
-- It is possible that the request has changed its frequency,
-- so we'll have to search all schedules for it.
addRequestToSchedules :: Schedules -> Poller.PollRequest -> IO ()
addRequestToSchedules schedules request = do
    let Schedules tvar = schedules
    schedMap <- TVar.readTVarIO tvar
    let interval = Poller.requestInterval request
    case Map.lookup interval schedMap of
        Nothing -> do
            s <- createSchedule interval
            STM.atomically (TVar.modifyTVar' tvar (Map.insert interval s))
            addRequestToSchedule request s
        Just schedule -> do
            deleteRequestFromSchedules request schedules
            addRequestToSchedule request schedule


createSchedule :: Word.Word16 -> IO Schedule
createSchedule interval = do
    tvars <- Traversable.mapM
        (STM.atomically . TVar.newTVar)
        (replicate (fromIntegral interval) [])
    a <- IOArray.newListArray (0, interval - 1) tvars
    tvarLastSlot <- STM.atomically (TVar.newTVar 0)
    return (Schedule (tvarLastSlot, a))


-- Remove from array and database.
-- FIXME also delete from database
deleteRequestFromSchedules :: Poller.PollRequest -> Schedules -> IO ()
deleteRequestFromSchedules request schedules = do
    let Schedules tvar = schedules
    schedMap <- TVar.readTVarIO tvar
    -- for each frequency
    Foldable.mapM_
        (deleteRequestFromSchedule request)
        (Map.elems schedMap)
    return ()


deleteRequestFromSchedule :: Poller.PollRequest -> Schedule -> IO ()
deleteRequestFromSchedule request schedule = do
    let Schedule (tvLastSlot, slots) = schedule
    (l, u) <- IOArray.getBounds slots
    del slots [l..u]
    where
    -- iterate over the slots, but stop when we find one containing
    -- our schedule.
    del slots [] = return ()
    del slots (i:is) = do
        tvpolls <- IOArray.readArray slots i
        found <- STM.atomically ( do
            polls <- TVar.readTVar tvpolls
            let fpolls = filter (\r -> Poller.requestId request == Poller.requestId r) polls
            if List.length polls /= List.length fpolls
                -- only update the TVar if we've removed something from the list
                then TVar.writeTVar tvpolls fpolls >> return True
                else return False
            )
        if found
            then return ()
            else del slots is


-- Loop over the range of slots that the request allows.
-- Remember the slot with the least polls.
-- Assumes request not already in schedule.
-- FIXME also add to database
addRequestToSchedule :: Poller.PollRequest -> Schedule -> IO ()
addRequestToSchedule request schedule = do
    let Schedule (tvLastSlot, slots) = schedule
    -- Establish the range of slots to search: the intersection
    -- of the request bounds and the array bounds.
    (arrl, arru) <- IOArray.getBounds slots
    let (reql, requ) = Poller.requestIntervalRange request
    let (l, u) = (max arrl reql, min arru requ)
    minSlot <- findMinSlot maxBound l slots [l..u]
    tvpolls <- IOArray.readArray slots minSlot
    STM.atomically (TVar.modifyTVar' tvpolls (request:))
    where
    findMinSlot m s slots [] = return m
    findMinSlot m s slots (i:is) = do
        polls <- IOArray.readArray slots i >>= TVar.readTVarIO
        let l = fromIntegral (List.length polls)
        if l > m
        then findMinSlot m s slots is
        -- this current slot is best so far
        else findMinSlot l i slots is


getPOSIXSecs :: IO Int
getPOSIXSecs = do
    -- getPOSIXTime returns a (large) real,
    -- which is a number of seconds since 1970-01-01.
    ptime <- POSIX.getPOSIXTime
    -- should we round, floor, or ceiling?
    return (round ptime)


-- We'll run the schedules by taking the current time as posix seconds
-- and takng mod poll-frequency of it to get the current slot.
-- Then we send any polls between now (the current slot)
-- and the last one sent.
--
-- As the posix day is always 86400 seconds long, the rem == 0
-- position should always be at a natural boundary.
-- e.g. for a poll frequency of 900s (15 mins) when now is a multiple
-- of 900 (i.e. now `mod` 900 == 0) then the time will be one of
-- [hh:00:00, hh:15:00, hh:30:00, hh:45:00].
tick :: Schedules -> TBQueue.TBQueue Poller.PollRequest -> IO ()
tick schedules requestQueue = do
    now <- getPOSIXSecs
    let Schedules tvar = schedules
    schedMap <- TVar.readTVarIO tvar
    -- for each frequency
    Foldable.mapM_
        (\(i, s) -> tickSchedule requestQueue now i s)
        (Map.assocs schedMap)


dropPollsOlderThanSecs :: Int
dropPollsOlderThanSecs = 10


-- If last is more than dropPollsOlderThanSecs slots behind slot,
-- then advance it to slot - dropPollsOlderThanSecs,
-- effectively dropping polls.
dropOldPolls :: Word.Word16 -> Word.Word16 -> Word.Word16 -> Word.Word16
dropOldPolls interval lastSlot slot =
    let d = (fromIntegral slot - fromIntegral lastSlot) `mod` fromIntegral interval
    in
    if d < dropPollsOlderThanSecs
    then lastSlot + 1
    else fromIntegral ((fromIntegral slot - dropPollsOlderThanSecs) `mod` fromIntegral interval)


-- If interval has rolled over (wrapped) then go from last to end,
-- then start to current.
slotsToPoll :: Word.Word16 -> Word.Word16 -> Word.Word16 -> [Word.Word16]
slotsToPoll interval start slot =
    if slot < start
    then [start .. (interval - 1)] ++ [0 .. slot]
    else [start .. slot]


tickSchedule :: TBQueue.TBQueue Poller.PollRequest -> Int -> Word.Word16 -> Schedule -> IO ()
tickSchedule requestQueue now interval schedule = do
    let slot = fromIntegral (now `mod` (fromIntegral interval))
    let Schedule (tvLastSlot, slots) = schedule
    lastSlot <- TVar.readTVarIO tvLastSlot
    -- If the difference between last and current is too large
    -- (>10s say) then discard the older polls.
    let start = dropOldPolls interval lastSlot slot
    Foldable.mapM_
        (sendSlotPolls requestQueue slots)
        (slotsToPoll interval start slot)
    STM.atomically (TVar.writeTVar tvLastSlot slot)


sendSlotPolls :: TBQueue.TBQueue Poller.PollRequest -> SlotArray -> Word.Word16 -> IO ()
sendSlotPolls requestQueue slots slot = do
    tvpolls <- IOArray.readArray slots slot
    STM.atomically (
        TVar.readTVar tvpolls >>=
        Foldable.mapM_ (TBQueue.writeTBQueue requestQueue)
        )
