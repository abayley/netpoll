-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Protocol.SNMP.UDP
-- Copyright   :  (c) Alistair Bayley
-- License     :  GPL
--
-- Maintainer  :  alistair@abayley.org
-- Stability   :  experimental
-- Portability :  portable
--
-- Construct and deconstruct (parse) SNMP UDP packets.
-- Only supports a minimal subset of SNMP primitive types:
-- Int, String, OID.
--
-----------------------------------------------------------------------------
module Network.Protocol.SNMP.UDP where

import qualified Data.Attoparsec.ByteString as AttoPBS
import qualified Data.Bits as Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LazyBS
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Builder as Builder
import qualified Data.Char as Char
import qualified Data.Foldable as Foldable
import qualified Data.Int as Int
import qualified Data.List as List
import qualified Data.List.Split as Split
import qualified Data.Monoid as Monoid
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Text.Encoding.Error as EncodingError
import qualified Data.Word as Word
import qualified Numeric


{-
http://luca.ntop.org/Teaching/Appunti/asn1.html

The data returned by SocketBS.recvFrom does not include the
UDP headers; it seems to be just the payload.

SNMP V2 Packet
========================
SNMP packets are encoded with the ASN.1 BER (Base Encoding
Rules). The rules are (summary, more detail below):
  - all values are encoded as type-length-value
  - type is a single byte
  - lengths < 128 are encoded as single byte
  - lengths > 127 are encoded as 128 + n
    (where n is the number of bytes required to encode the length)
    followed by the length value
  - strings encoded as-is (we use utf8 encoding)
  - signed integers are encoded as 2s-complement
    with a variable number of bytes.
  - unsigned integers encoded as-is (big-endian)
  - oids are encoded as a byte for each number in the oid.
    If an element id > 127 then it is encoded as a sequence
    where the high bit of every byte is set, and the lower
    7 bits hold the integer value; the sequence is terminated
    by a byte with the high bit clear.

Common datatypes are:
01 BOOLEAN
02 INTEGER
03 BIT STRING
04 OCTET STRING
05 NULL
06 OBJECT IDENTIFIER
30 SEQUENCE
40 IpAddress
41 Counter32
42 Gauge32
43 TimeTicks
44 Opaque
45 NapsAddress
46 Counter64
47 Gauge64
80 NoObject
81 NoInstance
82 EndOfMIB
a0 GetRequest
a1 GetNextRequest
a2 GetResponse
a4 Trap (v1 only - obsolete)
a5 GetBulkRequest
a6 InformRequest
a7 Trap (v2)

The SNMP PDU always starts with SEQUENCE (0x30).
The overall structure of the PDU is (i.e the sequence contains):
  - version (0 = v1, 1 = v2c)
  - community string
  - sequence of fields

If it is not a trap, then the sequence of fields is:
  - request-id INTEGER
  - error-status INTEGER
  - error-index INTEGER
  - var bindings SEQUENCE

And each varbind is a pair of oid+value (so we use another
sequence to enclose the pair):
  - SEQUENCE
    - OID
    - value

For requests error-status and error-index are both zero
i.e. they are only filled in for responses.
For GetBulk requests error-status becomes non-repeaters
and error-index becomes max-repetitions.

So for this snmpget example:
  snmpget -v 2c -c ab localhost sysObjectID.0
  (sysObjectID.0 is .1.3.6.1.2.1.1.2.0)

the request PDU (length 37 bytes) is like so:
--------------------------------------
0x30 type: SEQUENCE
0x23 length 35
--------------------------------------
  0x02 type: INTEGER (version)
  0x01 length 1
  0x01 1 == v2c, 0 == v1
  --------------------------------------
  0x04 type: OCTET STRING (community string)
  0x02 length 2
  0x61 a
  0x62 b
  --------------------------------------
  0xa0 type: GetRequest
  0x1a length 26
  --------------------------------------
    0x02 type: INTEGER (request-id)
    0x02 length 2
    0x4d
    0x70
    --------------------------------------
    0x02 type: INTEGER (error-status)
    0x01 length 1
    0x00 0 (always 0 for requests)
    --------------------------------------
    0x02 type: INTEGER (error-index)
    0x01 length 1
    0x00 0 (always 0 for requests)
    --------------------------------------
    0x30 type: SEQUENCE (varbindings)
    0x0e length 14
    --------------------------------------
      0x30 type: SEQUENCE (varbind)
      0x0c length 12
      --------------------------------------
        0x06 type: OBJECT IDENTIFER (oid)
        0x08 length 8
        0x2b
        0x06
        0x01
        0x02
        0x01
        0x01
        0x02
        0x00 .1.3.6.1.2.1.1.2.0
        --------------------------------------
        0x05 type: NULL
        0x00 length 0
-}

snmpTypeString :: Word.Word8
snmpTypeString = 4
snmpTypeInt :: Word.Word8
snmpTypeInt = 2
snmpTypeSequence :: Word.Word8
snmpTypeSequence = 48
snmpTypeOid :: Word.Word8
snmpTypeOid = 6
snmpTypeCounter32 :: Word.Word8
snmpTypeCounter32 = 65
snmpTypeGauge32 :: Word.Word8
snmpTypeGauge32 = 66
snmpTypeCounter64 :: Word.Word8
snmpTypeCounter64 = 70
snmpTypeGauge64 :: Word.Word8
snmpTypeGauge64 = 71
snmpTypeVarbindNoObject :: Word.Word8
snmpTypeVarbindNoObject = 128
snmpTypeVarbindNoInstance :: Word.Word8
snmpTypeVarbindNoInstance = 129
snmpTypeVarbindEndOfMIB :: Word.Word8
snmpTypeVarbindEndOfMIB = 130
snmpTypeGetRequest :: Word.Word8
snmpTypeGetRequest = 160
snmpTypeGetResponse :: Word.Word8
snmpTypeGetResponse = 162


highBitSet :: [Word.Word8] -> Bool
highBitSet [] = False
highBitSet (h:_) = h > 127


-- Convert a Word into a sequence of bytes.
-- For unsigned types (Counter and Gauge).
word2Words :: Word.Word64 -> [Word.Word8]
word2Words 0 = [0]
word2Words n = g n [] where
    g 0 acc = acc
    -- shiftR makes number smaller.
    g i acc = g (Bits.shiftR i 8) (fromIntegral (i Bits..&. 255) : acc)


-- For Counter and Gauge types (unsigned).
words2Word :: [Word.Word8] -> Word.Word64
words2Word s = g s 0 where
    g [] n = n
    g (w:ws) n = g ws (Bits.shiftL n 8 + fromIntegral w)


-- Convert an Int into a sequence of bytes:
-- the two's-complement representation.
-- For INTEGER (signed).
int2Words :: Int.Int64 -> [Word.Word8]
-- Special case that does not fit the code below
int2Words n | n == -1 = [255]
int2Words n | n >= 0 =
    if highBitSet ws then 0:ws else ws where
    ws = word2Words (fromIntegral n)
int2Words n =  -- n < 0
    if not (highBitSet ws) then 255:ws else ws where
    ws = map Bits.complement (word2Words (fromIntegral (abs (n+1))))


-- Convert a sequence of bytes (two's complement)
-- into an Int.
words2Int :: [Word.Word8] -> Int.Int64
words2Int [] = 0
words2Int s@(w1:_) =
    -- -positive
    if w1 < 128 then fromIntegral (words2Word s)
    -- negative
    else negate (1 + fromIntegral (words2Word (map Bits.complement s)))


{-
When encoding OIDs the first 2 elements of the OID sequence
(.iso.org) are compressed into a single byte by the formula:
    40 * e1 + e2
e.g. .1.3 -> 0x2b

The OID integers are encoded with different BER rules from integers.
It is a sequence of bytes terminated by a byte < 128.
The bytes preceding the last must have their high bit set.
The value is constructed by removing the high bits and
concatenating the lower 7 bite from each byte.

.1.3.128.256.257.65535.16777216:
0x06  type
0x0e  length
0x2b  .1.3
0x81 0x00  .128  1000 0001  0000 0000
0x82 0x00  .256  1000 0010  0000 0000
0x83 0xff 0x7f  .65535  1000 0011  1111 1111  0111 1111

.1.3.255.256.257.1024:
0x06  type
0x09  length
0x2b  .1.3
0x81 0x7f  .255
0x82 0x00  .256
0x82 0x01  .257
0x88 0x00  .1024
-}

oidInt2Words :: Word.Word64 -> [Word.Word8]
oidInt2Words i = if i < 128 then [fromIntegral i]
    -- shiftR makes number smaller.
    -- The last byte must be < 128; every other must be > 127.
    else g (Bits.shiftR i 7) [fromIntegral (i Bits..&. 127)]
    where
    g 0 acc = acc
    g n acc = g (Bits.shiftR n 7) ((fromIntegral (128 + n Bits..&. 127)) : acc)


oidString2Words :: String -> [Word.Word8]
oidString2Words s =
    let
        ints = map read (drop 1 (Split.splitOn "." s))
        (i1:i2:i3) = ints
        w1 = fromIntegral (40 * i1 + i2)
    in w1 : (List.concat (List.map oidInt2Words i3))


-- consume a single OID integer from the stream of words,
-- and return it plus the remaining uncomsumed words
words2OidInt :: [Word.Word8] -> (Word.Word64, [Word.Word8])
words2OidInt s = go s 0 where
    go [] n = (n, [])
    go (h:t) n = if h < 128 then (n + fromIntegral h, t)
        -- strip off high bit, add, shift up by 7 bits.
        else go t (Bits.shiftL (n + fromIntegral (h Bits..&. 127)) 7)


decodeOidFirstWord :: Word.Word8 -> [Word.Word64]
decodeOidFirstWord w = [fromIntegral (quot w 40), fromIntegral (rem w 40)]


words2Oid :: [Word.Word8] -> [Word.Word64]
words2Oid [] = []
words2Oid (w1:ws) = decodeOidFirstWord w1 ++ w2o ws
    where
    w2o [] = []
    w2o s = let (n, r) = words2OidInt s in n : w2o r


-- Encode length of value with BER.
-- If length < 128 then just length, otherwise
-- 128 + number of byes followed by the int as bytes.
-- e.g.
--   length 127 (0x7f) is encoded as 0x7f
--   length 128 (0x80) is encoded as 0x81 0x80
--   length 255 (0x80) is encoded as 0x81 0xff
--   length 256 (0x0100) is encoded as 0x82 0x01 0x00
berLength :: Word.Word64 -> [Word.Word8]
berLength l = if l < 128 then [fromIntegral l] else
    (fromIntegral (128 + List.length bytes)) : bytes
    where bytes = word2Words l


-- We use Lazy ByteStrings here (rather than Builders)
-- because we need to know the length of each piece.
-- I do wonder if it would be better to just have the
-- functions return [Word.Word8], but I also believe
-- small ByteStrings are copy-combined, so you don't get
-- much overhead in terms of storage (and chained appends).
-- Besides, ByteString comes with a convenient functions
-- to encode a String via UTF8; I have not found an
-- equivalent for Word8 yet.

bsLen :: LazyBS.ByteString -> [Word.Word8]
bsLen lbs = berLength (fromIntegral (LazyBS.length lbs))


-- | UTF8-encode a String into a ByteString.
encodeBERString :: String -> LazyBS.ByteString
encodeBERString s = LazyBS.append prefix lbs where
    lbs = Builder.toLazyByteString . Foldable.foldMap Builder.charUtf8 $ s
    prefix = LazyBS.pack (snmpTypeString : bsLen lbs)


encodeBERInt :: Int.Int64 -> LazyBS.ByteString
encodeBERInt i = LazyBS.append prefix lbs where
    lbs = LazyBS.pack (int2Words i)
    prefix = LazyBS.pack (snmpTypeInt : bsLen lbs)


encodeBERWord :: Word.Word64 -> LazyBS.ByteString
encodeBERWord i = LazyBS.append prefix lbs where
    lbs = LazyBS.pack (word2Words i)
    prefix = LazyBS.pack (snmpTypeInt : bsLen lbs)


-- seqType is either snmpTypeSequence or snmpTypeGetRequest
encodeBERSequence :: Word.Word8 -> LazyBS.ByteString -> LazyBS.ByteString
encodeBERSequence seqType lbs = LazyBS.append prefix lbs where
    prefix = LazyBS.pack (seqType : bsLen lbs)


encodeBEROid :: String -> LazyBS.ByteString
encodeBEROid oid = LazyBS.append prefix lbs where
    lbs = LazyBS.pack (oidString2Words oid)
    prefix = LazyBS.pack (snmpTypeOid : bsLen lbs)


nullValue :: LazyBS.ByteString
nullValue = LazyBS.pack [5, 0]


-- We only need to generate get requests, although
-- we do want to be able to get multiple OIDs in a
-- single request.
-- So to support that we only need to encode:
--    SEQUENCE
--    INTEGER
--    OCTET STRING
--    OBJECT IDENTIFIER

snmpV1 :: Word.Word64
snmpV1 = 0
snmpV2 :: Word.Word64
snmpV2 = 1


infixr 4 <>
(<>) :: Monoid.Monoid m => m -> m -> m
(<>) = Monoid.mappend


makeGetRequest :: Word.Word64 -> String -> [String] -> LazyBS.ByteString
makeGetRequest reqid community oids =
    encodeBERSequence snmpTypeSequence (
        encodeBERWord snmpV2
        <> encodeBERString community
        <> encodeBERSequence snmpTypeGetRequest (
            encodeBERWord reqid -- request-id
            <> encodeBERWord 0 -- error-status
            <> encodeBERWord 0 -- error-index
            <> encodeBERSequence snmpTypeSequence (
                LazyBS.concat (List.map encodeOid oids)
                )
            )
        )
    where
    encodeOid oid = encodeBERSequence snmpTypeSequence
        (encodeBEROid oid <> nullValue)


data SnmpResponse =
    SnmpSequence [SnmpResponse]
    | SnmpGetResponse [SnmpResponse]
    | SnmpGetRequest [SnmpResponse]
    | SnmpInt Int.Int64
    | SnmpWord Word.Word64
    | SnmpString String
    | SnmpOid [Word.Word64]
    -- invalid OIDs do not result in non-zero error codes.
    -- Instead the OID is returned with a value of one of the
    -- invalid OID types.
    -- We save the type tag in the SnmpBadOid value here.
    | SnmpBadOid Word.Word8
    | SnmpUnknown Word.Word8 [Word.Word8]
    deriving (Eq, Ord, Read, Show)


parseBERLength :: AttoPBS.Parser Word.Word64
parseBERLength = do
    l <- AttoPBS.anyWord8
    if l < 128 then return (fromIntegral l)
    else do
        bs <- AttoPBS.take (fromIntegral (l Bits..&. 127))
        return (words2Word (BS.unpack bs))


-- parseVal is really just a helper for parseValue
parseVal :: Word.Word8 -> BS.ByteString -> AttoPBS.Parser SnmpResponse
parseVal t bs
    | t == snmpTypeSequence = parseSequence SnmpSequence
    | t == snmpTypeGetResponse = parseSequence SnmpGetResponse
    | t == snmpTypeGetRequest = parseSequence SnmpGetRequest
    | t == snmpTypeInt = return (SnmpInt (words2Int (BS.unpack bs)))
    | t == snmpTypeCounter32 = parseWord
    | t == snmpTypeGauge32 = parseWord
    | t == snmpTypeCounter64 = parseWord
    | t == snmpTypeGauge64 = parseWord
    | elem t [snmpTypeVarbindNoObject,
              snmpTypeVarbindNoInstance,
              snmpTypeVarbindEndOfMIB] = return (SnmpBadOid t)
    | t == snmpTypeString = return (SnmpString (Text.unpack
        (Encoding.decodeUtf8With EncodingError.lenientDecode bs)))
    | t == snmpTypeOid = return (SnmpOid (words2Oid (BS.unpack bs)))
    | otherwise = return (SnmpUnknown t (BS.unpack bs))
    where
    parseWord = return (SnmpWord (words2Word (BS.unpack bs)))
    parseSequence constr =
        either fail return
            (AttoPBS.parseOnly (AttoPBS.many1 parseValue) bs)
        >>= return . constr


parseValue :: AttoPBS.Parser SnmpResponse
parseValue = do
    t <- AttoPBS.anyWord8
    len <- parseBERLength
    bs <- AttoPBS.take (fromIntegral len)
    parseVal t bs


parseSnmpResponse :: BS.ByteString -> Either String SnmpResponse
parseSnmpResponse = AttoPBS.parseOnly parseValue


-- Stolen from:
-- https://hackage.haskell.org/package/pretty-hex
prettyHex :: BS.ByteString -> String
prettyHex bs = unlines (header : body) where
    byteWidth = 2
    numWordBytes = 4
    hexDisplayWidtb = 50  -- display panel
    numLineWords = 4  -- words on line
    addressWidth = 4  -- min width of padded address
    numLineBytes :: Int
    numLineBytes = numLineWords * numWordBytes  -- bytes on a line
    replacementChar = '.'  -- for non-printables

    header = "Length: " ++ show (BS.length bs)
        ++ " (0x" ++ Numeric.showHex (BS.length bs) ") bytes"

    body :: [String]
    body = List.map (List.intercalate "   ")
        $ List.transpose [mkLineNumbers bs, mkHexDisplay bs, mkAsciiDump bs]

    mkHexDisplay :: BS.ByteString -> [String]
    mkHexDisplay
        = padLast hexDisplayWidtb
        . List.map (List.intercalate "  ") . group numLineWords
        . List.map (List.intercalate " ") . group numWordBytes
        . List.map (paddedShowHex byteWidth)
        . BS.unpack

    mkAsciiDump :: BS.ByteString -> [String]
    mkAsciiDump = group numLineBytes . cleanString . Char8.unpack

    cleanString :: String -> String
    cleanString = List.map go where
        go x | isWorthPrinting x = x
             | otherwise = replacementChar

    mkLineNumbers :: BS.ByteString -> [String]
    mkLineNumbers s = [paddedShowHex addressWidth (x * numLineBytes) ++ ":"
        | x <- [0 .. (BS.length s - 1) `div` numLineBytes] ]

    padLast :: Int -> [String] -> [String]
    padLast w [x] = [x ++ List.replicate (w - List.length x) ' ']
    padLast w (x:xs) = x : padLast w xs
    padLast _ [] = []

    isWorthPrinting :: Char -> Bool
    isWorthPrinting x = Char.isAscii x && not (Char.isControl x)

    -- 'group' breaks up a list into sublists of size @n@. The last group
    -- may be smaller than @n@ elements. When @n@ less not positive the
    -- list is returned as one sublist.
    group :: Int -> [a] -> [[a]]
    group n
     | n <= 0    = (:[])
     | otherwise = List.unfoldr go
      where
        go [] = Nothing
        go xs = Just (splitAt n xs)

    paddedShowHex :: (Show a, Integral a) => Int -> a -> String
    paddedShowHex w n = pad ++ str where
        str = Numeric.showHex n ""
        pad = List.replicate (w - List.length str) '0'
