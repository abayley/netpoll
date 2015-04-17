{-# LANGUAGE OverloadedStrings #-}
module Main where

import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.STM.TBQueue as TBQueue
import qualified Data.Foldable as Foldable
-- import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketBS
import qualified System.IO as IO
import qualified Network.Protocol.SNMP.Process as SNMP
import qualified Network.Protocol.SNMP.UDP as UDP
-- import qualified Network.Protocol.NetSNMP as NetSNMP

import qualified Netpoll.Poller as Poller
import qualified Netpoll.Scheduler as Scheduler


printResults :: Either SNMP.ErrorMsg [SNMP.SNMPResult] -> IO ()
printResults results = 
    case results of
        Left _ -> IO.putStrLn (show results)
        Right snmpresults -> Foldable.mapM_ IO.putStrLn (map show snmpresults)


printResult :: Either SNMP.ErrorMsg Text.Text -> IO ()
printResult result =
    case result of
        Left _ -> IO.putStrLn (show result)
        Right oid -> TextIO.putStrLn oid

-- TOTO
-- add logging
-- use ReaderT in poller to manage args
-- add postgres

main :: IO ()
main = do
    socket <- Socket.socket Socket.AF_INET Socket.Datagram 0
    sockaddr <- Poller.getSockAddr "127.0.0.1" 44444
    Socket.bind socket sockaddr
    reqQ <- TBQueue.newTBQueueIO 10
    resQ <- TBQueue.newTBQueueIO 10
    reqM <- Poller.mkRequestMap
    Concurrent.forkIO (Poller.poller socket reqQ reqM)
    Concurrent.forkIO (Poller.listener socket reqQ resQ reqM)
    Concurrent.forkIO (Poller.timeoutHarvester reqQ resQ reqM)
    Poller.testRequestsToPoller reqQ
