module TestSuite where

import Test.HUnit as HUnit
import qualified TestSNMP as TestSNMP
import qualified TestUDP as TestUDP


testSuite :: HUnit.Test
testSuite = HUnit.TestList [TestSNMP.snmpTests, TestUDP.udpTests]


main :: IO Int
main = do
    testcounts <- HUnit.runTestTT testSuite
    -- putStrLn (show (errors testcounts + failures testcounts))
    return (if errors testcounts + failures testcounts >  0 then 1 else 0)
