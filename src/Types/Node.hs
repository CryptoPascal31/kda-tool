{-# LANGUAGE OverloadedStrings #-}

module Types.Node where

------------------------------------------------------------------------------
import           Chainweb.Api.ChainId
import           Chainweb.Api.ChainwebMeta
import           Chainweb.Api.Hash
import           Chainweb.Api.NodeInfo
import           Chainweb.Api.PactCommand
import           Chainweb.Api.Transaction
import           Data.Aeson
import qualified Data.ByteString.Lazy as LB
import qualified Data.List.NonEmpty as NE
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding
import           Network.Connection
import           Network.HTTP.Client
import           Network.HTTP.Client.TLS
import           Network.HTTP.Types.Header
import           Network.HTTP.Types.Status
import           Text.Printf
------------------------------------------------------------------------------
import           Types.HostPort
------------------------------------------------------------------------------

data Scheme = Http | Https
  deriving (Eq,Ord,Show)

schemeText :: Scheme -> Text
schemeText Https = "https://"
schemeText Http = "http://"

data ServerType = PactServer | ChainwebServer
  deriving (Eq,Ord,Show)

data Node = Node
  { _node_scheme :: Scheme
  , _node_server :: HostPort
  , _node_httpManager :: Manager
  , _node_serverType :: ServerType
  , _node_nodeInfo :: Maybe NodeInfo
  -- ^ mainnet01, testnet04, etc or Nothing if it's a pact -s server
  }

getNode :: HostPort -> IO (Either String Node)
getNode h = do
    httpsMgr <- newTlsManagerWith (mkManagerSettings (TLSSettingsSimple True False False) Nothing)
    req <- parseRequest ("https://" <> infoUrl)
    resp <- httpLbs req httpsMgr
    if statusIsSuccessful (responseStatus resp)
      then do
        case eitherDecode (responseBody resp) of
          Left e -> return $ Left ("Error decoding response: " <> e)
          Right ni -> do
            return $ Right $ Node Https h httpsMgr ChainwebServer (Just ni)
      else do
        httpMgr <- newManager defaultManagerSettings
        req2 <- parseRequest ("http://" <> infoUrl)
        resp2 <- httpLbs req2 httpMgr
        if statusIsSuccessful (responseStatus resp2)
          then return $ Right $ Node Http h httpMgr PactServer Nothing
          else do
            req3 <- parseRequest ("http://" <> infoUrl)
            resp3 <- httpLbs req3 httpMgr
            if statusIsSuccessful (responseStatus resp3)
              then return $ Right $ Node Https h httpMgr PactServer Nothing
              else return $ Left ("Error requesting from " <> versionUrl)

  where
    infoUrl = T.unpack $ hostPortToText h <> "/info"
    versionUrl = T.unpack $ hostPortToText h <> "/version"

nodeApiRoot :: Node -> Text
nodeApiRoot n =
    case (_node_serverType n, _node_nodeInfo n) of
      (PactServer, _) -> prefix
      (ChainwebServer, Just ni) ->
        prefix <>
        "chainweb/" <>
        _nodeInfo_apiVer ni <> "/" <>
        _nodeInfo_chainwebVer ni
      _ -> error $ "Couldn't get node " <> T.unpack hpText <> " info"
  where
    hpText = hostPortToText (_node_server n)
    prefix = schemeText (_node_scheme n) <> hpText <> "/"

nodeChainRoot :: Node -> ChainId -> Text
nodeChainRoot n c =
    case (_node_serverType n) of
      PactServer -> nodeApiRoot n
      ChainwebServer ->
        nodeApiRoot n <>
        "/chain/" <>
        T.pack (show $ unChainId c)

nodePactRoot :: Node -> ChainId -> Text
nodePactRoot n c =
    case (_node_serverType n) of
      PactServer -> nodeApiRoot n
      ChainwebServer ->
        nodeChainRoot n c <>
        "/pact/api/v1"

nodeGetCut :: Node -> IO (Response LB.ByteString)
nodeGetCut n = do
    req0 <- parseRequest url
    let req = req0
          { method = "GET"
--          , requestBody = RequestBodyLBS bs
--          , requestHeaders = [(hContentType, "application/json")]
          }
    httpLbs req (_node_httpManager n)
  where
    url = T.unpack root <> "/cut"
    root = nodeApiRoot n

-- | This has to take a HostPort instead of a Node because you might want to
-- query the mempool on nodes that don't expose the service API which has the
-- /info endpoint that is needed to construct a 'Node'.
mempoolPending :: HostPort -> Text -> ChainId -> IO (Response LB.ByteString)
mempoolPending hp network c = do
    req0 <- parseRequest url
    let req = req0
          { method = "POST"
          , requestHeaders = [(hContentType, "application/json")]
          }
    mgr <- newTlsManagerWith (mkManagerSettings (TLSSettingsSimple True False False) Nothing)
    httpLbs req mgr
  where
    url = printf "https://%s/chainweb/0.0/%s/chain/%d/mempool/getPending" (hostPortToText hp) network (unChainId c)

pollNode :: Node -> ChainId -> NE.NonEmpty Hash -> IO (Response LB.ByteString)
pollNode n cid rks = do
    req0 <- parseRequest url
    let bs = encode $ object [ "requestKeys" .= rks ]
    let req = req0
          { method = "POST"
          , requestBody = RequestBodyLBS bs
          , requestHeaders = [(hContentType, "application/json")]
          }
    httpLbs req (_node_httpManager n)
  where
    url = T.unpack root <> "/poll"
    root = nodePactRoot n cid

sendToNode :: Node -> NE.NonEmpty Transaction -> IO (Response LB.ByteString)
sendToNode n ts@(t NE.:| _) = do
    req0 <- parseRequest url
    let bs = encode $ object [ "cmds" .= ts ]
    let req = req0
          { method = "POST"
          , requestBody = RequestBodyLBS bs
          , requestHeaders = [(hContentType, "application/json")]
          }
    httpLbs req (_node_httpManager n)
  where
    url = T.unpack root <> "/send"
    root = nodePactRoot n $ _chainwebMeta_chainId $ _pactCommand_meta $ _transaction_cmd t

localNodeQuery :: Node -> Transaction -> IO (Response LB.ByteString)
localNodeQuery n t = do
    req0 <- parseRequest url
    let req = req0
          { method = "POST"
          , requestBody = RequestBodyLBS $ encode t
          , requestHeaders = [(hContentType, "application/json")]
          }
    httpLbs req (_node_httpManager n)
  where
    url = T.unpack root <> "/local"
    root = nodePactRoot n $ _chainwebMeta_chainId $ _pactCommand_meta $ _transaction_cmd t

responseToValue :: Response LB.ByteString -> Value
responseToValue r = do
    case eitherDecode $ responseBody r of
      Left e -> object [ "error" .= e ]
      Right (v :: Value) -> object
        [ "statusCode" .= statusCode s
        , "statusMsg" .= decodeUtf8 (statusMessage s)
        , "body" .= v
        ]
  where
    s = responseStatus r
