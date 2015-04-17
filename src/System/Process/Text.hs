-----------------------------------------------------------------------------
-- |
-- Module      :  System.Process.Text
-- Copyright   :  (c) Alistair Bayley
-- License     :  GPL
--
-- Maintainer  :  alistair@abayley.org
-- Stability   :  experimental
-- Portability :  portable
--
-- A copy of the System.Process library where the
-- functions return Text, rather than String.
--
-----------------------------------------------------------------------------
module System.Process.Text where

import qualified Control.Concurrent as Concurrent
import qualified Control.DeepSeq as DeepSeq
import qualified Control.Exception as Exception
import qualified Control.Monad as Monad
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Foreign.C.Error as CError
import qualified GHC.IO.Exception as GHCEx
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified System.Process as Process
import qualified System.Process.Internals as Internals


readProcessWithExitCode
    :: FilePath                 -- ^ Filename of the executable (see 'proc' for details)
    -> [String]                 -- ^ any arguments
    -> Text.Text                   -- ^ standard input
    -> IO (Exit.ExitCode, Text.Text, Text.Text) -- ^ exitcode, stdout, stderr
readProcessWithExitCode cmd args input = do
    let cp_opts = (Process.proc cmd args) {
                    Process.std_in  = Process.CreatePipe,
                    Process.std_out = Process.CreatePipe,
                    Process.std_err = Process.CreatePipe
                  }
    -- IO.putStrLn (show cmd ++ " " ++ show args)
    withCreateProcess_ "readProcessWithExitCode" cp_opts $
      \(Just inh) (Just outh) (Just errh) ph -> do

        out <- TextIO.hGetContents outh
        err <- TextIO.hGetContents errh

        -- fork off threads to start consuming stdout & stderr
        withForkWait  (Exception.evaluate $ DeepSeq.rnf out) $ \waitOut ->
         withForkWait (Exception.evaluate $ DeepSeq.rnf err) $ \waitErr -> do

          -- now write any input
          Monad.unless (Text.null input) $
            ignoreSigPipe $ TextIO.hPutStr inh input
          -- hClose performs implicit hFlush, and thus may trigger a SIGPIPE
          ignoreSigPipe $ IO.hClose inh

          -- wait on the output
          waitOut
          waitErr

          IO.hClose outh
          IO.hClose errh

        -- wait on the process
        ex <- Process.waitForProcess ph

        return (ex, out, err)


withForkWait :: IO () -> (IO () ->  IO a) -> IO a
withForkWait async body = do
  waitVar <- Concurrent.newEmptyMVar :: IO (Concurrent.MVar (Either Exception.SomeException ()))
  Exception.mask $ \restore -> do
    tid <- Concurrent.forkIO $ Exception.try (restore async) >>= Concurrent.putMVar waitVar
    let wait = Concurrent.takeMVar waitVar >>= either Exception.throwIO return
    restore (body wait) `Exception.onException` Concurrent.killThread tid


withCreateProcess_
  :: String
  -> Process.CreateProcess
  -> (Maybe IO.Handle -> Maybe IO.Handle -> Maybe IO.Handle -> Process.ProcessHandle -> IO a)
  -> IO a
withCreateProcess_ fun c action =
    Exception.bracketOnError (Internals.createProcess_ fun c) cleanupProcess
                     (\(m_in, m_out, m_err, ph) -> action m_in m_out m_err ph)


ignoreSigPipe :: IO () -> IO ()
ignoreSigPipe = Exception.handle $ \e -> case e of
    GHCEx.IOError
        { GHCEx.ioe_type  = GHCEx.ResourceVanished, GHCEx.ioe_errno = Just ioe }
        | CError.Errno ioe == CError.ePIPE -> return ()
    _ -> Exception.throwIO e


cleanupProcess :: (Maybe IO.Handle, Maybe IO.Handle, Maybe IO.Handle, Process.ProcessHandle) -> IO ()
cleanupProcess (mb_stdin, mb_stdout, mb_stderr, ph) = do
    Process.terminateProcess ph
    -- Note, it's important that other threads that might be reading/writing
    -- these handles also get killed off, since otherwise they might be holding
    -- the handle lock and prevent us from closing, leading to deadlock.
    maybe (return ()) (ignoreSigPipe . IO.hClose) mb_stdin
    maybe (return ()) IO.hClose mb_stdout
    maybe (return ()) IO.hClose mb_stderr
    -- terminateProcess does not guarantee that it terminates the process.
    -- Indeed on Unix it's SIGTERM, which asks nicely but does not guarantee
    -- that it stops. If it doesn't stop, we don't want to hang, so we wait
    -- asynchronously using forkIO.
    _ <- Concurrent.forkIO (Process.waitForProcess ph >> return ())
    return ()
