{-# LANGUAGE OverloadedStrings #-}
module Main where

import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.STM.TBQueue as TBQueue
import qualified Control.Monad.Trans.Reader as Reader
import qualified Network.Socket as Socket

import qualified Netpoll.Poller as Poller
import qualified Netpoll.Scheduler as Scheduler
import qualified System.Log as Log


-- TODO
-- DONE: add logging
-- DONE: use ReaderT in poller to manage args
-- add postgres
-- build datastore
-- design configurator and matcher
-- build archiver

main :: IO ()
main = do
    socket <- Socket.socket Socket.AF_INET Socket.Datagram 0
    -- sockaddr <- Poller.getSockAddr "127.0.0.1" 44444
    sockaddr <- Poller.getSockAddr "0.0.0.0" 44444
    Socket.bind socket sockaddr
    reqQ <- TBQueue.newTBQueueIO 10
    resQ <- TBQueue.newTBQueueIO 10
    reqM <- Poller.mkRequestMap
    logger <- Log.createLogger Nothing 10000000 9
    let pollerEnv = Poller.PollerEnv (reqM, reqQ, resQ, socket, logger)
    -- TODO moar Async
    Concurrent.forkIO (Reader.runReaderT Poller.poller pollerEnv)
    Concurrent.forkIO (Reader.runReaderT Poller.listener pollerEnv)
    Concurrent.forkIO (Reader.runReaderT Poller.timeoutHarvester pollerEnv)
    Reader.runReaderT Poller.testRequestsToPoller pollerEnv
