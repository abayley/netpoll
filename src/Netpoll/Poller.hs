-- Poller.hs
{-
TODO:
logging (rotating logger)
ReaderT monad for all IO functions to carry env around
    (including logger)
datastore and archiver
scheduler
configurator

what does this do?
process a stream of poll requests. Each poll request:
 - request id (unique id for request)
 - ip
 - list of (dataseries, oids, calc) groups
 - routing token
 - timeout & retries

A poll request generates a poll. That means:
 - send a poll
 - push request on queue of waiting responses

when a response comes back:
 - find the matching request on the queue
 - do the calculation
 - forward the result

When we send a request to a device, we want to
put all the oids in one request.
However, there may be multiple data series,
so the oids need to be grouped, and each group
may include an optional calculation function
to apply to the group.
Each oid group should produce just one value
i.e. the group is for one data series.
The calculation function should be of type
[Int64] -> Double
(we will only store floats in our database.)

Concurrency:
 - scheduler: thread to generate poll requests
 - poller: thread to receive poll requests (generate snmp get requests)
 - listener: thread to listen for responses and process them
 - store: thread to push poll responses into database

Data structures:
 - TBQueues between:
   - scheduler -> poller 
   - listener -> store
 - request map: shared by poller & listener.
     poller adds requests, listener removes.
      - fast lookup by request-id
      - fast insert/append and remove (random index)

How do we handle timeouts and retries?
There needs to be some actor that scans the
request map for items that have timed out.
It can decrement the retry timer and resend
the request (just push it on the poller queue).
If the retry time is zero then we send a timeout
result forward to the store.

It is also possible for garbled responses to be
returned by devices. In this case we need to match
the oids in the response against the request,
and if they differ to resend the request.

So it looks as though we need a couple of indexes
(maps) for requests: one by request-id, and one by
next-timeout (i.e. time at which request is deemed to
have timed out).


Datastore
---------
An SQL database (pref postgres) with a highres table partitioned
by day, and lower-res tables:
 - 15 min
 - hourly
 - daily

An archiver process runs every 15 mins and rolls up the highres
data into the lower-res tables. It also precreates partitions
as required.

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
        ts :: timestamp
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


Configuration database
----------------------
tables:
  - device (id, type (sysObjectID.0?), hostname, ip, snmp community)
  - device_flow

For each interface (or just a known subset?) we get:
  - bytes transmitted

For each flow we get:
  - bytes transmitted (or ABR)
  - FMRD
  - FMYD

For each Y.1731 probe we get:
  - delay (p2r, r2p, rt)
  - jitter (p2r, r2p, rt)
-}

module Netpoll.Poller where

import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TVar as TVar
import qualified Control.Concurrent.STM.TBQueue as TBQueue
import qualified Data.Bits as Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LazyBS
import qualified Data.IntMap.Strict as IntMap
import qualified Data.List as List
import qualified Data.Monoid as Monoid
import qualified Data.Set as Set
import qualified Data.Time.Clock.POSIX as POSIX
import qualified Data.Word as Word

import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketBS
import qualified System.IO as IO

import qualified Network.Protocol.SNMP.UDP as SnmpUDP


data PollRequest = PollRequest {
    requestId :: String,  -- unique id
    requestAddress :: String,  -- ip
    requestAuthToken :: String,  -- snmp community
    requestRoutingToken :: String,  -- for store
    requestPollerType :: String,  -- snmp, other, ...
    requestInterval :: Word.Word16,  -- seconds
    requestIntervalRange :: (Word.Word16, Word.Word16),
    requestTimeout :: Word.Word16,  -- seconds
    requestRetries :: Word.Word16,  -- seconds
    requestNextTimeout :: Int,  -- seconds since epoch
    -- (dataseries id, calculator, oids)
    requestMeasurements :: [(Int, String, [String])]
    } deriving (Eq, Ord, Read, Show)


data PollResult = PollResult {
    resultId :: String,  -- unique id, same as requestId
    resultRoutingToken :: String,  -- for store
    resultDataseriesId :: Int,
    resultValue :: Double,
    -- 0 == ok, 1 == timeout, 2 == error
    resultErrorCode :: Int,
    -- secondary error code e.g. snmp error
    resultErrorCode2 :: Int
    } deriving (Eq, Ord, Read, Show)


-- We maintain two maps (indexes):
--   address -> request
--   next-timeout -> request
newtype RequestMap = RequestMap
    -- snmp-request-id -> request
    ( TVar.TVar (IntMap.IntMap PollRequest)
    -- next-timeout -> [request]
    -- (because a given time may have more than one poll)
    , TVar.TVar (IntMap.IntMap [PollRequest])
    )


mkRequestMap :: IO RequestMap
mkRequestMap = do
    let map1 = IntMap.empty
    let map2 = IntMap.empty
    t1 <- TVar.newTVarIO map1
    t2 <- TVar.newTVarIO map2
    return (RequestMap (t1, t2))


-- Use the first dataseries id as the request id
-- (arbitrary)
getSnmpRequestId :: PollRequest -> Int
getSnmpRequestId = (\(a,_,_) -> a) . head . requestMeasurements


addRequestToMap :: RequestMap -> PollRequest -> IO ()
addRequestToMap maps request = do
    IO.putStrLn ("addRequestToMap: " ++ show (requestId request))
    STM.atomically $ do
        let RequestMap (map1, map2) = maps
        let key1 = getSnmpRequestId request
        let key2 = requestNextTimeout request
        TVar.modifyTVar' map1 (IntMap.insert key1 request)
        TVar.modifyTVar' map2 (IntMap.alter f key2)
    printMaps maps
    where
        -- f = maybe (Just [request]) (Just . (request :))
        f Nothing = Just [request]
        f (Just l) = Just (request : l)


-- for debugging
printMaps :: RequestMap -> IO ()
printMaps maps = do
    let RequestMap (tvar1, tvar2) = maps
    map1 <- STM.atomically (TVar.readTVar tvar1)
    map2 <- STM.atomically (TVar.readTVar tvar2)
    let m1 = map (\(k,r) -> show k ++ " -> " ++ requestId r) (IntMap.assocs map1)
    let m2 = map (\(k,r) -> show k ++ " -> " ++ (List.intercalate "," (map requestId r))) (IntMap.assocs map2)
    IO.putStrLn ("map1: " ++ List.intercalate ", " m1)
    IO.putStrLn ("map2: " ++ List.intercalate ", " m2)


deleteFromMap :: RequestMap -> PollRequest -> IO ()
deleteFromMap maps req = do
    -- IO.putStrLn ("deleteFromMap: " ++ show (requestId req))
    let RequestMap (tvar1, tvar2) = maps
    STM.atomically (do
        -- map1 indexed by request-id
        map1 <- TVar.readTVar tvar1
        TVar.writeTVar tvar1 (IntMap.delete (getSnmpRequestId req) map1)
        -- map2 indexed by next-timeout
        map2 <- TVar.readTVar tvar2
        let key2 = requestNextTimeout req
        let mb = IntMap.lookup key2 map2
        case mb of
            -- if we can't find it, do nothing
            Nothing -> return ()
            Just l -> do
                -- remove any requests with matching request-id
                let newl = filter (\p -> requestId p /= requestId req) l
                let newmap = if newl == []
                    then IntMap.delete key2 map2
                    else IntMap.insert key2 newl map2
                TVar.writeTVar tvar2 newmap
        )
    -- printMaps maps


getRequestById :: RequestMap -> Int -> IO (Maybe PollRequest)
getRequestById maps reqId = do
    let RequestMap (map1, _) = maps
    m <- STM.atomically (TVar.readTVar map1)
    return (IntMap.lookup reqId m)


-- The String ipaddr is the IP address as a String.
-- We don't do DNS lookup here.
getSockAddr :: String -> Socket.PortNumber -> IO Socket.SockAddr
getSockAddr ipaddr port = do
    let hints = Socket.defaultHints { Socket.addrFlags = [Socket.AI_NUMERICHOST, Socket.AI_NUMERICSERV] }
    addrInfos <- Socket.getAddrInfo (Just hints) (Just ipaddr) (Just (show port))
    return (Socket.addrAddress (head addrInfos))


sendUDPPacket :: Socket.Socket -> String -> Socket.PortNumber -> BS.ByteString -> IO Int
sendUDPPacket socket ipaddr port bs = do
    sockaddr <- getSockAddr ipaddr port
    SocketBS.sendTo socket bs sockaddr


-- The IPv4 address in Socket.SockAddrInet is a Word32.
-- I want to see the individual octets.
ipv4ToBytes :: Word.Word32 -> (Word.Word8, Word.Word8, Word.Word8, Word.Word8)
ipv4ToBytes a =
    ( fromIntegral (a Bits..&. 0x000000ff)
    , fromIntegral (Bits.shiftR (a Bits..&. 0x0000ff00) 8)
    , fromIntegral (Bits.shiftR (a Bits..&. 0x00ff0000) 16)
    , fromIntegral (Bits.shiftR (a Bits..&. 0xff000000) 24)
    )


ipv4BytesToString :: (Word.Word8, Word.Word8, Word.Word8, Word.Word8) -> String
ipv4BytesToString (a1, a2, a3, a4) =
    show a1 Monoid.<> "." Monoid.<>
    show a2 Monoid.<> "." Monoid.<>
    show a3 Monoid.<> "." Monoid.<>
    show a4


-- we only do ipv4
getAddress :: Socket.SockAddr -> Maybe String
getAddress (Socket.SockAddrInet _ addr) = Just (ipv4BytesToString (ipv4ToBytes addr))
getAddress _ = Nothing


getSnmpRespReqId :: SnmpUDP.SnmpResponse -> Int
getSnmpRespReqId (SnmpUDP.SnmpSequence s) =
    f (head (filter isGetResp s))
    where
    isGetResp (SnmpUDP.SnmpGetResponse _) = True
    isGetResp _ = False
    f (SnmpUDP.SnmpGetResponse l) = getSnmpRespInt (head l)
    getSnmpRespInt (SnmpUDP.SnmpInt i) = fromIntegral i


getSnmpRespError :: SnmpUDP.SnmpResponse -> (Int, Int)
getSnmpRespError (SnmpUDP.SnmpSequence s) =
    f (head (filter isGetResp s))
    where
    isGetResp (SnmpUDP.SnmpGetResponse _) = True
    isGetResp _ = False
    f (SnmpUDP.SnmpGetResponse (_:e:i:_)) = (getSnmpRespInt e, getSnmpRespInt i)
    getSnmpRespInt (SnmpUDP.SnmpInt i) = fromIntegral i


getPOSIXSecs :: IO Int
getPOSIXSecs = do
    -- getPOSIXTime returns a (large) real,
    -- which is a number of seconds since 1970-01-01.
    ptime <- POSIX.getPOSIXTime
    -- should we round, floor, or ceiling?
    return (round ptime)


-- decrement retry counter and push onto poller queue
resendRequest :: TBQueue.TBQueue PollRequest -> PollRequest -> IO ()
resendRequest requestQueue request = do
    -- IO.putStrLn ("resendRequest: " ++ requestId request)
    let newRetries = requestRetries request - 1
    let newReq = request {requestRetries = newRetries }
    STM.atomically (TBQueue.writeTBQueue requestQueue newReq)


-- Get the oids and values, apply any post-processing,
-- construct the PollResults, and send onwards.
sendResultToStore :: TBQueue.TBQueue PollResult -> PollRequest -> SnmpUDP.SnmpResponse -> IO ()
sendResultToStore resultQueue request response = do
    -- FIXME implement
    IO.putStrLn ("send result to store: " ++ show (requestId request))
    return ()


sendErrorToStore :: TBQueue.TBQueue PollResult -> PollRequest -> SnmpUDP.SnmpResponse -> IO ()
sendErrorToStore resultQueue request response = do
    -- FIXME implement
    IO.putStrLn ("send error to store: " ++ show (requestId request))
    return ()


sendTimeoutToStore :: TBQueue.TBQueue PollResult -> PollRequest -> IO ()
sendTimeoutToStore resultQueue request = do
    -- FIXME implement
    IO.putStrLn ("request timeout: " ++ requestId request)
    return ()


requestOids :: PollRequest -> [String]
requestOids request = 
    List.concat [oids | (_, _, oids) <- requestMeasurements request]


getSnmpRespOidVals :: SnmpUDP.SnmpResponse -> [(String, SnmpUDP.SnmpResponse)]
getSnmpRespOidVals (SnmpUDP.SnmpSequence l) =
    varbinds (head (filter isGetResp l))
    where
    isGetResp (SnmpUDP.SnmpGetResponse _) = True
    isGetResp _ = False
    isSeq (SnmpUDP.SnmpSequence _) = True
    isSeq _ = False
    varbinds :: SnmpUDP.SnmpResponse -> [(String, SnmpUDP.SnmpResponse)]
    varbinds (SnmpUDP.SnmpGetResponse l) = varbinds (head (filter isSeq l))
    varbinds (SnmpUDP.SnmpSequence s) = List.concat (List.map varbind s)
    varbind :: SnmpUDP.SnmpResponse -> [(String, SnmpUDP.SnmpResponse)]
    varbind (SnmpUDP.SnmpSequence (o:v:_)) =
        case o of
            SnmpUDP.SnmpOid l -> [(oid2Str l, v)]
            _ -> []
    varbind _ = []
    oid2Str :: [Word.Word64] -> String
    oid2Str oid = List.concat (map (("." ++) . show) oid)


getSnmpRespOids response = map fst (getSnmpRespOidVals response)

-- Check that every oid in the request
-- has a matching oid in the response.
oidsMatch :: PollRequest -> SnmpUDP.SnmpResponse -> Bool
oidsMatch request response =
    Set.fromList (getSnmpRespOids response) == Set.fromList (requestOids request)


poller :: Socket.Socket -> TBQueue.TBQueue PollRequest -> RequestMap -> IO ()
poller socket requestQueue requestMap = do
    -- blocks (STM retry) if nothing on queue
    request <- STM.atomically (TBQueue.readTBQueue requestQueue)
    IO.putStrLn("poller: found request on queue: " ++ requestId request)
    let reqId = getSnmpRequestId request
    let oids = requestOids request
    let snmpReq = SnmpUDP.makeGetRequest (fromIntegral reqId) (requestAuthToken request) oids
    -- parse and print the outgoing request (for debugging)
    -- either IO.putStrLn (IO.putStrLn . show)
    --     (SnmpUDP.parseSnmpResponse (LazyBS.toStrict snmpReq))
    -- Add request to map before sending packet,
    -- just in case response comes back very quickly
    -- (avoid race condition).
    now <- getPOSIXSecs
    let nextTimeout = now + fromIntegral (requestTimeout request)
    addRequestToMap requestMap (request { requestNextTimeout = nextTimeout })
    sent <- sendUDPPacket socket (requestAddress request) 161 (LazyBS.toStrict snmpReq)
    IO.putStrLn ("poller: sent bytes: " ++ show sent)
    poller socket requestQueue requestMap


{-
snmp response error codes:
1 - too big - the response PDU would be too big
2 - no such name - the name of a requested object was not found
3 - bad value - incorrect type or length
4 - read only - tried to set a read-only variable
5 - generic - some other error not in this list
6 - no access - access denied for security reasons
7 - wrong type - incorrect type for an object
8 - wrong length
9 - wrong encoding
10 - wrong value - var bind contains value out of range e.g. enums
11 - no creation - variable does not exist, cannot be created
12 - inconsistent value - in range but not possible in current state
13 - resource unavailable - for set
14 - commit failed - a set failed
15 - undo failed - set failed, then undo failed (when setting a group)
16 - auth error
17 - not writable
18 - inconsistent name - name in var bind names something that does not exist
-}
processResponse :: BS.ByteString
    -> TBQueue.TBQueue PollRequest
    -> TBQueue.TBQueue PollResult
    -> RequestMap
    -> IO ()
processResponse msg requestQueue resultQueue requestMap = do 
    either IO.putStrLn processParsedResponse (SnmpUDP.parseSnmpResponse msg)
    where
    processParsedResponse response = do
        IO.putStrLn (show response)
        let reqId = getSnmpRespReqId response
        mbReq <- getRequestById requestMap reqId
        case mbReq of
            -- cannot match? discard
            Nothing -> do
                IO.putStrLn ("processResponse: no request for id " ++ show reqId)
            Just request -> do
                let (errStatus, errIndex) = getSnmpRespError response
                -- FIXME check response error codes
                IO.putStrLn ("processResponse: found request for id " ++ show reqId)
                deleteFromMap requestMap request
                if errStatus /= 0
                then sendErrorToStore resultQueue request response
                else if oidsMatch request response
                    then sendResultToStore resultQueue request response
                    else resendRequest requestQueue request
                        -- IO.putStrLn ("processResponse: oids do not match; resend")
                        -- IO.putStrLn ("request oids: " ++ show (requestOids request))
                        -- IO.putStrLn ("response oids: " ++ show (getSnmpRespOids response))


listener :: Socket.Socket
    -> TBQueue.TBQueue PollRequest
    -> TBQueue.TBQueue PollResult
    -> RequestMap
    -> IO ()
listener socket requestQueue resultQueue requestMap = do
    (msg, fromSock) <- SocketBS.recvFrom socket 8192
    let address = getAddress fromSock
    -- IO.putStrLn ("listener: received from" ++ show fromSock)
    -- IO.putStrLn (SnmpUDP.prettyHex msg)
    -- IO.putStrLn "------------"
    case address of
        -- non-ipv4 address - drop it
        Nothing -> return ()
        Just _ -> processResponse msg requestQueue resultQueue requestMap
    listener socket requestQueue resultQueue requestMap


-- harvester of sorrow (language of the mad)
-- Scan (every second) for polls that have timed-out.
-- If they have a non-zero retry counter then decrement
-- it and send them back to the poller.
-- If they have exhausted their retries then send
-- a PollResult forward with timeout failure set.
timeoutHarvester requestQueue resultQueue requestMap = do
    now <- getPOSIXSecs
    -- IO.putStrLn ("scan for timeouts at " ++ show now)
    let RequestMap (tvar1, tvar2) = requestMap
    (retries, timeouts) <- STM.atomically (do
        map2 <- TVar.readTVar tvar2
        -- filter to requests whose next-timeout has passed
        -- i.e. is less than now.
        let keys = filter (< now) (IntMap.keys map2)
        -- fetch lists of requests from map and flatten
        let mbrequests = map (\k -> IntMap.lookup k map2) keys
        let requests = List.concat (map (maybe [] id) mbrequests)
        -- filter them again: those that have exhausted their retries
        -- should be discarded (remove from map).
        -- These will be sent on as failed polls.
        -- The others have their retry counter decremented
        -- and are pushed back on the poller queue.
        -- In either case remove the request from the map
        return (List.partition ((> 0) . requestRetries) requests)
        )
    mapM_ (deleteFromMap requestMap) (retries ++ timeouts)
    mapM_ (resendRequest requestQueue) retries
    mapM_ (sendTimeoutToStore resultQueue) timeouts
    -- Pause for a second between scans
    Concurrent.threadDelay 1000000
    timeoutHarvester requestQueue resultQueue requestMap


testRequestsToPoller :: TBQueue.TBQueue PollRequest -> IO ()
testRequestsToPoller reqQ = do
    -- let ifOutOctets_1 = ".1.3.6.1.2.1.2.2.1.16.1"
    let ifOutOctets_1 = ".1.0.0"
    let req = PollRequest
            { requestId = "req1"
            , requestAddress = "127.0.0.1"
            , requestAuthToken = "public"
            , requestRoutingToken = "nid"
            , requestPollerType = "snmp"
            , requestInterval = 300
            , requestTimeout = 3
            , requestRetries = 3
            , requestNextTimeout = 0
            , requestMeasurements = [(256, "id", [ifOutOctets_1])]
            }
    STM.atomically (TBQueue.writeTBQueue reqQ req)
    let loop = do
            -- micro seconds
            Concurrent.threadDelay 5000000
            IO.putStrLn "push request"
            STM.atomically (TBQueue.writeTBQueue reqQ req)
            loop
    loop
