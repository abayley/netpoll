{-# LANGUAGE OverloadedStrings #-}
module TestSNMP where

import qualified Data.Map.Strict as Map
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text
import qualified Data.Time.Clock as Clock
import qualified Network.Protocol.SNMP.Process as SNMP
-- import qualified System.IO as IO
import Test.HUnit as HUnit


test_parseOid :: HUnit.Test
test_parseOid = HUnit.TestList (
    ((".1.2.3", SNMP.Integer 0 "") ~=? SNMP.parseOid ".1.2.3 = INTEGER: 0") :
    (("x", SNMP.Integer 1 "up") ~=? SNMP.parseOid "x = INTEGER: up(1)") :
    (("x INTEGER: up(1)", SNMP.Unknown "" "") ~=? SNMP.parseOid "x INTEGER: up(1)") :
    []
    )


-- Fetch an oid and test against expected value.
-- If we get an error (e.g. invalid OID) then the test fails.
test_snmpGetOids :: [SNMP.OID] -> [SNMP.SNMPResult] -> Assertion
test_snmpGetOids oids expect = do
    options <- SNMP.defaultOptions
    result <- SNMP.snmpGet "localhost" oids "public" options
    case result of
        Left errmsg -> HUnit.assertFailure (show errmsg)
        Right snmpresult -> expect @=? snmpresult


test_snmpGetOid :: SNMP.OID -> SNMP.SNMPResult -> Assertion
test_snmpGetOid oid expect = test_snmpGetOids [oid] [expect]

systemPrefix :: Text.Text
systemPrefix = ".iso.org.dod.internet.mgmt.mib-2.system."
test_snmpGet :: HUnit.Test
test_snmpGet = HUnit.TestList (map HUnit.TestCase (
    (test_snmpGetOid "sysObjectID.0" (
        Text.append systemPrefix "sysObjectID.0",
        SNMP.OID ".iso.org.dod.internet.private.enterprises.netSnmp.netSnmpEnumerations.netSnmpAgentOIDs.13")) :
    (test_snmpGetOid "sysDescr.0" (
        Text.append systemPrefix "sysDescr.0",
        SNMP.DisplayString "Windows backus 6.2.9200   Home Edition x86 Family 6 Model 55 Stepping 3")) :
    []
    ))


ifEntryPrefix :: Text.Text
ifEntryPrefix = ".iso.org.dod.internet.mgmt.mib-2.interfaces.ifTable.ifEntry."
test_snmpGetMulti :: HUnit.Test
test_snmpGetMulti = HUnit.TestList (map HUnit.TestCase (
    (test_snmpGetOids ["ifSpeed.1", "ifMtu.1", "ifAdminStatus.1"] (
        (Text.append ifEntryPrefix "ifSpeed.1", SNMP.Gauge32 1073741824) :
        (Text.append ifEntryPrefix "ifMtu.1", SNMP.Integer 1500 "") :
        (Text.append ifEntryPrefix "ifAdminStatus.1", SNMP.Integer 1 "up") :
        [])) :
    []
    ))


test_snmpWalk :: HUnit.Test
test_snmpWalk = HUnit.TestCase $ do
    options1 <- SNMP.defaultOptions
    let options = options1 { SNMP.snmpOutputOpts = "fU"}
    result <- SNMP.snmpWalk "localhost" "ifIndex" "public" options 25
    case result of
        Left errmsg -> HUnit.assertFailure (show errmsg)
        Right list -> do
            let r1 = (Text.append ifEntryPrefix "ifIndex.1", SNMP.Integer 1 "")
            r1 @=? (list !! 0)


test_snmpTable :: HUnit.Test
test_snmpTable = HUnit.TestCase $ do
    options <- SNMP.defaultOptions
    result <- SNMP.snmpTable "localhost" "ifTable" [] "public" options
    case result of
        Left errmsg -> HUnit.assertFailure (show errmsg)
        Right table -> do
            let keys = Map.keys table
            [1] @=? (keys !! 0)
            [2] @=? (keys !! 1)
            let row = Maybe.fromJust (Map.lookup (head keys) table)
            let col = head (Map.keys row)
            "ifAdminStatus" @=? col


test_snmpTableCols :: HUnit.Test
test_snmpTableCols = HUnit.TestCase $ do
    options <- SNMP.defaultOptions
    result <- SNMP.snmpTable "localhost" "ifTable" ["ifIndex", "ifDescr"] "public" options
    case result of
        Left errmsg -> HUnit.assertFailure (show errmsg)
        Right table -> do
            let keys = Map.keys table
            [1] @=? (keys !! 0)
            [2] @=? (keys !! 1)
            let row = Maybe.fromJust (Map.lookup (head keys) table)
            let col = head (Map.keys row)
            "ifDescr" @=? col


test_snmpTableColsFailure :: HUnit.Test
test_snmpTableColsFailure = HUnit.TestCase $ do
    options <- SNMP.defaultOptions
    result <- SNMP.snmpTable "localhost" "ifTable" ["ifXIndex", "ifDescr"] "public" options
    case result of
        Left errmsg -> (1, "ifXIndex:  (Sub-id not found: (top) -> ifXIndex)\n") @=? errmsg
        Right table -> HUnit.assertFailure (show "valid table returned - should have been error")


ifTableName :: Text.Text
ifTableName = ".iso.org.dod.internet.mgmt.mib-2.interfaces.ifTable"
ifTableOid :: Text.Text
ifTableOid = ".1.3.6.1.2.1.2.2"
test_snmpTranslateName :: HUnit.Test
test_snmpTranslateName = "test_snmpTranslateName" ~: HUnit.TestCase $ do
    options <- SNMP.defaultOptions
    result <- SNMP.snmpTranslateName "ifTable" options
    case result of
        Left errmsg -> HUnit.assertFailure (show errmsg)
        Right oid -> ifTableOid @=? oid


test_snmpCanonicalName :: HUnit.Test
test_snmpCanonicalName = "test_snmpCanonicalName" ~: HUnit.TestCase $ do
    options <- SNMP.defaultOptions
    result <- SNMP.snmpCanonicalName "ifTable" options
    case result of
        Left errmsg -> HUnit.assertFailure (show errmsg)
        Right oid -> ifTableName @=? oid


test_snmpTranslateOid :: HUnit.Test
test_snmpTranslateOid = "test_snmpTranslateOid" ~: HUnit.TestCase $ do
    options <- SNMP.defaultOptions
    result <- SNMP.snmpTranslateOid ifTableOid options
    case result of
        Left errmsg -> HUnit.assertFailure (show errmsg)
        Right oid -> ifTableName @=? oid


-- Return the number of seconds an IO action takes.
-- For crude timing measurement.
time :: IO a -> IO Double
time a = do
    start <- Clock.getCurrentTime
    _ <- a
    end <- Clock.getCurrentTime
    return (realToFrac (Clock.diffUTCTime end start))


test_snmpTranslateOidCached :: HUnit.Test
test_snmpTranslateOidCached = "test_snmpTranslateOidCached" ~: HUnit.TestCase $ do
    options <- SNMP.defaultOptions
    t1 <- time (SNMP.snmpTranslateOid ifTableOid options)
    t2 <- time (SNMP.snmpTranslateOid ifTableOid options)
    t3 <- time (SNMP.snmpTranslateOid ifTableOid options)
    -- First one should be slow (> 0.1s).
    HUnit.assertBool "t1 > 0.1" (t1 > 0.1)
    -- Subsequent should be cached, therefore fast.
    HUnit.assertBool "t2 < 0.01" (t2 < 0.01)
    HUnit.assertBool "t3 < 0.01" (t3 < 0.01)


snmpTests :: HUnit.Test
snmpTests = HUnit.TestList (
    test_parseOid :
    test_snmpGet :
    test_snmpGetMulti :
    test_snmpWalk :    
    test_snmpTable :
    test_snmpTableCols :
    test_snmpTableColsFailure :
    test_snmpTranslateName :
    test_snmpCanonicalName :
    test_snmpTranslateOid :
    test_snmpTranslateOidCached :
    [])
