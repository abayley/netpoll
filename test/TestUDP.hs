module TestUDP where

import qualified Data.ByteString.Lazy as LazyBS
import qualified Network.Protocol.SNMP.UDP as UDP
import Test.HUnit as HUnit


test_int2Words :: HUnit.Test
test_int2Words = "test_int2Words" ~: HUnit.TestCase $ do
    UDP.int2Words 0 @?= [0]
    UDP.int2Words 1 @?= [1]
    UDP.int2Words 128 @?= [0, 128]
    UDP.int2Words 256 @?= [1, 0]
    UDP.int2Words (-1) @?= [255]
    UDP.int2Words (-128) @?= [128]
    UDP.int2Words (-129) @?= [255, 127]
    UDP.int2Words maxBound @?= [127, 255, 255, 255, 255, 255, 255, 255]
    UDP.int2Words minBound @?= [128,   0,   0,   0,   0,   0,   0,   0]


test_words2Int :: HUnit.Test
test_words2Int = "test_words2Int" ~: HUnit.TestCase $ do
    UDP.words2Int [0] @?= 0
    UDP.words2Int [1] @?= 1
    UDP.words2Int [255] @?= -1
    UDP.words2Int [1, 0] @?= 256
    UDP.words2Int [127, 255, 255, 255, 255, 255, 255, 255] @?= maxBound
    UDP.words2Int [128,   0,   0,   0,   0,   0,   0,   0] @?= minBound


test_word2Words :: HUnit.Test
test_word2Words = "test_word2Words" ~: HUnit.TestCase $ do
    UDP.word2Words 0 @?= [0]
    UDP.word2Words 1 @?= [1]
    UDP.word2Words 128 @?= [128]
    UDP.word2Words 256 @?= [1, 0]
    UDP.word2Words maxBound @?= [255, 255, 255, 255, 255, 255, 255, 255]


test_intRoundTrip :: HUnit.Test
test_intRoundTrip = "test_intRoundTrip" ~: HUnit.TestCase $ do
    rt 0
    rt 1
    rt (-1)
    rt (-2)
    rt 128
    rt 255
    rt 256
    rt minBound
    rt maxBound
    where rt n = UDP.words2Int (UDP.int2Words n) @?= n


test_berLength :: HUnit.Test
test_berLength = "test_berLength" ~: HUnit.TestCase $ do
    UDP.berLength 0 @?= [0]
    UDP.berLength 1 @?= [1]
    UDP.berLength 127 @?= [127]
    UDP.berLength 128 @?= [129, 128]
    UDP.berLength 256 @?= [130, 1, 0]
    UDP.berLength 65535 @?= [130, 255, 255]
    UDP.berLength 65536 @?= [131, 1, 0, 0]


compareLBS actual expect = do
    UDP.prettyHex (LazyBS.toStrict actual) @?= UDP.prettyHex (LazyBS.toStrict expect)


test_encodeBERInt :: HUnit.Test
test_encodeBERInt = "test_encodeBERInt" ~: HUnit.TestCase $ do
    compareLBS
        (UDP.encodeBERInt 0)
        (LazyBS.pack [2, 1, 0])
    compareLBS
        (UDP.encodeBERInt 1)
        (LazyBS.pack [2, 1, 1])
    -- compareLBS
    --     (UDP.encodeBERInt (-1))
    --     (LazyBS.pack [2, 1, 1])
    compareLBS
        (UDP.encodeBERInt (256))
        (LazyBS.pack [2, 2, 1, 0])


test_encodeBERString :: HUnit.Test
test_encodeBERString = "encodeBERString" ~: HUnit.TestCase $ do
    compareLBS
        (UDP.encodeBERString "a")
        (LazyBS.pack [4, 1, 97])

ifTableOid = ".1.3.6.1.2.1.2.2.0"

test_encodeBEROid :: HUnit.Test
test_encodeBEROid = "test_encodeBEROid" ~: HUnit.TestCase $ do
    compareLBS
        (UDP.encodeBEROid ifTableOid)
        (LazyBS.pack [6, 8, 43, 6, 1, 2, 1, 2, 2, 0])
    compareLBS
        (UDP.encodeBEROid ".1.3.127.128.255.16383.16384")
        (LazyBS.pack [6, 11, 43, 127, 129, 0, 129, 127, 255, 127, 129, 128, 0])
    compareLBS
        (UDP.encodeBEROid ".1.3.255.256.1024.65536")
        (LazyBS.pack [6, 10, 43, 129, 127, 130, 0, 136, 0, 132, 128, 0])


test_makeGetRequest :: HUnit.Test
test_makeGetRequest = "test_makeGetRequest" ~: HUnit.TestCase $ do
    compareLBS
        (UDP.makeGetRequest 0 "x" [".1.3.1"])
        (LazyBS.pack (
            48 :  -- type sequence
            27 :  -- len 27
            2  :    -- type int
            1  :    -- len 1
            1  :    -- snmpv2
            4  :    -- type string
            1  :    -- len 1
            120 :   -- x
            160 :   -- type GetRequest
            19 :    -- len 19
            2  :      -- type int (request-id)
            1  :      -- len 1
            0  :      -- value 0
            2  :      -- type int (error-status)
            1  :      -- len 1
            0  :      -- value 0
            2  :      -- type int (error-index)
            1  :      -- len 1
            0  :      -- value 0
            48 :      -- type sequence (varbindings)
            8  :      -- len 8
            48 :        -- type sequence (varbind)
            6  :        -- len 6
            6  :          -- type oid
            2  :          -- len 2
            43 :          -- 0x2b
            1  :          -- .1.3.1
            5  :          -- type null
            0  :          -- len 0
            []))


udpTests :: HUnit.Test
udpTests = HUnit.TestList (
    test_word2Words :
    test_words2Int :
    test_int2Words :
    test_intRoundTrip :
    test_berLength :
    test_encodeBERInt :
    test_encodeBERString :
    test_encodeBEROid :
    test_makeGetRequest :
    [])
