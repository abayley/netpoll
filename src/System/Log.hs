module System.Log where

import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TChan as TChan
import qualified Control.Concurrent.STM.TVar as TVar
import qualified Control.Monad as Monad
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Data.Time.LocalTime as LocalTime
import qualified Data.Time.Format as TimeFormat
import qualified Data.Word as Word
import qualified System.IO as IO
import qualified System.Directory as Dir
import qualified System.FilePath as FilePath


data Logger = Logger
    { logFile :: Maybe FilePath.FilePath
    , logFileSize :: Integer
    , logRotations :: Word.Word8
    , logChan :: TChan.TChan LogMessage
    , logAsync :: TVar.TVar (Maybe (Async.Async ()))
    }


data Level = DEBUG | INFO | WARN | ERROR | CRITICAL
    deriving (Show, Read, Eq, Ord)


data LogMessage = LogStop | LogMsg Level String


createLogger :: Maybe FilePath.FilePath -> Integer -> Word.Word8 -> IO Logger
createLogger mbFilePath maxSize rotations = do
    case mbFilePath of
        Nothing -> return ()
        Just filePath -> check filePath
    chan <- TChan.newTChanIO
    tvAsync <- TVar.newTVarIO Nothing
    let logger = Logger mbFilePath maxSize rotations chan tvAsync
    async <- Async.async (consumeLogChan logger)
    -- link ensures exceptions raised in async are
    -- propagated to this thread.
    Async.link async
    STM.atomically (TVar.writeTVar (logAsync logger) (Just async))
    return logger


stopLogger :: Logger -> IO ()
stopLogger logger = do
    mbasync <- TVar.readTVarIO (logAsync logger)
    STM.atomically (TChan.writeTChan (logChan logger) LogStop)
    -- wait for it to quit
    maybe (return ()) Async.wait mbasync


consumeLogChan :: Logger -> IO ()
consumeLogChan logger = do
    openLogFile (logFile logger) >>= consume logger


openLogFile :: Maybe FilePath.FilePath -> IO IO.Handle
openLogFile mbFilePath = do
    handle <- maybe (return IO.stdout) (\f -> IO.openFile f IO.AppendMode) mbFilePath
    -- Set line buffering on all handles, including stdout
    -- (which ought to have it by default but apparently
    -- does not, at least on windows).
    IO.hSetBuffering handle IO.LineBuffering
    return handle


type LogConsumer = Logger -> IO.Handle -> IO ()


consume :: LogConsumer
consume logger handle = do
    msg <- STM.atomically (TChan.readTChan (logChan logger))
    handleLogMessage logger handle consume msg


-- Run the logger down: consume everything from
-- the channel, and quit when it is empty.
consumeFinally :: LogConsumer
consumeFinally logger handle =
    STM.atomically (TChan.tryReadTChan (logChan logger))
    >>= maybe (return ())
            (handleLogMessage logger handle consumeFinally)


handleLogMessage :: Logger -> IO.Handle -> LogConsumer -> LogMessage -> IO ()
handleLogMessage logger handle k msg = do
    case msg of
        LogStop -> consumeFinally logger handle
        LogMsg _ m -> do
            IO.hPutStrLn handle m
            rotateHandle logger handle >>= k logger


-- Check if the log file needs to be rotated,
-- and do so if required. Returns the current handle,
-- or a new one if it is rotated.
rotateHandle :: Logger -> IO.Handle -> IO IO.Handle
rotateHandle logger handle = do
    if logFile logger == Nothing then return handle
    else do
        size <- IO.hFileSize handle
        if size < logFileSize logger then return handle
        else do
            IO.hClose handle
            rotateFiles (Maybe.fromJust (logFile logger)) (logRotations logger)
            openLogFile (logFile logger)


check :: FilePath.FilePath -> IO ()
check file = do
    let dir = FilePath.takeDirectory file
    dirExist <- Dir.doesDirectoryExist dir
    Monad.unless dirExist $ fail $ dir ++ " does not exist or is not a directory."
    dirPerm <- Dir.getPermissions dir
    Monad.unless (Dir.writable dirPerm) $ fail $ dir ++ " is not writable."
    exist <- Dir.doesFileExist file
    Monad.when exist $ do
        perm <- Dir.getPermissions file
        Monad.unless (Dir.writable perm) $ fail $ file ++ " is not writable."


rotateFiles :: FilePath.FilePath -> Word.Word8 -> IO ()
rotateFiles path n = mapM_ move srcdsts
  where
    dsts' = reverse . ("":) . map (('.':). show) $ [0..n-1]
    dsts = map (path++) dsts'
    srcs = tail dsts
    srcdsts = zip srcs dsts
    move (src,dst) = do
        exist <- Dir.doesFileExist src
        Monad.when exist $ Dir.renameFile src dst


rpad :: String -> Int -> String
rpad str n = let l = List.length str in
    str ++ replicate (n-l) ' '


writeChan :: Level -> Logger -> String -> IO ()
writeChan level logger msg = do
    threadId <- Concurrent.myThreadId
    let tid = drop 9 (show threadId)
    let format = "%Y-%m-%dT%H:%M:%S.%q"
    now <- LocalTime.getZonedTime
    let tz = TimeFormat.formatTime TimeFormat.defaultTimeLocale "%z" now
    let t = TimeFormat.formatTime TimeFormat.defaultTimeLocale format now
    -- Truncate picosecond component to 8 DP.
    -- My windows machine is only accurate to 7 DP, 8 onwards is just 0s.
    let timestr = (take 28 t) ++ tz
    let leveltidstr = ' ':rpad (show level) 8 ++ ' ':rpad tid 7
    let logmsg = LogMsg level (timestr ++ leveltidstr ++ ' ':msg)
    STM.atomically (TChan.writeTChan (logChan logger) logmsg)


debug, info, warn, error, critical :: Logger -> String -> IO ()
debug    = writeChan DEBUG
info     = writeChan INFO
warn     = writeChan WARN
error    = writeChan ERROR
critical = writeChan CRITICAL
