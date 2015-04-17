{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Protocol.SNMP.Process
-- Copyright   :  (c) Alistair Bayley
-- License     :  GPL
--
-- Maintainer  :  alistair@abayley.org
-- Stability   :  experimental
-- Portability :  portable
--
-- An SNMP library which shells out to the net-snmp command line programs.
-- Uses a Text-based process library and returns string results as Text.
--
-----------------------------------------------------------------------------
module Network.Protocol.SNMP.Process where

import qualified Control.Monad.Trans.Error as Error
import qualified Data.Char as Char
import qualified Data.IORef as IORef
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Traversable as Traversable
import qualified Data.Word as Word
import qualified System.Exit as Exit
import qualified System.Process.Text as ProcessText
import qualified Text.Read as Read
-- import qualified Data.Text.IO as TextIO
-- import qualified System.IO as IO


-- INTEGER and Integer32 are indistinguishable
-- See SNMPv2-SMI::Integer32

-- SNMPValue combines type and value.
-- Not sure if this is a good idea or not.
data SNMPValue = 
    Integer Int Text.Text
    | TruthValue Bool
    | Timeticks Word.Word32
    | DateAndTime Text.Text
    | DisplayString Text.Text
    | Counter32 Word.Word32
    | Counter64 Word.Word64
    | Unsigned32 Word.Word32
    | IpAddress Text.Text
    | Gauge32 Word.Word32
    | OID Text.Text
    | Unknown Text.Text Text.Text
    deriving (Eq, Ord, Show, Read)


type HostName = String
type OID = String
type NumericOID = [Int]
type Community =  String
type ErrorMsg = (Int, Text.Text)
type SNMPResult = (Text.Text, SNMPValue)
-- how to model SNMP tables?
-- It would be nice to be able to index
-- values by index + column name.
--   table : index -> row
--   row : column -> value
type SNMPTableRow = Map.Map Text.Text SNMPValue
type SNMPTable = Map.Map NumericOID SNMPTableRow

-- FIXME TODO add iterations, timeouts, retries
data SNMPOptions = SNMPOptions
    { snmpVersion :: String
    , snmpMibs :: [String]
    , snmpFlags :: [String]
    , snmpInputOpts :: String
    , snmpOutputOpts :: String
    , snmpCommand :: String
    , snmpSession :: SNMPSession
    }
    deriving (Eq)

defaultOptions :: IO SNMPOptions
defaultOptions = do
    sess <- defaultSession
    return (SNMPOptions "2c" [] ["-Pud"] "" "f" "snmpget" sess)


type TranslationCache = IORef.IORef (Map.Map Text.Text Text.Text)
data SNMPSession = SNMPSession
    { sessionTranslateNameCache :: TranslationCache
    , sessionTranslateOidCache  :: TranslationCache
    , sessionCanonicalNameCache :: TranslationCache
    }
    deriving (Eq)

defaultSession :: IO SNMPSession
defaultSession = do
    cache1 <- IORef.newIORef (Map.empty)
    cache2 <- IORef.newIORef (Map.empty)
    cache3 <- IORef.newIORef (Map.empty)
    return (SNMPSession cache1 cache2 cache3)


-- Return text found between first pair of parens
betweenParens :: Text.Text -> Text.Text
betweenParens s =
    Text.takeWhile (/= ')') . Text.drop 1 . Text.dropWhile (/= '(') $ s


parseTimeticks :: Word.Word32 -> Text.Text -> Word.Word32
parseTimeticks def s =
    case Read.readEither . Text.unpack . betweenParens $ s of
        Right n -> n
        Left _ -> def


readText :: Read a => a -> Text.Text -> a
readText def s = case Read.readEither . Text.unpack $ s of
    Right n -> n
    Left _ -> def


-- INTEGER types are printed in 2 ways (that I know of):
-- INTEGER: up(1)
-- INTEGER: 1500
-- i.e. the first one is like an enum.
-- This function handles both cases.
parseInteger :: Text.Text -> SNMPValue
parseInteger s = 
    if hasParens s
        then Integer (readText 0 . betweenParens $ s) (beforeParens s)
        else Integer (readText 0 . Text.takeWhile Char.isDigit $ s) (Text.empty)
    where
        beforeParens = Text.takeWhile (/= '(')
        hasParens s1 = maybe False (const True) (Text.find (== '(') s1)


makeSNMPValue :: Text.Text -> Text.Text -> SNMPValue
makeSNMPValue typ value =
    case () of
      _ | typ == "OID" -> OID value
        | typ == "STRING" -> DisplayString value
        | typ == "INTEGER" -> parseInteger value
        | typ == "Timeticks" -> Timeticks (parseTimeticks 0 value)
        | typ == "Gauge32" -> Gauge32 (readText 0 value)
        | typ == "Counter32" -> Counter32 (readText 0 value)
        | typ == "Counter64" -> Counter64 (readText 0 value)
        | otherwise -> Unknown typ value


-- | Parse a single return value in the format:
-- oid = type: value
-- Returns a pair of (oid, value)
-- where value has type SNMPValue,
-- which includes both the value and the type.
parseOid :: Text.Text -> SNMPResult
parseOid line = (oid, value) where
    (oid, typevalue) = Text.breakOn " =" line
    (typ, val) = Text.breakOn ":" typevalue
    typ1 = Text.strip (Text.drop 2 typ)
    value = makeSNMPValue typ1 (Text.drop 2 val)


buildSnmpOpts :: String -> String -> [String]
buildSnmpOpts prefix options =
    if List.null options then []
        else [prefix ++ options]


commonSnmpOpts :: SNMPOptions -> [String]
commonSnmpOpts options = 
    snmpFlags options ++ inputOpts ++ outputOpts ++ mibs
    where
        mibs = buildSnmpOpts "-m" (List.intercalate "," (snmpMibs options))
        inputOpts = buildSnmpOpts "-I" (snmpInputOpts options)
        outputOpts = buildSnmpOpts "-O" (snmpOutputOpts options)


-- | An snmp command that returns one or more values,
-- one value per line, in the format:
-- oid = type: value
snmpGetMultiple :: HostName -> [OID] -> Community -> SNMPOptions -> IO (Either ErrorMsg [SNMPResult])
snmpGetMultiple hostName oids community options = do
    let opts = ["-v", snmpVersion options, "-c", community] ++ commonSnmpOpts options
    let args = opts ++ [hostName] ++ oids
    (exitCode, _stdout, _stderr) <- ProcessText.readProcessWithExitCode (snmpCommand options) args Text.empty
    case exitCode of
        Exit.ExitFailure n -> return (Left (n, _stderr))
        Exit.ExitSuccess -> return (Right (map parseOid (Text.lines _stdout)))


-- | An snmp command run locally that returns a single value
-- on one line. Does not hit the network, so does not use
-- snmp version or community string.
snmpTranslate :: Text.Text -> SNMPOptions -> IO (Either ErrorMsg Text.Text)
snmpTranslate oid options = do
    let args = commonSnmpOpts options ++ [Text.unpack oid]
    (exitCode, _stdout, _stderr) <- ProcessText.readProcessWithExitCode (snmpCommand options) args Text.empty
    case exitCode of
        Exit.ExitFailure n -> return (Left (n, _stderr))
        Exit.ExitSuccess -> return (Right (head (Text.lines _stdout)))


snmpGet :: HostName -> [OID] -> Community -> SNMPOptions -> IO (Either ErrorMsg [SNMPResult])
snmpGet = snmpGetMultiple

-- | snmpwalk uses -CI (exclude given OID)
-- I think snmpbulkwalk excludes given OID by default;
-- -Ci includes it.
-- snmpbulkwalk uses -Crn where n = iterations
-- both use -t n -r n -OfU -Pud
-- snmpget uses -t n -r n -OnU -Pud

snmpWalk :: HostName -> OID -> Community -> SNMPOptions -> Int -> IO (Either ErrorMsg [SNMPResult])
snmpWalk hostName oid community options iterations = do
    let opts = options {snmpCommand = "snmpbulkwalk", snmpFlags = ["-Pud", "-Cr" ++ show iterations]}
    snmpGetMultiple hostName [oid] community opts


addToCache :: TranslationCache -> Text.Text -> Either ErrorMsg Text.Text -> IO ()
addToCache cache oid result = do
    case result of
        Left _ -> return ()
        Right value -> do
            mapping <- IORef.readIORef cache
            let newmap = Map.insert oid value mapping
            IORef.atomicModifyIORef' cache (\_ -> (newmap, ()))


-- | All snmptranslate functions pass through here on the way
-- to snmpTranslate.
-- This is where we check the cache, and if the oid is not
-- in the cache, call the external command and add the result
-- to the cache.    
snmpCacheTranslate :: TranslationCache -> Text.Text -> SNMPOptions -> IO (Either ErrorMsg Text.Text)
snmpCacheTranslate cache oid options = do
    mapping <- IORef.readIORef cache
    case Map.lookup oid mapping of
        Just v -> return (Right v)
        Nothing -> do
            let opts = options { snmpCommand = "snmptranslate" }
            result <- snmpTranslate oid opts
            addToCache cache oid result
            return result


-- canonicalNames passes -IR -Of
-- translateNames passes -IR -On
-- translateOids passes -Iu -Of

-- | translate a numeric OID into a long named OID
snmpTranslateOid :: Text.Text -> SNMPOptions -> IO (Either ErrorMsg Text.Text)
snmpTranslateOid oid options = do
    let cache = sessionTranslateOidCache (snmpSession options)
    let opts = options { snmpInputOpts = "u", snmpOutputOpts = "f" }
    snmpCacheTranslate cache oid opts


-- | translate a named OID into a numerical OID
snmpTranslateName :: Text.Text -> SNMPOptions -> IO (Either ErrorMsg Text.Text)
snmpTranslateName oid options = do
    let cache = sessionTranslateNameCache (snmpSession options)
    let opts = options { snmpInputOpts = "R", snmpOutputOpts = "n" }
    snmpCacheTranslate cache oid opts


-- | translate an OID (name or numeric) into a long named oid
snmpCanonicalName :: Text.Text -> SNMPOptions -> IO (Either ErrorMsg Text.Text)
snmpCanonicalName oid options = do
    let cache = sessionCanonicalNameCache (snmpSession options)
    let opts = options { snmpInputOpts = "R", snmpOutputOpts = "f" }
    snmpCacheTranslate cache oid opts


-- | The SNMPTable constructed by parseSNMPTable contains
-- a lot of duplicated strings, in the column names.
-- Here we seek to replace them with references to
-- shared strings.
minimalSpaceTable :: SNMPTable -> SNMPTable
minimalSpaceTable table = Map.foldrWithKey' mkRow Map.empty table where
    -- take the column names (shared strings) from the first row
    colNames = Map.keys (head (Map.elems table))
    mkRow index row newtable = Map.insert index (Map.foldrWithKey' mkCol Map.empty row) newtable
    mkCol colname value newrow = Map.insert (lookupSharedColname colname) value newrow
    lookupSharedColname colname = maybe colname id (List.find (== colname) colNames)


-- | Turn a stream of SNMPResult into a table.
-- Each result has a full OID;
-- remove the table prefix, find the column name
-- and index, and use these to populate the map.
parseSNMPTable :: OID -> SNMPOptions -> [SNMPResult] -> IO (Either ErrorMsg SNMPTable)
parseSNMPTable tableOid options results = do
    eprefix <- snmpCanonicalName (Text.pack tableOid) options
    -- The invocation of snmpCanonicalName shouldn't normally fail,
    -- although the fork could fail with out-of-memory, etc.
    -- So a little ugliness here to handle that case.
    either (return . Left) (\prefix -> parseTable prefix Map.empty results) eprefix
    where
    -- Wrapper that changes stripPrefix semantics slightly.
    -- If the prefix is present then strip it, otherwise
    -- just return the original string.
    stripPrefix :: Text.Text -> Text.Text -> Text.Text
    stripPrefix pref str = maybe str id (Text.stripPrefix pref str)

    parseTable :: Text.Text -> SNMPTable -> [SNMPResult] -> IO (Either ErrorMsg SNMPTable)
    parseTable _      table [] = return (Right table)
    parseTable prefix table (r:rs) = do
        let (oid, value) = r
        -- After removing the table prefix the OID will be
        -- ".entry.column.index". strip will turn this into
        -- ["", "entry", "column", "index1", "index2", ...]
        -- and we want to recover "column" and "index".
        let (colname:indexlist) = drop 2 (Text.splitOn "." (stripPrefix prefix oid))
        -- let index = Text.intercalate "." indexlist
        let index = List.map (read . Text.unpack) indexlist
        -- Get current row (by index) from map.
        -- If it is not present then make a new one.
        let row = maybe Map.empty id (Map.lookup index table)
        let newrow = Map.insert colname value row
        let newtable = Map.insert index newrow table
        parseTable prefix newtable rs


-- | snmpTable uses a walk, rather than the snmptable command,
-- because some devices choke on the bulk walk that snmptable uses.
-- Also, the output from a walk is easier to parse then the
-- output from snmptable.
-- We emulate snmptable by reconstrucing a table from the walk.
snmpTable :: HostName -> OID -> [String]-> Community -> SNMPOptions -> IO (Either ErrorMsg SNMPTable)
snmpTable hostName oid columns community options = do
    result <- case columns of
        [] -> snmpWalk hostName oid community options 25
        -- If the user has specified columns, then we walk each
        -- column separately and join the results together.
        _ -> do
            -- We need to concatenate the results of multiple
            -- walks, but the return type is Either.
            -- Stop on the first Left.
            results <- Error.runErrorT . Traversable.sequenceA .
                map (\col -> Error.ErrorT (snmpWalk hostName col community options 25)) $ columns
            return (either Left (Right . concat) results)
    case result of
        Left errmsg -> return (Left errmsg)
        Right values -> do
            table <- parseSNMPTable oid options values
            return (either Left (Right . minimalSpaceTable) table)
