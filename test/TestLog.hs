module TestLog where

import qualified System.Log as Log
import Test.HUnit as HUnit


test_logger :: HUnit.Test
test_logger = "logger" ~: HUnit.TestCase $ do
    logger <-  Log.createLogger (Just "./test.log") 1000000 9
    loop 1000 logger
    Log.stopLogger logger
    where
    loop 0 _ = return ()
    loop n logger = do
        let sn = show n
        Log.warn logger ("this is warning " ++ sn)
        Log.debug logger ("debug message " ++ sn)
        Log.critical logger ("this is critical " ++ sn)
        Log.info logger ("a multi-line log\nmessage that spans\nmultiple lines " ++ sn)
        loop (n-1) logger


logTests :: HUnit.Test
logTests = HUnit.TestList (
    test_logger :
    [])
