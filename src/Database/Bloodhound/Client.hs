{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

-------------------------------------------------------------------------------
-- |
-- Module : Database.Bloodhound.Client
-- Copyright : (C) 2014, 2018 Chris Allen
-- License : BSD-style (see the file LICENSE)
-- Maintainer : Chris Allen <cma@bitemyapp.com>
-- Stability : provisional
-- Portability : OverloadedStrings
--
-- Client side functions for talking to Elasticsearch servers.
--
-------------------------------------------------------------------------------

module Database.Bloodhound.Client
       ( -- * Bloodhound client functions
         -- | The examples in this module assume the following code has been run.
         --   The :{ and :} will only work in GHCi. You'll only need the data types
         --   and typeclass instances for the functions that make use of them.

         -- $setup
         withBH
       -- ** Indices
       , createIndex
       , createIndexWith
       , flushIndex
       , deleteIndex
       , updateIndexSettings
       , getIndexSettings
       , forceMergeIndex
       , indexExists
       , openIndex
       , closeIndex
       , listIndices
       , catIndices
       , waitForYellowIndex
       -- *** Index Aliases
       , updateIndexAliases
       , getIndexAliases
       , deleteIndexAlias
       -- *** Index Templates
       , putTemplate
       , templateExists
       , deleteTemplate
       -- ** Mapping
       , putMapping
       -- ** Documents
       , indexDocument
       , updateDocument
       , getDocument
       , documentExists
       , deleteDocument
       , deleteByQuery
       -- ** Searching
       , searchAll
       , searchByIndex
       , searchByIndices
       , searchByIndexTemplate
       , searchByIndicesTemplate
       , scanSearch
       , getInitialScroll
       , getInitialSortedScroll
       , advanceScroll
       , pitSearch
       , openPointInTime
       , closePointInTime
       , refreshIndex
       , mkSearch
       , mkAggregateSearch
       , mkHighlightSearch
       , mkSearchTemplate
       , bulk
       , pageSearch
       , mkShardCount
       , mkReplicaCount
       , getStatus
       -- ** Templates
       , storeSearchTemplate
       , getSearchTemplate
       , deleteSearchTemplate
       -- ** Snapshot/Restore
       -- *** Snapshot Repos
       , getSnapshotRepos
       , updateSnapshotRepo
       , verifySnapshotRepo
       , deleteSnapshotRepo
       -- *** Snapshots
       , createSnapshot
       , getSnapshots
       , deleteSnapshot
       -- *** Restoring Snapshots
       , restoreSnapshot
       -- ** Nodes
       , getNodesInfo
       , getNodesStats
       -- ** Request Utilities
       , encodeBulkOperations
       , encodeBulkOperation
       -- * Authentication
       , basicAuthHook
       -- * Reply-handling tools
       , isVersionConflict
       , isSuccess
       , isCreated
       , parseEsResponse
       -- * Count
       , countByIndex
       )
       where

import qualified Blaze.ByteString.Builder     as BB
import           Control.Applicative          as A
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.ByteString.Lazy.Builder
import qualified Data.ByteString.Lazy.Char8   as L
import           Data.Foldable                (toList)
import qualified Data.HashMap.Strict          as HM
import           Data.Ix
import qualified Data.List                    as LS (foldl')
import           Data.List.NonEmpty           (NonEmpty (..))
import           Data.Maybe                   (catMaybes, fromMaybe)
import           Data.Monoid
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Text.Encoding           as T
import           Data.Time.Clock
import qualified Data.Vector                  as V
import           Network.HTTP.Client
import qualified Network.HTTP.Types.Method    as NHTM
import qualified Network.HTTP.Types.Status    as NHTS
import qualified Network.HTTP.Types.URI       as NHTU
import qualified Network.URI                  as URI
import           Prelude                      hiding (filter, head)

import           Database.Bloodhound.Types

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> :set -XDeriveGeneric
-- >>> import Database.Bloodhound
-- >>> import Network.HTTP.Client
-- >>> let testServer = (Server "http://localhost:9200")
-- >>> let runBH' = withBH defaultManagerSettings testServer
-- >>> let testIndex = IndexName "twitter"
-- >>> let defaultIndexSettings = IndexSettings (ShardCount 1) (ReplicaCount 0)
-- >>> data TweetMapping = TweetMapping deriving (Eq, Show)
-- >>> _ <- runBH' $ deleteIndex testIndex
-- >>> _ <- runBH' $ deleteIndex (IndexName "didimakeanindex")
-- >>> import GHC.Generics
-- >>> import           Data.Time.Calendar        (Day (..))
-- >>> import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
-- >>> :{
--instance ToJSON TweetMapping where
--          toJSON TweetMapping =
--            object ["properties" .=
--              object ["location" .=
--                object ["type" .= ("geo_point" :: Text)]]]
--data Location = Location { lat :: Double
--                         , lon :: Double } deriving (Eq, Generic, Show)
--data Tweet = Tweet { user     :: Text
--                    , postDate :: UTCTime
--                    , message  :: Text
--                    , age      :: Int
--                    , location :: Location } deriving (Eq, Generic, Show)
--exampleTweet = Tweet { user     = "bitemyapp"
--                      , postDate = UTCTime
--                                   (ModifiedJulianDay 55000)
--                                   (secondsToDiffTime 10)
--                      , message  = "Use haskell!"
--                      , age      = 10000
--                      , location = Location 40.12 (-71.34) }
--instance ToJSON   Tweet where
--  toJSON = genericToJSON defaultOptions
--instance FromJSON Tweet where
--  parseJSON = genericParseJSON defaultOptions
--instance ToJSON   Location where
--  toJSON = genericToJSON defaultOptions
--instance FromJSON Location where
--  parseJSON = genericParseJSON defaultOptions
--data BulkTest = BulkTest { name :: Text } deriving (Eq, Generic, Show)
--instance FromJSON BulkTest where
--  parseJSON = genericParseJSON defaultOptions
--instance ToJSON BulkTest where
--  toJSON = genericToJSON defaultOptions
-- :}

-- | 'mkShardCount' is a straight-forward smart constructor for 'ShardCount'
--   which rejects 'Int' values below 1 and above 1000.
--
-- >>> mkShardCount 10
-- Just (ShardCount 10)
mkShardCount :: Int -> Maybe ShardCount
mkShardCount n
  | n < 1 = Nothing
  | n > 1000 = Nothing
  | otherwise = Just (ShardCount n)

-- | 'mkReplicaCount' is a straight-forward smart constructor for 'ReplicaCount'
--   which rejects 'Int' values below 0 and above 1000.
--
-- >>> mkReplicaCount 10
-- Just (ReplicaCount 10)
mkReplicaCount :: Int -> Maybe ReplicaCount
mkReplicaCount n
  | n < 0 = Nothing
  | n > 1000 = Nothing -- ...
  | otherwise = Just (ReplicaCount n)

emptyBody :: L.ByteString
emptyBody = L.pack ""

dispatch :: MonadBH m
         => Method
         -> Text
         -> Maybe L.ByteString
         -> m Reply
dispatch dMethod url body = do
  initReq <- liftIO $ parseUrl' url
  reqHook <- bhRequestHook A.<$> getBHEnv
  let reqBody = RequestBodyLBS $ fromMaybe emptyBody body
  req <- liftIO
         $ reqHook
         $ setRequestIgnoreStatus
         $ initReq { method = dMethod
                   , requestHeaders =
                     -- "application/x-ndjson" for bulk
                     ("Content-Type", "application/json") : requestHeaders initReq
                   , requestBody = reqBody }
  -- req <- liftIO $ reqHook $ setRequestIgnoreStatus $ initReq { method = dMethod
  --                                                            , requestBody = reqBody }
  mgr <- bhManager <$> getBHEnv
  liftIO $ httpLbs req mgr

joinPath' :: [Text] -> Text
joinPath' = T.intercalate "/"

joinPath :: MonadBH m => [Text] -> m Text
joinPath ps = do
  Server s <- bhServer <$> getBHEnv
  return $ joinPath' (s:ps)

appendSearchTypeParam :: Text -> SearchType -> Text
appendSearchTypeParam originalUrl st = addQuery params originalUrl
  where stText = "search_type"
        params
          | st == SearchTypeDfsQueryThenFetch = [(stText, Just "dfs_query_then_fetch")]
        -- used to catch 'SearchTypeQueryThenFetch', which is also the default
          | otherwise                         = []

-- | Severely dumbed down query renderer. Assumes your data doesn't
-- need any encoding
addQuery :: [(Text, Maybe Text)] -> Text -> Text
addQuery q u = u <> rendered
  where
    rendered =
      T.decodeUtf8 $ BB.toByteString $ NHTU.renderQueryText prependQuestionMark q
    prependQuestionMark = True

bindM2 :: (Applicative m, Monad m) => (a -> b -> m c) -> m a -> m b -> m c
bindM2 f ma mb = join (f <$> ma <*> mb)

-- | Convenience function that sets up a manager and BHEnv and runs
-- the given set of bloodhound operations. Connections will be
-- pipelined automatically in accordance with the given manager
-- settings in IO. If you've got your own monad transformer stack, you
-- should use 'runBH' directly.
withBH :: ManagerSettings -> Server -> BH IO a -> IO a
withBH ms s f = do
  mgr <- newManager ms
  let env = mkBHEnv s mgr
  runBH env f

-- Shortcut functions for HTTP methods
delete :: MonadBH m => Text -> m Reply
delete = flip (dispatch NHTM.methodDelete) Nothing
delete' :: MonadBH m => Text -> Maybe L.ByteString -> m Reply
delete' = dispatch NHTM.methodDelete
get    :: MonadBH m => Text -> m Reply
get    = flip (dispatch NHTM.methodGet) Nothing
head   :: MonadBH m => Text -> m Reply
head   = flip (dispatch NHTM.methodHead) Nothing
put    :: MonadBH m => Text -> Maybe L.ByteString -> m Reply
put    = dispatch NHTM.methodPut
post   :: MonadBH m => Text -> Maybe L.ByteString -> m Reply
post   = dispatch NHTM.methodPost

-- indexDocument s ix name doc = put (root </> s </> ix </> name </> doc) (Just encode doc)
-- http://hackage.haskell.org/package/http-client-lens-0.1.0/docs/Network-HTTP-Client-Lens.html
-- https://github.com/supki/libjenkins/blob/master/src/Jenkins/Rest/Internal.hs

-- | 'getStatus' fetches the 'Status' of a 'Server'
--
-- >>> serverStatus <- runBH' getStatus
-- >>> fmap tagline (serverStatus)
-- Just "You Know, for Search"
getStatus :: MonadBH m => m (Maybe Status)
getStatus = do
  response <- get =<< url
  return $ decode (responseBody response)
  where url = joinPath []

-- | 'getSnapshotRepos' gets the definitions of a subset of the
-- defined snapshot repos.
getSnapshotRepos
    :: ( MonadBH m
       , MonadThrow m
       )
    => SnapshotRepoSelection
    -> m (Either EsError [GenericSnapshotRepo])
getSnapshotRepos sel = fmap (fmap unGSRs) . parseEsResponse =<< get =<< url
  where
    url = joinPath ["_snapshot", selectorSeg]
    selectorSeg = case sel of
                    AllSnapshotRepos -> "_all"
                    SnapshotRepoList (p :| ps) -> T.intercalate "," (renderPat <$> (p:ps))
    renderPat (RepoPattern t)                  = t
    renderPat (ExactRepo (SnapshotRepoName t)) = t


-- | Wrapper to extract the list of 'GenericSnapshotRepo' in the
-- format they're returned in
newtype GSRs = GSRs { unGSRs :: [GenericSnapshotRepo] }


instance FromJSON GSRs where
  parseJSON = withObject "Collection of GenericSnapshotRepo" parse
    where
      parse = fmap GSRs . mapM (uncurry go) . HM.toList
      go rawName = withObject "GenericSnapshotRepo" $ \o ->
        GenericSnapshotRepo (SnapshotRepoName rawName) <$> o .: "type"
                                                       <*> o .: "settings"


-- | Create or update a snapshot repo
updateSnapshotRepo
  :: ( MonadBH m
     , SnapshotRepo repo
     )
  => SnapshotRepoUpdateSettings
  -- ^ Use 'defaultSnapshotRepoUpdateSettings' if unsure
  -> repo
  -> m Reply
updateSnapshotRepo SnapshotRepoUpdateSettings {..} repo =
  bindM2 put url (return (Just body))
  where
    url = addQuery params <$> joinPath ["_snapshot", snapshotRepoName gSnapshotRepoName]
    params
      | repoUpdateVerify = []
      | otherwise        = [("verify", Just "false")]
    body = encode $ object [ "type" .= gSnapshotRepoType
                           , "settings" .= gSnapshotRepoSettings
                           ]
    GenericSnapshotRepo {..} = toGSnapshotRepo repo



-- | Verify if a snapshot repo is working. __NOTE:__ this API did not
-- make it into Elasticsearch until 1.4. If you use an older version,
-- you will get an error here.
verifySnapshotRepo
    :: ( MonadBH m
       , MonadThrow m
       )
    => SnapshotRepoName
    -> m (Either EsError SnapshotVerification)
verifySnapshotRepo (SnapshotRepoName n) =
  parseEsResponse =<< bindM2 post url (return Nothing)
  where
    url = joinPath ["_snapshot", n, "_verify"]


deleteSnapshotRepo :: MonadBH m => SnapshotRepoName -> m Reply
deleteSnapshotRepo (SnapshotRepoName n) = delete =<< url
  where
    url = joinPath ["_snapshot", n]


-- | Create and start a snapshot
createSnapshot
    :: (MonadBH m)
    => SnapshotRepoName
    -> SnapshotName
    -> SnapshotCreateSettings
    -> m Reply
createSnapshot (SnapshotRepoName repoName)
               (SnapshotName snapName)
               SnapshotCreateSettings {..} =
  bindM2 put url (return (Just body))
  where
    url = addQuery params <$> joinPath ["_snapshot", repoName, snapName]
    params = [("wait_for_completion", Just (boolQP snapWaitForCompletion))]
    body = encode $ object prs
    prs = catMaybes [ ("indices" .=) . indexSelectionName <$> snapIndices
                    , Just ("ignore_unavailable" .= snapIgnoreUnavailable)
                    , Just ("ignore_global_state" .= snapIncludeGlobalState)
                    , Just ("partial" .= snapPartial)
                    ]


indexSelectionName :: IndexSelection -> Text
indexSelectionName AllIndexes            = "_all"
indexSelectionName (IndexList (i :| is)) = T.intercalate "," (renderIndex <$> (i:is))
  where
    renderIndex (IndexName n) = n


-- | Get info about known snapshots given a pattern and repo name.
getSnapshots
    :: ( MonadBH m
       , MonadThrow m
       )
    => SnapshotRepoName
    -> SnapshotSelection
    -> m (Either EsError [SnapshotInfo])
getSnapshots (SnapshotRepoName repoName) sel =
  fmap (fmap unSIs) . parseEsResponse =<< get =<< url
  where
    url = joinPath ["_snapshot", repoName, snapPath]
    snapPath = case sel of
      AllSnapshots -> "_all"
      SnapshotList (s :| ss) -> T.intercalate "," (renderPath <$> (s:ss))
    renderPath (SnapPattern t)              = t
    renderPath (ExactSnap (SnapshotName t)) = t


newtype SIs = SIs { unSIs :: [SnapshotInfo] }


instance FromJSON SIs where
  parseJSON = withObject "Collection of SnapshotInfo" parse
    where
      parse o = SIs <$> o .: "snapshots"


-- | Delete a snapshot. Cancels if it is running.
deleteSnapshot :: MonadBH m => SnapshotRepoName -> SnapshotName -> m Reply
deleteSnapshot (SnapshotRepoName repoName) (SnapshotName snapName) =
  delete =<< url
  where
    url = joinPath ["_snapshot", repoName, snapName]


-- | Restore a snapshot to the cluster See
-- <https://www.elastic.co/guide/en/elasticsearch/reference/1.7/modules-snapshots.html#_restore>
-- for more details.
restoreSnapshot
    :: MonadBH m
    => SnapshotRepoName
    -> SnapshotName
    -> SnapshotRestoreSettings
    -- ^ Start with 'defaultSnapshotRestoreSettings' and customize
    -- from there for reasonable defaults.
    -> m Reply
restoreSnapshot (SnapshotRepoName repoName)
                (SnapshotName snapName)
                SnapshotRestoreSettings {..} = bindM2 post url (return (Just body))
  where
    url = addQuery params <$> joinPath ["_snapshot", repoName, snapName, "_restore"]
    params = [("wait_for_completion", Just (boolQP snapRestoreWaitForCompletion))]
    body = encode (object prs)


    prs = catMaybes [ ("indices" .=) . indexSelectionName <$> snapRestoreIndices
                 , Just ("ignore_unavailable" .= snapRestoreIgnoreUnavailable)
                 , Just ("include_global_state" .= snapRestoreIncludeGlobalState)
                 , ("rename_pattern" .=) <$> snapRestoreRenamePattern
                 , ("rename_replacement" .=) . renderTokens <$> snapRestoreRenameReplacement
                 , Just ("include_aliases" .= snapRestoreIncludeAliases)
                 , ("index_settings" .= ) <$> snapRestoreIndexSettingsOverrides
                 , ("ignore_index_settings" .= ) <$> snapRestoreIgnoreIndexSettings
                 ]
    renderTokens (t :| ts) = mconcat (renderToken <$> (t:ts))
    renderToken (RRTLit t)      = t
    renderToken RRSubWholeMatch = "$0"
    renderToken (RRSubGroup g)  = T.pack (show (rrGroupRefNum g))


getNodesInfo
    :: ( MonadBH m
       , MonadThrow m
       )
    => NodeSelection
    -> m (Either EsError NodesInfo)
getNodesInfo sel = parseEsResponse =<< get =<< url
  where
    url = joinPath ["_nodes", selectionSeg]
    selectionSeg = case sel of
      LocalNode -> "_local"
      NodeList (l :| ls) -> T.intercalate "," (selToSeg <$> (l:ls))
      AllNodes -> "_all"
    selToSeg (NodeByName (NodeName n))            = n
    selToSeg (NodeByFullNodeId (FullNodeId i))    = i
    selToSeg (NodeByHost (Server s))              = s
    selToSeg (NodeByAttribute (NodeAttrName a) v) = a <> ":" <> v

getNodesStats
    :: ( MonadBH m
       , MonadThrow m
       )
    => NodeSelection
    -> m (Either EsError NodesStats)
getNodesStats sel = parseEsResponse =<< get =<< url
  where
    url = joinPath ["_nodes", selectionSeg, "stats"]
    selectionSeg = case sel of
      LocalNode -> "_local"
      NodeList (l :| ls) -> T.intercalate "," (selToSeg <$> (l:ls))
      AllNodes -> "_all"
    selToSeg (NodeByName (NodeName n))            = n
    selToSeg (NodeByFullNodeId (FullNodeId i))    = i
    selToSeg (NodeByHost (Server s))              = s
    selToSeg (NodeByAttribute (NodeAttrName a) v) = a <> ":" <> v

-- | 'createIndex' will create an index given a 'Server', 'IndexSettings', and an 'IndexName'.
--
-- >>> response <- runBH' $ createIndex defaultIndexSettings (IndexName "didimakeanindex")
-- >>> respIsTwoHunna response
-- True
-- >>> runBH' $ indexExists (IndexName "didimakeanindex")
-- True
createIndex :: MonadBH m => IndexSettings -> IndexName -> m Reply
createIndex indexSettings (IndexName indexName) =
  bindM2 put url (return body)
  where url = joinPath [indexName]
        body = Just $ encode indexSettings

-- | Create an index, providing it with any number of settings. This
--   is more expressive than 'createIndex' but makes is more verbose
--   for the common case of configuring only the shard count and
--   replica count.
createIndexWith :: MonadBH m
  => [UpdatableIndexSetting]
  -> Int -- ^ shard count
  -> IndexName
  -> m Reply
createIndexWith updates shards (IndexName indexName) =
  bindM2 put url (return (Just body))
  where url = joinPath [indexName]
        body = encode $ object
          ["settings" .= deepMerge
            ( HM.singleton "index.number_of_shards" (toJSON shards) :
              [u | Object u <- toJSON <$> updates]
            )
          ]

-- | 'flushIndex' will flush an index given a 'Server' and an 'IndexName'.
flushIndex :: MonadBH m => IndexName -> m Reply
flushIndex (IndexName indexName) = do
  path <- joinPath [indexName, "_flush"]
  post path Nothing

-- | 'deleteIndex' will delete an index given a 'Server' and an 'IndexName'.
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings (IndexName "didimakeanindex")
-- >>> response <- runBH' $ deleteIndex (IndexName "didimakeanindex")
-- >>> respIsTwoHunna response
-- True
-- >>> runBH' $ indexExists (IndexName "didimakeanindex")
-- False
deleteIndex :: MonadBH m => IndexName -> m Reply
deleteIndex (IndexName indexName) =
  delete =<< joinPath [indexName]

-- | 'updateIndexSettings' will apply a non-empty list of setting updates to an index
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings (IndexName "unconfiguredindex")
-- >>> response <- runBH' $ updateIndexSettings (BlocksWrite False :| []) (IndexName "unconfiguredindex")
-- >>> respIsTwoHunna response
-- True
updateIndexSettings :: MonadBH m => NonEmpty UpdatableIndexSetting -> IndexName -> m Reply
updateIndexSettings updates (IndexName indexName) =
  bindM2 put url (return body)
  where
    url = joinPath [indexName, "_settings"]
    body = Just (encode jsonBody)
    jsonBody = Object (deepMerge [u | Object u <- toJSON <$> toList updates])


getIndexSettings :: (MonadBH m, MonadThrow m) => IndexName
                 -> m (Either EsError IndexSettingsSummary)
getIndexSettings (IndexName indexName) =
  parseEsResponse =<< get =<< url
  where
    url = joinPath [indexName, "_settings"]

-- | 'forceMergeIndex'
--
-- The force merge API allows to force merging of one or more indices through
-- an API. The merge relates to the number of segments a Lucene index holds
-- within each shard. The force merge operation allows to reduce the number of
-- segments by merging them.
--
-- This call will block until the merge is complete. If the http connection is
-- lost, the request will continue in the background, and any new requests will
-- block until the previous force merge is complete.

-- For more information see
-- <https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-forcemerge.html#indices-forcemerge>.
-- Nothing
-- worthwhile comes back in the reply body, so matching on the status
-- should suffice.
--
-- 'forceMergeIndex' with a maxNumSegments of 1 and onlyExpungeDeletes
-- to True is the main way to release disk space back to the OS being
-- held by deleted documents.
--
-- >>> let ixn = IndexName "unoptimizedindex"
-- >>> _ <- runBH' $ deleteIndex ixn >> createIndex defaultIndexSettings ixn
-- >>> response <- runBH' $ forceMergeIndex (IndexList (ixn :| [])) (defaultIndexOptimizationSettings { maxNumSegments = Just 1, onlyExpungeDeletes = True })
-- >>> respIsTwoHunna response
-- True
forceMergeIndex :: MonadBH m => IndexSelection -> ForceMergeIndexSettings -> m Reply
forceMergeIndex ixs ForceMergeIndexSettings {..} =
    bindM2 post url (return body)
  where url = addQuery params <$> joinPath [indexName, "_forcemerge"]
        params = catMaybes [ ("max_num_segments",) . Just . showText <$> maxNumSegments
                           , Just ("only_expunge_deletes", Just (boolQP onlyExpungeDeletes))
                           , Just ("flush", Just (boolQP flushAfterOptimize))
                           ]
        indexName = indexSelectionName ixs
        body = Nothing


deepMerge :: [Object] -> Object
deepMerge = LS.foldl' go mempty
  where go acc = LS.foldl' go' acc . HM.toList
        go' acc (k, v) = HM.insertWith merge k v acc
        merge (Object a) (Object b) = Object (deepMerge [a, b])
        merge _ b = b


statusCodeIs :: (Int, Int) -> Reply -> Bool
statusCodeIs r resp = inRange r $ NHTS.statusCode (responseStatus resp)

respIsTwoHunna :: Reply -> Bool
respIsTwoHunna = statusCodeIs (200, 299)

existentialQuery :: MonadBH m => Text -> m (Reply, Bool)
existentialQuery url = do
  reply <- head url
  return (reply, respIsTwoHunna reply)


-- | Tries to parse a response body as the expected type @a@ and
-- failing that tries to parse it as an EsError. All well-formed, JSON
-- responses from elasticsearch should fall into these two
-- categories. If they don't, a 'EsProtocolException' will be
-- thrown. If you encounter this, please report the full body it
-- reports along with your Elasticsearch verison.
parseEsResponse :: ( MonadThrow m
                   , FromJSON a
                   )
                => Reply
                -> m (Either EsError a)
parseEsResponse reply
  | respIsTwoHunna reply = case eitherDecode body of
                             Right a -> return (Right a)
                             Left err ->
                               tryParseError err
  | otherwise = tryParseError "Non-200 status code"
  where body = responseBody reply
        tryParseError originalError
          = case eitherDecode body of
              Right e -> return (Left e)
              -- Failed to parse the error message.
              Left err -> explode ("Original error was: " <> originalError <> " Error parse failure was: " <> err)
        explode errorMsg = throwM (EsProtocolException (T.pack errorMsg) body)

-- | 'indexExists' enables you to check if an index exists. Returns 'Bool'
--   in IO
--
-- >>> exists <- runBH' $ indexExists testIndex
indexExists :: MonadBH m => IndexName -> m Bool
indexExists (IndexName indexName) = do
  (_, exists) <- existentialQuery =<< joinPath [indexName]
  return exists

-- | 'refreshIndex' will force a refresh on an index. You must
-- do this if you want to read what you wrote.
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings testIndex
-- >>> _ <- runBH' $ refreshIndex testIndex
refreshIndex :: MonadBH m => IndexName -> m Reply
refreshIndex (IndexName indexName) =
  bindM2 post url (return Nothing)
  where url = joinPath [indexName, "_refresh"]

-- | Block until the index becomes available for indexing
--   documents. This is useful for integration tests in which
--   indices are rapidly created and deleted.
waitForYellowIndex :: MonadBH m => IndexName -> m Reply
waitForYellowIndex (IndexName indexName) = get =<< url
  where url = addQuery q <$> joinPath ["_cluster","health",indexName]
        q = [("wait_for_status",Just "yellow"),("timeout",Just "10s")]

stringifyOCIndex :: OpenCloseIndex -> Text
stringifyOCIndex oci = case oci of
  OpenIndex  -> "_open"
  CloseIndex -> "_close"

openOrCloseIndexes :: MonadBH m => OpenCloseIndex -> IndexName -> m Reply
openOrCloseIndexes oci (IndexName indexName) =
  bindM2 post url (return Nothing)
  where ociString = stringifyOCIndex oci
        url = joinPath [indexName, ociString]

-- | 'openIndex' opens an index given a 'Server' and an 'IndexName'. Explained in further detail at
--   <http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/indices-open-close.html>
--
-- >>> reply <- runBH' $ openIndex testIndex
openIndex :: MonadBH m => IndexName -> m Reply
openIndex = openOrCloseIndexes OpenIndex

-- | 'closeIndex' closes an index given a 'Server' and an 'IndexName'. Explained in further detail at
--   <http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/indices-open-close.html>
--
-- >>> reply <- runBH' $ closeIndex testIndex
closeIndex :: MonadBH m => IndexName -> m Reply
closeIndex = openOrCloseIndexes CloseIndex

-- | 'listIndices' returns a list of all index names on a given 'Server'
listIndices :: (MonadThrow m, MonadBH m) => m [IndexName]
listIndices =
  parse . responseBody =<< get =<< url
  where
    url = joinPath ["_cat/indices?format=json"]
    parse body = either (\msg -> (throwM (EsProtocolException (T.pack msg) body))) return $ do
      vals <- eitherDecode body
      forM vals $ \val ->
        case val of
          Object obj ->
            case HM.lookup "index" obj of
              (Just (String txt)) -> Right (IndexName txt)
              v -> Left $ "indexVal in listIndices failed on non-string, was: " <> show v
          v -> Left $ "One of the values parsed in listIndices wasn't an object, it was: " <> show v

-- | 'catIndices' returns a list of all index names on a given 'Server' as well as their doc counts
catIndices :: (MonadThrow m, MonadBH m) => m [(IndexName, Int)]
catIndices =
  parse . responseBody =<< get =<< url
  where
    url = joinPath ["_cat/indices?format=json"]
    parse body = either (\msg -> (throwM (EsProtocolException (T.pack msg) body))) return $ do
      vals <- eitherDecode body
      forM vals $ \val ->
        case val of
          Object obj ->
            case (HM.lookup "index" obj, HM.lookup "docs.count" obj) of
              (Just (String txt), Just (String docs)) -> Right ((IndexName txt), read (T.unpack docs))
              v -> Left $ "indexVal in catIndices failed on non-string, was: " <> show v
          v -> Left $ "One of the values parsed in catIndices wasn't an object, it was: " <> show v

-- | 'updateIndexAliases' updates the server's index alias
-- table. Operations are atomic. Explained in further detail at
-- <https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-aliases.html>
--
-- >>> let src = IndexName "a-real-index"
-- >>> let aliasName = IndexName "an-alias"
-- >>> let iAlias = IndexAlias src (IndexAliasName aliasName)
-- >>> let aliasCreate = IndexAliasCreate Nothing Nothing
-- >>> _ <- runBH' $ deleteIndex src
-- >>> respIsTwoHunna <$> runBH' (createIndex defaultIndexSettings src)
-- True
-- >>> runBH' $ indexExists src
-- True
-- >>> respIsTwoHunna <$> runBH' (updateIndexAliases (AddAlias iAlias aliasCreate :| []))
-- True
-- >>> runBH' $ indexExists aliasName
-- True
updateIndexAliases :: MonadBH m => NonEmpty IndexAliasAction -> m Reply
updateIndexAliases actions = bindM2 post url (return body)
  where url = joinPath ["_aliases"]
        body = Just (encode bodyJSON)
        bodyJSON = object [ "actions" .= toList actions]

-- | Get all aliases configured on the server.
getIndexAliases :: (MonadBH m, MonadThrow m)
                => m (Either EsError IndexAliasesSummary)
getIndexAliases = parseEsResponse =<< get =<< url
  where url = joinPath ["_aliases"]

-- | Delete a single alias, removing it from all indices it
--   is currently associated with.
deleteIndexAlias :: MonadBH m => IndexAliasName -> m Reply
deleteIndexAlias (IndexAliasName (IndexName name)) = delete =<< url
  where url = joinPath ["_all","_alias",name]

-- | 'putTemplate' creates a template given an 'IndexTemplate' and a 'TemplateName'.
--   Explained in further detail at
--   <https://www.elastic.co/guide/en/elasticsearch/reference/1.7/indices-templates.html>
--
--   >>> let idxTpl = IndexTemplate [IndexPattern "tweet-*"] (Just (IndexSettings (ShardCount 1) (ReplicaCount 1))) [toJSON TweetMapping]
--   >>> resp <- runBH' $ putTemplate idxTpl (TemplateName "tweet-tpl")
putTemplate :: MonadBH m => IndexTemplate -> TemplateName -> m Reply
putTemplate indexTemplate (TemplateName templateName) =
  bindM2 put url (return body)
  where url = joinPath ["_template", templateName]
        body = Just $ encode indexTemplate

-- | 'templateExists' checks to see if a template exists.
--
--   >>> exists <- runBH' $ templateExists (TemplateName "tweet-tpl")
templateExists :: MonadBH m => TemplateName -> m Bool
templateExists (TemplateName templateName) = do
  (_, exists) <- existentialQuery =<< joinPath ["_template", templateName]
  return exists

-- | 'deleteTemplate' is an HTTP DELETE and deletes a template.
--
--   >>> let idxTpl = IndexTemplate [IndexPattern "tweet-*"] (Just (IndexSettings (ShardCount 1) (ReplicaCount 1))) [toJSON TweetMapping]
--   >>> _ <- runBH' $ putTemplate idxTpl (TemplateName "tweet-tpl")
--   >>> resp <- runBH' $ deleteTemplate (TemplateName "tweet-tpl")
deleteTemplate :: MonadBH m => TemplateName -> m Reply
deleteTemplate (TemplateName templateName) =
  delete =<< joinPath ["_template", templateName]

-- | 'putMapping' is an HTTP PUT and has upsert semantics. Mappings are schemas
-- for documents in indexes.
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings testIndex
-- >>> resp <- runBH' $ putMapping testIndex TweetMapping
-- >>> print resp
-- Response {responseStatus = Status {statusCode = 200, statusMessage = "OK"}, responseVersion = HTTP/1.1, responseHeaders = [("content-type","application/json; charset=UTF-8"),("content-encoding","gzip"),("transfer-encoding","chunked")], responseBody = "{\"acknowledged\":true}", responseCookieJar = CJ {expose = []}, responseClose' = ResponseClose}
putMapping :: (MonadBH m, ToJSON a) => IndexName -> a -> m Reply
putMapping (IndexName indexName) mapping =
  bindM2 put url (return body)
  where url = joinPath [indexName, "_mapping"]
        -- "_mapping" above is originally transposed
        -- erroneously. The correct API call is: "/INDEX/_mapping"
        body = Just $ encode mapping

versionCtlParams :: IndexDocumentSettings -> [(Text, Maybe Text)]
versionCtlParams cfg =
  case idsVersionControl cfg of
    NoVersionControl -> []
    InternalVersion v -> versionParams v "internal"
    ExternalGT (ExternalDocVersion v) -> versionParams v "external_gt"
    ExternalGTE (ExternalDocVersion v) -> versionParams v "external_gte"
    ForceVersion (ExternalDocVersion v) -> versionParams v "force"
  where
    vt = showText . docVersionNumber
    versionParams v t = [ ("version", Just $ vt v)
                        , ("version_type", Just t)
                        ]

-- | 'indexDocument' is the primary way to save a single document in
--   Elasticsearch. The document itself is simply something we can
--   convert into a JSON 'Value'. The 'DocId' will function as the
--   primary key for the document. You are encouraged to generate
--   your own id's and not rely on Elasticsearch's automatic id
--   generation. Read more about it here:
--   https://github.com/bitemyapp/bloodhound/issues/107
--
-- >>> resp <- runBH' $ indexDocument testIndex defaultIndexDocumentSettings exampleTweet (DocId "1")
-- >>> print resp
-- Response {responseStatus = Status {statusCode = 200, statusMessage = "OK"}, responseVersion = HTTP/1.1, responseHeaders = [("content-type","application/json; charset=UTF-8"),("content-encoding","gzip"),("content-length","152")], responseBody = "{\"_index\":\"bloodhound-tests-twitter-1\",\"_type\":\"_doc\",\"_id\":\"1\",\"_version\":2,\"result\":\"updated\",\"_shards\":{\"total\":1,\"successful\":1,\"failed\":0},\"_seq_no\":1,\"_primary_term\":1}", responseCookieJar = CJ {expose = []}, responseClose' = ResponseClose}
indexDocument :: (ToJSON doc, MonadBH m) => IndexName
                 -> IndexDocumentSettings -> doc -> DocId -> m Reply
indexDocument (IndexName indexName) cfg document (DocId docId) =
  bindM2 put url (return body)
  where url = addQuery (indexQueryString cfg (DocId docId)) <$> joinPath [indexName, "_doc", docId]
        jsonBody = encodeDocument cfg document
        body = Just (encode jsonBody)

-- | 'updateDocument' provides a way to perform an partial update of a
-- an already indexed document.
updateDocument :: (ToJSON patch, MonadBH m) => IndexName
                  -> IndexDocumentSettings -> patch -> DocId -> m Reply
updateDocument (IndexName indexName) cfg patch (DocId docId) =
  bindM2 post url (return body)
  where url = addQuery (indexQueryString cfg (DocId docId)) <$>
              joinPath [indexName, "_update", docId]
        jsonBody = encodeDocument cfg patch
        body = Just (encode $ object ["doc" .= jsonBody])

{-  From ES docs:
      Parent and child documents must be indexed on the same shard.
      This means that the same routing value needs to be provided when getting, deleting, or updating a child document.

    Parent/Child support in Bloodhound requires MUCH more love.
    To work it around for now (and to support the existing unit test) we route "parent" documents to their "_id"
    (which is the default strategy for the ES), and route all child documents to their parens' "_id"

    However, it may not be flexible enough for some corner cases.

    Buld operations are completely unaware of "routing" and are probably broken in that matter.
    Or perhaps they always were, because the old "_parent" would also have this requirement.
-}
indexQueryString :: IndexDocumentSettings -> DocId -> [(Text, Maybe Text)]
indexQueryString cfg (DocId docId) =
  versionCtlParams cfg <> routeParams
  where
    routeParams = case idsJoinRelation cfg of
      Nothing -> []
      Just (ParentDocument _ _) -> [("routing", Just docId)]
      Just (ChildDocument _ _ (DocId pid)) -> [("routing", Just pid)]

encodeDocument :: ToJSON doc => IndexDocumentSettings -> doc -> Value
encodeDocument cfg document =
  case idsJoinRelation cfg of
    Nothing -> toJSON document
    Just (ParentDocument (FieldName field) name) ->
      mergeObjects (toJSON document) (object [field .= name])
    Just (ChildDocument (FieldName field) name parent) ->
      mergeObjects (toJSON document) (object [field .= object ["name" .= name, "parent" .= parent]])
  where
    mergeObjects (Object a) (Object b) = Object (a <> b)
    mergeObjects _ _ = error "Impossible happened: both document body and join parameters must be objects"

-- | 'deleteDocument' is the primary way to delete a single document.
--
-- >>> _ <- runBH' $ deleteDocument testIndex (DocId "1")
deleteDocument :: MonadBH m => IndexName -> DocId -> m Reply
deleteDocument (IndexName indexName) (DocId docId) =
  delete =<< joinPath [indexName, "_doc", docId]

-- | 'deleteByQuery' performs a deletion on every document that matches a query.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> _ <- runBH' $ deleteDocument testIndex query
deleteByQuery :: MonadBH m => IndexName -> Query -> m Reply
deleteByQuery (IndexName indexName) query =
  bindM2 post url (return body)
  where
    url = joinPath [indexName, "_delete_by_query"]
    body = Just (encode $ object [ "query" .= query ])

-- | 'bulk' uses
--    <http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/docs-bulk.html Elasticsearch's bulk API>
--    to perform bulk operations. The 'BulkOperation' data type encodes the
--    index\/update\/delete\/create operations. You pass a 'V.Vector' of 'BulkOperation's
--    and a 'Server' to 'bulk' in order to send those operations up to your Elasticsearch
--    server to be performed. I changed from [BulkOperation] to a Vector due to memory overhead.
--
-- >>> let stream = V.fromList [BulkIndex testIndex (DocId "2") (toJSON (BulkTest "blah"))]
-- >>> _ <- runBH' $ bulk stream
-- >>> _ <- runBH' $ refreshIndex testIndex
bulk :: MonadBH m => V.Vector BulkOperation -> m Reply
bulk bulkOps =
  bindM2 post url (return body)
  where
    url = joinPath ["_bulk"]
    body = Just $ encodeBulkOperations bulkOps

-- | 'encodeBulkOperations' is a convenience function for dumping a vector of 'BulkOperation'
--   into an 'L.ByteString'
--
-- >>> let bulkOps = V.fromList [BulkIndex testIndex (DocId "2") (toJSON (BulkTest "blah"))]
-- >>> encodeBulkOperations bulkOps
-- "\n{\"index\":{\"_id\":\"2\",\"_index\":\"twitter\"}}\n{\"name\":\"blah\"}\n"
encodeBulkOperations :: V.Vector BulkOperation -> L.ByteString
encodeBulkOperations stream = collapsed where
  blobs =
    fmap encodeBulkOperation stream
  mashedTaters =
    mash (mempty :: Builder) blobs
  collapsed =
    toLazyByteString $ mappend mashedTaters (byteString "\n")

mash :: Builder -> V.Vector L.ByteString -> Builder
mash = V.foldl' (\b x -> b <> byteString "\n" <> lazyByteString x)

mkBulkStreamValue :: Text -> Text -> Text -> Value
mkBulkStreamValue operation indexName docId =
  object [operation .=
          object [ "_index" .= indexName
                 , "_id"    .= docId]]

mkBulkStreamValueAuto :: Text -> Text -> Value
mkBulkStreamValueAuto operation indexName =
  object [operation .=
          object [ "_index" .= indexName ]]

mkBulkStreamValueWithMeta :: [UpsertActionMetadata] -> Text -> Text -> Text -> Value
mkBulkStreamValueWithMeta meta operation indexName docId =
  object [ operation .=
          object ([ "_index" .= indexName
                  , "_id"    .= docId]
                  <> (buildUpsertActionMetadata <$> meta))]

-- | 'encodeBulkOperation' is a convenience function for dumping a single 'BulkOperation'
--   into an 'L.ByteString'
--
-- >>> let bulkOp = BulkIndex testIndex (DocId "2") (toJSON (BulkTest "blah"))
-- >>> encodeBulkOperation bulkOp
-- "{\"index\":{\"_id\":\"2\",\"_index\":\"twitter\"}}\n{\"name\":\"blah\"}"
encodeBulkOperation :: BulkOperation -> L.ByteString
encodeBulkOperation (BulkIndex (IndexName indexName) (DocId docId) value) = blob
    where metadata = mkBulkStreamValue "index" indexName docId
          blob = encode metadata `mappend` "\n" `mappend` encode value

encodeBulkOperation (BulkIndexAuto (IndexName indexName) value) = blob
    where metadata = mkBulkStreamValueAuto "index" indexName
          blob = encode metadata `mappend` "\n" `mappend` encode value

encodeBulkOperation (BulkIndexEncodingAuto (IndexName indexName) encoding) = toLazyByteString blob
    where metadata = toEncoding (mkBulkStreamValueAuto "index" indexName)
          blob = fromEncoding metadata <> "\n" <> fromEncoding encoding

encodeBulkOperation (BulkCreate (IndexName indexName) (DocId docId) value) = blob
    where metadata = mkBulkStreamValue "create" indexName docId
          blob = encode metadata `mappend` "\n" `mappend` encode value

encodeBulkOperation (BulkDelete (IndexName indexName) (DocId docId)) = blob
    where metadata = mkBulkStreamValue "delete" indexName docId
          blob = encode metadata

encodeBulkOperation (BulkUpdate (IndexName indexName) (DocId docId) value) = blob
    where metadata = mkBulkStreamValue "update" indexName docId
          doc = object ["doc" .= value]
          blob = encode metadata `mappend` "\n" `mappend` encode doc

encodeBulkOperation (BulkUpsert (IndexName indexName)
                (DocId docId)
                payload
                actionMeta) = blob
    where metadata = mkBulkStreamValueWithMeta actionMeta "update" indexName docId
          blob = encode metadata <> "\n" <> encode doc
          doc = case payload of
            UpsertDoc value -> object ["doc" .= value, "doc_as_upsert" .= True]
            UpsertScript scriptedUpsert script value ->
              let scup = if scriptedUpsert then ["scripted_upsert" .= True] else []
                  upsert = ["upsert" .= value]
              in
                case (object (scup <> upsert), toJSON script) of
                  (Object obj, Object jscript) -> Object $ jscript <> obj
                  _ -> error "Impossible happened: serialising Script to Json should always be Object"



encodeBulkOperation (BulkCreateEncoding (IndexName indexName) (DocId docId) encoding) =
    toLazyByteString blob
    where metadata = toEncoding (mkBulkStreamValue "create" indexName docId)
          blob = fromEncoding metadata <> "\n" <> fromEncoding encoding

-- | 'getDocument' is a straight-forward way to fetch a single document from
--   Elasticsearch using a 'Server', 'IndexName', and a 'DocId'.
--   The 'DocId' is the primary key for your Elasticsearch document.
--
-- >>> yourDoc <- runBH' $ getDocument testIndex (DocId "1")
getDocument :: MonadBH m => IndexName -> DocId -> m Reply
getDocument (IndexName indexName) (DocId docId) =
  get =<< joinPath [indexName, "_doc", docId]

-- | 'documentExists' enables you to check if a document exists.
documentExists :: MonadBH m => IndexName ->  DocId -> m Bool
documentExists (IndexName indexName) (DocId docId) =
  fmap snd (existentialQuery =<< joinPath [indexName, "_doc", docId])

dispatchSearch :: MonadBH m => Text -> Search -> m Reply
dispatchSearch url search = post url' (Just (encode search))
  where url' = appendSearchTypeParam url (searchType search)

-- | 'searchAll', given a 'Search', will perform that search against all indexes
--   on an Elasticsearch server. Try to avoid doing this if it can be helped.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> let search = mkSearch (Just query) Nothing
-- >>> reply <- runBH' $ searchAll search
searchAll :: MonadBH m => Search -> m Reply
searchAll = bindM2 dispatchSearch url . return
  where url = joinPath ["_search"]

-- | 'searchByIndex', given a 'Search' and an 'IndexName', will perform that search
--   within an index on an Elasticsearch server.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> let search = mkSearch (Just query) Nothing
-- >>> reply <- runBH' $ searchByIndex testIndex search
searchByIndex :: MonadBH m => IndexName -> Search -> m Reply
searchByIndex (IndexName indexName) = bindM2 dispatchSearch url . return
  where url = joinPath [indexName, "_search"]

-- | 'searchByIndices' is a variant of 'searchByIndex' that executes a
--   'Search' over many indices. This is much faster than using
--   'mapM' to 'searchByIndex' over a collection since it only
--   causes a single HTTP request to be emitted.
searchByIndices :: MonadBH m => NonEmpty IndexName -> Search -> m Reply
searchByIndices ixs = bindM2 dispatchSearch url . return
  where url = joinPath [renderedIxs, "_search"]
        renderedIxs = T.intercalate (T.singleton ',') (map (\(IndexName t) -> t) (toList ixs))

dispatchSearchTemplate :: MonadBH m => Text -> SearchTemplate -> m Reply
dispatchSearchTemplate url search = post url (Just (encode search))

-- | 'searchByIndexTemplate', given a 'SearchTemplate' and an 'IndexName', will perform that search
--   within an index on an Elasticsearch server.
--
-- >>> let query = SearchTemplateSource "{\"query\": { \"match\" : { \"{{my_field}}\" : \"{{my_value}}\" } }, \"size\" : \"{{my_size}}\"}"
-- >>> let search = mkSearchTemplate (Right query) Nothing
-- >>> reply <- runBH' $ searchByIndexTemplate testIndex search
searchByIndexTemplate :: MonadBH m => IndexName -> SearchTemplate -> m Reply
searchByIndexTemplate (IndexName indexName) = bindM2 dispatchSearchTemplate url . return
  where url = joinPath [indexName, "_search", "template"]

-- | 'searchByIndicesTemplate' is a variant of 'searchByIndexTemplate' that executes a
--   'SearchTemplate' over many indices. This is much faster than using
--   'mapM' to 'searchByIndexTemplate' over a collection since it only
--   causes a single HTTP request to be emitted.
searchByIndicesTemplate :: MonadBH m => NonEmpty IndexName -> SearchTemplate -> m Reply
searchByIndicesTemplate ixs = bindM2 dispatchSearchTemplate url . return
  where url = joinPath [renderedIxs, "_search", "template"]
        renderedIxs = T.intercalate (T.singleton ',') (map (\(IndexName t) -> t) (toList ixs))

-- | 'storeSearchTemplate', saves a 'SearchTemplateSource' to be used later.
storeSearchTemplate :: MonadBH m => SearchTemplateId -> SearchTemplateSource -> m Reply
storeSearchTemplate (SearchTemplateId tid) (SearchTemplateSource ts) =
  url >>= flip post (Just (encode json))
  where
    url = joinPath ["_scripts", tid]
    json = Object $ HM.fromList ["script" .= Object (HM.fromList ["lang" .= String "mustache", "source" .= String ts]) ]

-- | 'getSearchTemplate', get info of an stored 'SearchTemplateSource'.
getSearchTemplate :: MonadBH m => SearchTemplateId -> m Reply 
getSearchTemplate (SearchTemplateId tid) =
  url >>= get
  where
    url = joinPath ["_scripts", tid]

-- | 'storeSearchTemplate', 
deleteSearchTemplate :: MonadBH m => SearchTemplateId -> m Reply 
deleteSearchTemplate (SearchTemplateId tid) =
  url >>= delete
  where
    url = joinPath ["_scripts", tid]

-- | For a given search, request a scroll for efficient streaming of
-- search results. Note that the search is put into 'SearchTypeScan'
-- mode and thus results will not be sorted. Combine this with
-- 'advanceScroll' to efficiently stream through the full result set
getInitialScroll ::
  (FromJSON a, MonadThrow m, MonadBH m) => IndexName ->
                                           Search ->
                                           m (Either EsError (SearchResult a))
getInitialScroll (IndexName indexName) search' = do
    let url = addQuery params <$> joinPath [indexName, "_search"]
        params = [("scroll", Just "1m")]
        sorting = Just [DefaultSortSpec $ mkSort (FieldName "_doc") Descending]
        search = search' { sortBody = sorting }
    resp' <- bindM2 dispatchSearch url (return search)
    parseEsResponse resp'

-- | For a given search, request a scroll for efficient streaming of
-- search results. Combine this with 'advanceScroll' to efficiently
-- stream through the full result set. Note that this search respects
-- sorting and may be less efficient than 'getInitialScroll'.
getInitialSortedScroll ::
  (FromJSON a, MonadThrow m, MonadBH m) => IndexName ->
                                           Search ->
                                           m (Either EsError (SearchResult a))
getInitialSortedScroll (IndexName indexName) search = do
    let url = addQuery params <$> joinPath [indexName, "_search"]
        params = [("scroll", Just "1m")]
    resp' <- bindM2 dispatchSearch url (return search)
    parseEsResponse resp'

scroll' :: (FromJSON a, MonadBH m, MonadThrow m) => Maybe ScrollId ->
                                                    m ([Hit a], Maybe ScrollId)
scroll' Nothing = return ([], Nothing)
scroll' (Just sid) = do
    res <- advanceScroll sid 60
    case res of
      Right SearchResult {..} -> return (hits searchHits, scrollId)
      Left _ -> return ([], Nothing)

-- | Use the given scroll to fetch the next page of documents. If there are no
-- further pages, 'SearchResult.searchHits.hits' will be '[]'.
advanceScroll
  :: ( FromJSON a
     , MonadBH m
     , MonadThrow m
     )
  => ScrollId
  -> NominalDiffTime
  -- ^ How long should the snapshot of data be kept around? This timeout is updated every time 'advanceScroll' is used, so don't feel the need to set it to the entire duration of your search processing. Note that durations < 1s will be rounded up. Also note that 'NominalDiffTime' is an instance of Num so literals like 60 will be interpreted as seconds. 60s is a reasonable default.
  -> m (Either EsError (SearchResult a))
advanceScroll (ScrollId sid) scroll = do
  url <- joinPath ["_search", "scroll"]
  resp <- post url (Just $ encode scrollObject)
  parseEsResponse resp
  where scrollTime = showText secs <> "s"
        secs :: Integer
        secs = round scroll

        scrollObject = object [ "scroll" .= scrollTime
                              , "scroll_id" .= sid
                              ]

scanAccumulator ::
  (FromJSON a, MonadBH m, MonadThrow m) =>
                                [Hit a] ->
                                ([Hit a], Maybe ScrollId) ->
                                m ([Hit a], Maybe ScrollId)
scanAccumulator oldHits (newHits, Nothing) = return (oldHits ++ newHits, Nothing)
scanAccumulator oldHits ([], _) = return (oldHits, Nothing)
scanAccumulator oldHits (newHits, msid) = do
    (newHits', msid') <- scroll' msid
    scanAccumulator (oldHits ++ newHits) (newHits', msid')

-- | 'scanSearch' uses the 'scroll' API of elastic,
-- for a given 'IndexName'. Note that this will
-- consume the entire search result set and will be doing O(n) list
-- appends so this may not be suitable for large result sets. In that
-- case, 'getInitialScroll' and 'advanceScroll' are good low level
-- tools. You should be able to hook them up trivially to conduit,
-- pipes, or your favorite streaming IO abstraction of choice. Note
-- that ordering on the search would destroy performance and thus is
-- ignored.
scanSearch :: (FromJSON a, MonadBH m, MonadThrow m) => IndexName
                                                    -> Search
                                                    -> m [Hit a]
scanSearch indexName search = do
    initialSearchResult <- getInitialScroll indexName search
    let (hits', josh) = case initialSearchResult of
                          Right SearchResult {..} -> (hits searchHits, scrollId)
                          Left _ -> ([], Nothing)
    (totalHits, _) <- scanAccumulator [] (hits', josh)
    return totalHits

pitAccumulator
  :: (FromJSON a, MonadBH m, MonadThrow m) => Search -> [Hit a] -> m [Hit a]
pitAccumulator search oldHits = do
  resp   <- searchAll search
  parsed <- parseEsResponse resp
  case parsed of
    Left  _            -> return []
    Right searchResult -> case hits (searchHits searchResult) of
      []      -> return oldHits
      newHits -> case (hitSort $ last newHits, pitId searchResult) of
        (Nothing, Nothing) ->
          error "no point in time (PIT) ID or last sort value"
        (Just _       , Nothing    ) -> error "no point in time (PIT) ID"
        (Nothing      , _     ) -> return (oldHits <> newHits)
        (Just lastSort, Just pitId') -> do
          let newSearch = search { pointInTime = Just (PointInTime pitId' "1m")
                                 , searchAfterKey = Just lastSort
                                 }
          pitAccumulator newSearch (oldHits <> newHits)

-- | 'pitSearch' uses the point in time (PIT) API of elastic, for a given
-- 'IndexName'. Requires Elasticsearch >=7.10. Note that this will consume the
-- entire search result set and will be doing O(n) list appends so this may
-- not be suitable for large result sets. In that case, the point in time API
-- should be used directly with `openPointInTime` and `closePointInTime`.
--
-- Note that 'pitSearch' utilizes the 'search_after' parameter under the hood,
-- which requires a non-empty 'sortBody' field in the provided 'Search' value.
-- Otherwise, 'pitSearch' will fail to return all matching documents.
--
-- For more information see
-- <https://www.elastic.co/guide/en/elasticsearch/reference/current/point-in-time-api.html>.
pitSearch
  :: (FromJSON a, MonadBH m, MonadThrow m) => IndexName -> Search -> m [Hit a]
pitSearch indexName search = do
  openResp <- openPointInTime indexName
  case openResp of
    Left  _                            -> return []
    Right OpenPointInTimeResponse {..} -> do
      let searchPIT = search { pointInTime = Just (PointInTime oPitId "1m") }
      hits      <- pitAccumulator searchPIT []
      closeResp <- closePointInTime $ ClosePointInTime oPitId
      case closeResp of
        Left _ -> return []
        Right _ -> return hits

-- | 'mkSearch' is a helper function for defaulting additional fields of a 'Search'
--   to Nothing in case you only care about your 'Query' and 'Filter'. Use record update
--   syntax if you want to add things like aggregations or highlights while still using
--   this helper function.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> mkSearch (Just query) Nothing
-- Search {queryBody = Just (TermQuery (Term {termField = "user", termValue = "bitemyapp"}) Nothing), filterBody = Nothing, searchAfterKey = Nothing, sortBody = Nothing, aggBody = Nothing, highlight = Nothing, trackSortScores = False, from = From 0, size = Size 10, searchType = SearchTypeQueryThenFetch, fields = Nothing, source = Nothing}
mkSearch :: Maybe Query -> Maybe Filter -> Search
mkSearch query filter = Search query filter Nothing Nothing Nothing False (From 0) (Size 10) SearchTypeQueryThenFetch Nothing Nothing Nothing Nothing Nothing Nothing

-- | 'mkAggregateSearch' is a helper function that defaults everything in a 'Search' except for
--   the 'Query' and the 'Aggregation'.
--
-- >>> let terms = TermsAgg $ (mkTermsAggregation "user") { termCollectMode = Just BreadthFirst }
-- >>> terms
-- TermsAgg (TermsAggregation {term = Left "user", termInclude = Nothing, termExclude = Nothing, termOrder = Nothing, termMinDocCount = Nothing, termSize = Nothing, termShardSize = Nothing, termCollectMode = Just BreadthFirst, termExecutionHint = Nothing, termAggs = Nothing})
-- >>> let myAggregation = mkAggregateSearch Nothing $ mkAggregations "users" terms
mkAggregateSearch :: Maybe Query -> Aggregations -> Search
mkAggregateSearch query mkSearchAggs = Search query Nothing Nothing (Just mkSearchAggs) Nothing False (From 0) (Size 0) SearchTypeQueryThenFetch Nothing Nothing Nothing Nothing Nothing Nothing

-- | 'mkHighlightSearch' is a helper function that defaults everything in a 'Search' except for
--   the 'Query' and the 'Aggregation'.
--
-- >>> let query = QueryMatchQuery $ mkMatchQuery (FieldName "_all") (QueryString "haskell")
-- >>> let testHighlight = Highlights Nothing [FieldHighlight (FieldName "message") Nothing]
-- >>> let search = mkHighlightSearch (Just query) testHighlight
mkHighlightSearch :: Maybe Query -> Highlights -> Search
mkHighlightSearch query searchHighlights = Search query Nothing Nothing Nothing (Just searchHighlights) False (From 0) (Size 10) SearchTypeQueryThenFetch Nothing Nothing Nothing Nothing Nothing Nothing

-- | 'mkSearchTemplate' is a helper function for defaulting additional fields of a 'SearchTemplate'
--   to Nothing. Use record update syntax if you want to add things.
mkSearchTemplate :: Either SearchTemplateId SearchTemplateSource -> TemplateQueryKeyValuePairs -> SearchTemplate
mkSearchTemplate id params = SearchTemplate id params Nothing Nothing

-- | 'pageSearch' is a helper function that takes a search and assigns the from
--    and size fields for the search. The from parameter defines the offset
--    from the first result you want to fetch. The size parameter allows you to
--    configure the maximum amount of hits to be returned.
--
-- >>> let query = QueryMatchQuery $ mkMatchQuery (FieldName "_all") (QueryString "haskell")
-- >>> let search = mkSearch (Just query) Nothing
-- >>> search
-- Search {queryBody = Just (QueryMatchQuery (MatchQuery {matchQueryField = FieldName "_all", matchQueryQueryString = QueryString "haskell", matchQueryOperator = Or, matchQueryZeroTerms = ZeroTermsNone, matchQueryCutoffFrequency = Nothing, matchQueryMatchType = Nothing, matchQueryAnalyzer = Nothing, matchQueryMaxExpansions = Nothing, matchQueryLenient = Nothing, matchQueryBoost = Nothing})), filterBody = Nothing, sortBody = Nothing, aggBody = Nothing, highlight = Nothing, trackSortScores = False, from = From 0, size = Size 10, searchType = SearchTypeQueryThenFetch, fields = Nothing, source = Nothing}
-- >>> pageSearch (From 10) (Size 100) search
-- Search {queryBody = Just (QueryMatchQuery (MatchQuery {matchQueryField = FieldName "_all", matchQueryQueryString = QueryString "haskell", matchQueryOperator = Or, matchQueryZeroTerms = ZeroTermsNone, matchQueryCutoffFrequency = Nothing, matchQueryMatchType = Nothing, matchQueryAnalyzer = Nothing, matchQueryMaxExpansions = Nothing, matchQueryLenient = Nothing, matchQueryBoost = Nothing})), filterBody = Nothing, sortBody = Nothing, aggBody = Nothing, highlight = Nothing, trackSortScores = False, from = From 10, size = Size 100, searchType = SearchTypeQueryThenFetch, fields = Nothing, source = Nothing}
pageSearch :: From     -- ^ The result offset
           -> Size     -- ^ The number of results to return
           -> Search  -- ^ The current seach
           -> Search  -- ^ The paged search
pageSearch resultOffset pageSize search = search { from = resultOffset, size = pageSize }

parseUrl' :: MonadThrow m => Text -> m Request
parseUrl' t = parseRequest (URI.escapeURIString URI.isAllowedInURI (T.unpack t))

-- | Was there an optimistic concurrency control conflict when
-- indexing a document?
isVersionConflict :: Reply -> Bool
isVersionConflict = statusCheck (== 409)

isSuccess :: Reply -> Bool
isSuccess = statusCheck (inRange (200, 299))

isCreated :: Reply -> Bool
isCreated = statusCheck (== 201)

statusCheck :: (Int -> Bool) -> Reply -> Bool
statusCheck prd = prd . NHTS.statusCode . responseStatus

-- | This is a hook that can be set via the 'bhRequestHook' function
-- that will authenticate all requests using an HTTP Basic
-- Authentication header. Note that it is *strongly* recommended that
-- this option only be used over an SSL connection.
--
-- >> (mkBHEnv myServer myManager) { bhRequestHook = basicAuthHook (EsUsername "myuser") (EsPassword "mypass") }
basicAuthHook :: Monad m => EsUsername -> EsPassword -> Request -> m Request
basicAuthHook (EsUsername u) (EsPassword p) = return . applyBasicAuth u' p'
  where u' = T.encodeUtf8 u
        p' = T.encodeUtf8 p


boolQP :: Bool -> Text
boolQP True  = "true"
boolQP False = "false"

countByIndex :: (MonadBH m, MonadThrow m) => IndexName -> CountQuery -> m (Either EsError CountResponse)
countByIndex (IndexName indexName) q = do
  url <- joinPath [indexName, "_count"]
  parseEsResponse =<< post url (Just (encode q))

-- | 'openPointInTime' opens a point in time for an index given an 'IndexName'. 
-- Note that the point in time should be closed with 'closePointInTime' as soon 
-- as it is no longer needed.
--
-- For more information see
-- <https://www.elastic.co/guide/en/elasticsearch/reference/current/point-in-time-api.html>.
openPointInTime
  :: (MonadBH m, MonadThrow m)
  => IndexName
  -> m (Either EsError OpenPointInTimeResponse)
openPointInTime (IndexName indexName) = do
  url <- joinPath [indexName, "_pit?keep_alive=1m"]
  parseEsResponse =<< post url Nothing

-- | 'closePointInTime' closes a point in time given a 'ClosePointInTime'.
--
-- For more information see
-- <https://www.elastic.co/guide/en/elasticsearch/reference/current/point-in-time-api.html>.
closePointInTime
  :: (MonadBH m, MonadThrow m)
  => ClosePointInTime
  -> m (Either EsError ClosePointInTimeResponse)
closePointInTime q = do
  url <- joinPath ["_pit"]
  parseEsResponse =<< delete' url (Just (encode q))
