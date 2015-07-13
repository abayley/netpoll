-- TestScheduler.hs
module TestScheduler where

import qualified Control.Concurrent.STM.TBQueue as TBQueue
import qualified Control.Monad.Trans.Reader as Reader
import qualified Database.PostgreSQL.Simple as Postgres
import Test.HUnit as HUnit

import qualified Netpoll.Poller as Poller
import qualified Netpoll.Scheduler as Scheduler
import qualified System.Log as Log


generateReqs x = map mkReq [1..x] where
    vals = [".1.0.0", ".1.0.1", ".1.0.2"]
    mkDs n = [(10 * n + i, "sum", vals) | i <- [0..9]]
    mkReq n = let reqId = "req" ++ show n in
        Poller.mkRequest reqId "127.0.0.1" "public" 300 (mkDs n)

test_1 :: HUnit.Test
test_1 = "test 1" ~: HUnit.TestCase $ do
    schedules <- Scheduler.mkSchedules
    reqQ <- TBQueue.newTBQueueIO 1000
    conn <- Postgres.connect (Postgres.defaultConnectInfo { Postgres.connectUser ="netpoll", Postgres.connectPassword = "netpoll" })
    -- logger <-  Log.createLogger (Just "./scheduler.log") 10000000 9
    -- Nothing = log to stdout
    logger <- Log.createLogger Nothing 10000000 9
    let schedulerEnv = Scheduler.SchedulerEnv (schedules, reqQ, conn, logger)

    Reader.runReaderT Scheduler.loadSchedulesFromDatabase schedulerEnv

    let ifOutOctets_1 = ".1.0.0"
    let req = Poller.mkRequest "req1" "127.0.0.1" "public" 300 [(256, "id", [ifOutOctets_1])]
    Reader.runReaderT (Scheduler.addRequestToSchedules req) schedulerEnv
    Log.debug logger "delete request"
    Reader.runReaderT (Scheduler.deleteRequestFromSchedules req) schedulerEnv

    (flip Reader.runReaderT) schedulerEnv $
        mapM_ Scheduler.addRequestToSchedules (generateReqs 100)

    Postgres.close conn
    return ()


tests :: HUnit.Test
tests = HUnit.TestList (
    test_1 :
    [])
