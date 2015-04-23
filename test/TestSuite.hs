module TestSuite where

import qualified System.IO as IO
import Test.HUnit as HUnit
import qualified TestSNMP as TestSNMP
import qualified TestUDP as TestUDP
import qualified TestLog as TestLog


testSuite :: HUnit.Test
testSuite = HUnit.TestList [TestSNMP.snmpTests, TestUDP.udpTests]
-- logging tests create files, so maybe don't run all the time
-- testSuite = HUnit.TestList [TestLog.logTests]


main :: IO Int
main = do
    -- You'd expect stdout to be line buffered to a terminal,
    -- but (on windows at least) apparently it is not.
    IO.hSetBuffering IO.stdout IO.LineBuffering
    testcounts <- HUnit.runTestTT testSuite
    -- putStrLn (show (errors testcounts + failures testcounts))
    return (if errors testcounts + failures testcounts >  0 then 1 else 0)
