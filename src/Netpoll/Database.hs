{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Netpoll.Database where

import qualified Data.Foldable as Foldable
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Data.Monoid as Monoid
import qualified Data.Word as Word
import qualified Database.PostgreSQL.Simple as Postgres
import qualified Database.PostgreSQL.Simple.FromRow as FromRow
import qualified Database.PostgreSQL.Simple.FromField as FromField

import qualified Netpoll.Poller as Poller


infixr 4 <>
(<>) :: Monoid.Monoid m => m -> m -> m
(<>) = Monoid.mappend


{-
-- Object names below 32 chars just in case we ever want to port to oracle.
-- In practice this means table names are 28 chars or less.

-- schema:
create role netpoll login password 'netpoll' creatdb;

create database netpoll with owner = netpoll encoding = 'UTF8';

-------------
-- Scheduler
-------------

create table schedule
( interval int not null
, constraint schedule_pk
    primary key (interval)
);

create table sched_slot
( interval int not null
, slot int not null
, constraint sched_slot_pk
    primary key (interval, slot)
, constraint sched_slot_ck1 check
    (slot >= 0 and slot < interval)
, constraint sched_slot_fk1
    foreign key (interval)
    references schedule (interval)
);

create table sched_request
( request_id text not null
, address text not null
, auth_token text not null
, routing_token text not null
, poller_type text not null
, interval int not null
, timeout int not null
, retries int not null
, constraint sched_request_pk
    primary key (request_id)
);

-- ensures that a request can only go in one slot
create table sched_request_slot
( request_id text not null
, interval int not null
, slot int not null
, constraint sched_request_slot_pk
    primary key (request_id, interval, slot)
, constraint sched_request_slot_fk1
    foreign key (request_id)
    references sched_request (request_id)
, constraint sched_request_slot_fk2
    foreign key (interval, slot)
    references sched_slot (interval, slot)
);

-- list of dataseries (measurements) for a given request
create table sched_request_measure
( request_id text not null
, dataseries_id int not null
, calculator text not null
, constraint sched_request_measure_pk
    primary key (request_id, dataseries_id)
, constraint sched_request_measure_fk1
    foreign key (request_id)
    references sched_request (request_id)
);

-- list of oids for a given measurement
create table sched_request_measure_val
( request_id text not null
, dataseries_id int not null
, position int not null
, value text not null
, constraint sched_request_measure_val_pk
    primary key (request_id, dataseries_id)
, constraint sched_request_measure_val_fk1
    foreign key (request_id, dataseries_id)
    references sched_request_measure (request_id, dataseries_id)
);


-------------
-- Datastore
-------------

Partitions:
  - highres: by day
  - 15min/hourly: by month
  - daily: not at all

The table structures:
  - highres:
        dataseries_id :: int
        ts :: timestamp
        value :: double
        valid_ind :: int

  - lowres:
        dataseries_id :: int
        start_ts :: timestamp
        end_ts :: timestamp
        cnt :: int
        avg :: double
        sum :: double
        max :: double
        min :: double
        stddev :: double

Tables could be called:
   - measure_highres
   - measure_15min
   - measure_hourly
   - measure_daily

create table measure_highres
( dataseries_id int not null
, ts timestamp with time zone not null
, value double not null
, valid_ind int not null
, constraint measure_highres_pk
    primary key (dataseries_id, ts)
);

create index measure_highres_ts_ix1 on measure_highres(ts);

create table measure_15min
( dataseries_id int not null
, start_ts timestamp with time zone not null
, end_ts timestamp with time zone not null
, cnt int not null
, avg double not null
, sum double not null
, min double not null
, max double not null
, stddev double not null
, constraint measure_15min_pk
    primary key (dataseries_id, ts)
);

create index measure_15min_start_ts on measure_15min(start_ts);

create table measure_highres_20150101 inherits measure_highres
    check (ts >= to_timestamp('2015-01-01', 'yyyy-mm-dd')
        and ts < to_timestamp('2015-01-02', 'yyyy-mm-dd') )
;

create table measure_15min_201501 inherits measure_15min
    check (start_ts >= to_timestamp('2015-01-01', 'yyyy-mm-dd')
        and start_ts < to_timestamp('2015-01-02', 'yyyy-mm-dd') )
;
-}


getSchedules :: Postgres.Connection -> IO [Word.Word16]
getSchedules conn = do
    let stmt = "select interval from schedule order by interval"
    is <- Postgres.query_ conn stmt
    return (map fromIntegral (List.concat is::[Int]))


type SlotRequests = (Word.Word16, [Poller.PollRequest])

-- For a given interval, return the slots and all of the requests
-- in each slot.
getRequestsForInterval :: Postgres.Connection -> Word.Word16 -> IO [SlotRequests]
getRequestsForInterval conn interval = do
    let stmt = "select "
            <> "  ss.slot "
            <> ", sr.request_id "
            <> ", srm.dataseries_id "
            <> ", srm.calculator "
            <> ", srmv.position "
            <> ", srmv.value "
            <> ", sr.address "
            <> ", sr.auth_token "
            <> ", sr.routing_token "
            <> ", sr.poller_type "
            <> ", sr.interval "
            <> ", sr.timeout "
            <> ", sr.retries "
            <> "from sched_slot ss "
            <> "join sched_request_slot srs on 1=1 "
            <> "    and srs.interval = ss.interval "
            <> "    and srs.slot = ss.slot "
            <> "join sched_request sr on 1=1 "
            <> "    and sr.request_id = srs.request_id "
            <> "join sched_request_measure srm on 1=1 "
            <> "    and srm.request_id = sr.request_id "
            <> "join sched_request_measure_val srmv on 1=1 "
            <> "    and srmv.request_id = srm.request_id "
            <> "    and srmv.dataseries_id = srm.dataseries_id "
            <> "where ss.interval = ? "
            <> "order by 1 desc, 2 desc, 3 desc, 5 desc "
    let initial = ([], (-1, [])) :: ([SlotRequests], SlotRequests)
    (results, last) <- Postgres.fold conn stmt [interval] initial processRequests
    return (last:results)


type ReqQueryTuple =
    ( Int  -- slot
    , String  -- req-id
    , Int  -- ds-id
    , String  -- calculator
    , Int  -- position
    , String  -- value
    , String  -- address
    , String  -- auth-token
    , String  -- routing-token
    , String  -- poller-type
    , Int  -- interval
    , Int  -- timeout
    , Int  -- retries
    )

-- add FromRow instances for 11-13 columns

instance
    ( FromField.FromField a, FromField.FromField b, FromField.FromField c
    , FromField.FromField d, FromField.FromField e, FromField.FromField f
    , FromField.FromField g, FromField.FromField h, FromField.FromField i
    , FromField.FromField j, FromField.FromField k
    ) => FromRow.FromRow (a,b,c,d,e,f,g,h,i,j,k) where
    fromRow = (,,,,,,,,,,)
        <$> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field


instance
    ( FromField.FromField a, FromField.FromField b, FromField.FromField c
    , FromField.FromField d, FromField.FromField e, FromField.FromField f
    , FromField.FromField g, FromField.FromField h, FromField.FromField i
    , FromField.FromField j, FromField.FromField k, FromField.FromField l
    ) => FromRow.FromRow (a,b,c,d,e,f,g,h,i,j,k,l) where
    fromRow = (,,,,,,,,,,,)
        <$> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field


instance
    ( FromField.FromField a, FromField.FromField b, FromField.FromField c
    , FromField.FromField d, FromField.FromField e, FromField.FromField f
    , FromField.FromField g, FromField.FromField h, FromField.FromField i
    , FromField.FromField j, FromField.FromField k, FromField.FromField l
    , FromField.FromField m
    ) => FromRow.FromRow (a,b,c,d,e,f,g,h,i,j,k,l,m) where
    fromRow = (,,,,,,,,,,,,)
        <$> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field <*> FromRow.field <*> FromRow.field
        <*> FromRow.field


-- prev holds what's been built of the current SlotRequests so far.
-- 1. If the current slot differs from the previous then push the
-- previous SlotRequests onto the list and make a new one.
--
-- 2. If the current request-id differs from the previous then make
-- a new PollRequest and prefix it to the list in prev.
--
-- 3. If the current dataseries-id differs from previous then make
-- a new tuple and prefix it to the measurements list.
--
-- 4. Finally, it's just another value, so prefix it to the value list.
processRequests :: ([SlotRequests], SlotRequests) -> ReqQueryTuple -> IO ([SlotRequests], SlotRequests)
processRequests (results, prevSr@(prevSlot, prevReqs)) row = do
    let slot = getSlot row
    let prevRequestId = if List.null prevReqs then Nothing else (Just (Poller.requestId (head prevReqs)))
    let prevDataseriesId :: Maybe Int
        prevDataseriesId = if List.null prevReqs then Nothing
            else let rms = Poller.requestMeasurements (head prevReqs) in
                if List.null rms then Nothing
                else (Just ((\(d,_,_) -> d) (head rms)))
    case () of
            -- first row
        _ | prevSlot == -1 -> return ([], makeSlotRequest row)
            -- 1. change of slot - the only time we accumulate to the results list
          | slot /= prevSlot -> return (prevSr:results, makeSlotRequest row)
            -- 2. change of request-id
          | getRequestId row /= Maybe.fromJust prevRequestId -> do
                let (_, [pr]) = makeSlotRequest row
                return (results, (prevSlot, pr:prevReqs))
            -- 3. change of dataseries-id
          | getDataseriesId row /= Maybe.fromJust prevDataseriesId -> do
                let m = makeMeasurement row
                -- prefix new measure to list in first request.
                -- This means building a new request to replace it.
                let (r1:rs) = prevReqs
                let ms = Poller.requestMeasurements r1
                let r2 = r1 { Poller.requestMeasurements = m:ms }
                return (results, (prevSlot, r2:rs))
            -- 4. another value
          | otherwise -> do
                -- prefix new value to list in first measurement.
                -- This means recreating the first measurement and
                -- the first request.
                let (_,_,[v]) = makeMeasurement row
                let (r1:rs) = prevReqs
                let (m1:ms) = Poller.requestMeasurements r1
                let (dsId, calc, vals) = m1
                let m2 = (dsId, calc, v:vals)
                let r2 = r1 { Poller.requestMeasurements = m2:ms }
                return (results, (prevSlot, r2:rs))


getSlot :: ReqQueryTuple -> Word.Word16
getSlot (a,b,c,d,e,f,g,h,i,j,k,l,m) = fromIntegral a


getRequestId :: ReqQueryTuple -> String
getRequestId (a,b,c,d,e,f,g,h,i,j,k,l,m) = b


getDataseriesId :: ReqQueryTuple -> Int
getDataseriesId (a,b,c,d,e,f,g,h,i,j,k,l,m) = c


makeSlotRequest :: ReqQueryTuple -> SlotRequests
makeSlotRequest row@
    ( rowSlot
    , rowReqId
    , rowDsId
    , rowCalc
    , rowPos
    , rowVal
    , rowAddr
    , rowAuth
    , rowRoute
    , rowPoller
    , rowInterval
    , rowTimeout
    , rowRetries
    ) =
    let pr = Poller.PollRequest
            { Poller.requestId = rowReqId
            , Poller.requestAddress = rowAddr
            , Poller.requestAuthToken = rowAuth
            , Poller.requestRoutingToken = rowRoute
            , Poller.requestPollerType = rowPoller
            , Poller.requestInterval = fromIntegral rowInterval
            , Poller.requestIntervalRange = (0, fromIntegral rowInterval - 1)
            , Poller.requestTimeout = fromIntegral rowTimeout
            , Poller.requestRetries = fromIntegral rowRetries
            , Poller.requestNextTimeout = 0
            , Poller.requestMeasurements = [makeMeasurement row]
            }
    in (fromIntegral rowSlot, [pr])


makeMeasurement :: ReqQueryTuple -> (Int, String, [String])
makeMeasurement
    ( rowSlot
    , rowReqId
    , rowDsId
    , rowCalc
    , rowPos
    , rowVal
    , rowAddr
    , rowAuth
    , rowRoute
    , rowPoller
    , rowInterval
    , rowTimeout
    , rowRetries
    ) = (rowDsId, rowCalc, [rowVal])


createSchedule :: Postgres.Connection -> Word.Word16 -> IO ()
createSchedule conn interval = do
    Postgres.begin conn

    let stmt = "insert into schedule (interval) values (?)"
    _ <- Postgres.execute conn stmt [interval]

    let stmt = "insert into sched_slot (interval, slot) values (?, ?)"
    let bindvals = [(interval, s) | s <- [0..(interval - 1)]]
    _ <- Postgres.executeMany conn stmt bindvals

    Postgres.commit conn


addRequestToSchedule :: Postgres.Connection -> Word.Word16 -> Word.Word16 -> Poller.PollRequest -> IO ()
addRequestToSchedule conn interval slot req = do
    let reqId = Poller.requestId req

    Postgres.begin conn

    let stmt = "insert into sched_request "
            <> "(request_id, address, auth_token, routing_token,"
            <> " poller_type, interval, timeout, retries)"
            <> " values (?, ?, ?, ?, ?, ?, ?, ?)"
    let bindvals =
            ( Poller.requestId req
            , Poller.requestAddress req
            , Poller.requestAuthToken req
            , Poller.requestRoutingToken req
            , Poller.requestPollerType req
            , Poller.requestInterval req
            , Poller.requestTimeout req
            , Poller.requestRetries req
            )
    _ <- Postgres.execute conn stmt bindvals

    let stmt = "insert into sched_request_measure "
            <> "(request_id, dataseries_id, calculator) "
            <> "values (?, ?, ?)"
    let stmt2 = "insert into sched_request_measure_val "
            <> "(request_id, dataseries_id, position, value) "
            <> "values (?, ?, ?, ?)"
    Foldable.forM_ (Poller.requestMeasurements req) $ \(dsId, calc, oids) -> do
        _ <- Postgres.execute conn stmt (reqId, dsId, calc)
        Foldable.forM_ (zip oids [1..]) $ \(oid, pos::Int) -> do
            _ <- Postgres.execute conn stmt2 (reqId, dsId, pos, oid)
            return ()

    let stmt = "insert into sched_request_slot (request_id, interval, slot) values (?, ?, ?)"
    _ <- Postgres.execute conn stmt (reqId, interval, slot)

    Postgres.commit conn


deleteRequestFromSchedules conn req = do
    let reqId = Poller.requestId req

    Postgres.begin conn

    let stmt = "delete from sched_request_measure_val where request_id = ?"
    _ <- Postgres.execute conn stmt [reqId]

    let stmt = "delete from sched_request_measure where request_id = ?"
    _ <- Postgres.execute conn stmt [reqId]

    let stmt = "delete from sched_request_slot where request_id = ?"
    _ <- Postgres.execute conn stmt [reqId]

    let stmt = "delete from sched_request where request_id = ?"
    _ <- Postgres.execute conn stmt [reqId]

    Postgres.commit conn


insertHighResValue conn res = do
    let stmt = "insert into measure_highres "
            <> "(dataseries_id, ts, value, valid_ind)"
            <> " values (?, to_timestamp(?), ?, ?)"
    let valid_ind = Poller.resultErrorCode res
    let bindvals =
            ( Poller.resultDataseriesId res
            , Poller.resultTimestamp res
            , Poller.resultValue res
            , valid_ind
            )
    Postgres.begin conn
    _ <- Postgres.execute conn stmt bindvals
    Postgres.commit conn

