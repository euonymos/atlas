{-# LANGUAGE TemplateHaskell #-}
{-|
Module      : GeniusYield.GYConfig
Copyright   : (c) 2023 GYELD GMBH
License     : Apache 2.0
Maintainer  : support@geniusyield.co
Stability   : develop

-}
module GeniusYield.GYConfig
    ( GYCoreConfig (..)
    , Confidential (..)
    , GYCoreProviderInfo (..)
    , withCfgProviders
    , coreConfigIO
    , coreProviderIO
    , findMaestroTokenAndNetId
    , isNodeKupo
    , isMaestro
    , isBlockfrost
    ) where

import           Control.Exception                (SomeException, bracket, try)
import qualified Data.Aeson                       as Aeson
import           Data.Aeson.TH
import           Data.Aeson.Types
import qualified Data.ByteString.Lazy             as LBS
import           Data.Char                        (toLower)
import qualified Data.Text                        as Text
import           Data.Time                        (NominalDiffTime)

import qualified Cardano.Api                      as Api

import           GeniusYield.Imports
import qualified GeniusYield.Providers.Blockfrost as Blockfrost
-- import qualified GeniusYield.Providers.CachedQueryUTxOs as CachedQuery
import qualified GeniusYield.Providers.Katip      as Katip
import qualified GeniusYield.Providers.Kupo       as KupoApi
import qualified GeniusYield.Providers.Maestro    as MaestroApi
import qualified GeniusYield.Providers.Node       as Node
import           GeniusYield.Types

-- | How many seconds to keep slots cached, before refetching the data.
slotCachingTime :: NominalDiffTime
slotCachingTime = 5

-- | Newtype with a custom show instance that prevents showing the contained data.
newtype Confidential a = Confidential a
  deriving newtype (Eq, Ord, FromJSON)

instance Show (Confidential a) where
  showsPrec _ _ = showString "<Confidential>"

{- |
The supported providers. The options are:

- Local node.socket and a maestro API key
- Cardano db sync alongside cardano submit api
- Maestro blockchain API, provided its API token.

In JSON format, this essentially corresponds to:

= { socketPath: FilePath, kupoUrl: string }
| { maestroToken: string }
| { blockfrostKey: string }

The constructor tags don't need to appear in the JSON.
-}
data GYCoreProviderInfo
  = GYNodeKupo {cpiSocketPath :: !FilePath, cpiKupoUrl :: !Text}
  | GYMaestro {cpiMaestroToken :: !(Confidential Text)}
  | GYBlockfrost {cpiBlockfrostKey :: !(Confidential Text)}
  deriving stock (Show)

$( deriveFromJSON
    defaultOptions
      { fieldLabelModifier = \fldName -> case drop 3 fldName of x : xs -> toLower x : xs; [] -> []
      , sumEncoding = UntaggedValue
      }
    ''GYCoreProviderInfo
 )

coreProviderIO :: FilePath -> IO GYCoreProviderInfo
coreProviderIO filePath = do
  bs <- LBS.readFile filePath
  case Aeson.eitherDecode' bs of
    Left err  -> throwIO $ userError err
    Right cfg -> pure cfg

isNodeKupo :: GYCoreProviderInfo -> Bool
isNodeKupo GYNodeKupo {} = True
isNodeKupo _             = False

isMaestro :: GYCoreProviderInfo -> Bool
isMaestro GYMaestro {} = True
isMaestro _            = False

isBlockfrost :: GYCoreProviderInfo -> Bool
isBlockfrost GYBlockfrost {} = True
isBlockfrost _               = False

findMaestroTokenAndNetId :: [GYCoreConfig] -> IO (Text, GYNetworkId)
findMaestroTokenAndNetId configs = do
    let config = find (isMaestro . cfgCoreProvider) configs
    case config of
        Nothing -> throwIO $ userError "Missing Maestro Configuration"
        Just conf -> do
            let netId = cfgNetworkId conf
            case cfgCoreProvider conf of
              GYMaestro (Confidential token) -> return (token, netId)
              _ -> throwIO $ userError "Missing Maestro Token"

{- |
The config to initialize the GY framework with.
Should include information on the providers to use, as well as the network id.

In JSON format, this essentially corresponds to:

= { coreProvider: GYCoreProviderInfo, networkId: NetworkId, logging: [GYLogScribeConfig], utxoCacheEnable: boolean }
-}
data GYCoreConfig = GYCoreConfig
  { cfgCoreProvider :: !GYCoreProviderInfo
  , cfgNetworkId    :: !GYNetworkId
  , cfgLogging      :: ![GYLogScribeConfig]
  -- , cfgUtxoCacheEnable :: !Bool
  }
  deriving stock (Show)

$( deriveFromJSON
    defaultOptions
      { fieldLabelModifier = \fldName -> case drop 3 fldName of x : xs -> toLower x : xs; [] -> []
      }
    ''GYCoreConfig
 )

coreConfigIO :: FilePath -> IO GYCoreConfig
coreConfigIO file = do
  bs <- LBS.readFile file
  case Aeson.eitherDecode' bs of
    Left err  -> throwIO $ userError err
    Right cfg -> pure cfg

nodeConnectInfo :: FilePath -> GYNetworkId -> Api.LocalNodeConnectInfo Api.CardanoMode
nodeConnectInfo path netId = Node.networkIdToLocalNodeConnectInfo netId path

withCfgProviders :: GYCoreConfig  -> GYLogNamespace -> (GYProviders -> IO a) -> IO a
withCfgProviders
  GYCoreConfig
    { cfgCoreProvider
    , cfgNetworkId
    , cfgLogging
    }
    ns
    f =
    do
      (gyGetParameters, gySlotActions', gyQueryUTxO', gyLookupDatum, gySubmitTx, gyAwaitTxConfirmed) <- case cfgCoreProvider of
        GYNodeKupo path kupoUrl -> do
          let info = nodeConnectInfo path cfgNetworkId
              era = networkIdToEra cfgNetworkId
          kEnv <- KupoApi.newKupoApiEnv $ Text.unpack kupoUrl
          nodeSlotActions <- makeSlotActions slotCachingTime $ Node.nodeGetSlotOfCurrentBlock info
          pure
            ( Node.nodeGetParameters era info
            , nodeSlotActions
            , KupoApi.kupoQueryUtxo kEnv
            , KupoApi.kupoLookupDatum kEnv
            , Node.nodeSubmitTx info
            , KupoApi.kupoAwaitTxConfirmed kEnv
            )
        GYMaestro (Confidential apiToken) -> do
          maestroApiEnv <- MaestroApi.networkIdToMaestroEnv apiToken cfgNetworkId
          maestroGetParams <- makeGetParameters
            (MaestroApi.maestroGetSlotOfCurrentBlock maestroApiEnv)
            (MaestroApi.maestroProtocolParams maestroApiEnv)
            (MaestroApi.maestroSystemStart maestroApiEnv)
            (MaestroApi.maestroEraHistory maestroApiEnv)
            (MaestroApi.maestroStakePools maestroApiEnv)
          maestroSlotActions <- makeSlotActions slotCachingTime $ MaestroApi.maestroGetSlotOfCurrentBlock maestroApiEnv
          pure
            ( maestroGetParams
            , maestroSlotActions
            , MaestroApi.maestroQueryUtxo maestroApiEnv
            , MaestroApi.maestroLookupDatum maestroApiEnv
            , MaestroApi.maestroSubmitTx maestroApiEnv
            , MaestroApi.maestroAwaitTxConfirmed maestroApiEnv
            )
        GYBlockfrost (Confidential key) -> do
          let proj = Blockfrost.networkIdToProject cfgNetworkId key
          blockfrostGetParams <- makeGetParameters
            (Blockfrost.blockfrostGetSlotOfCurrentBlock proj)
            (Blockfrost.blockfrostProtocolParams proj)
            (Blockfrost.blockfrostSystemStart proj)
            (Blockfrost.blockfrostEraHistory proj)
            (Blockfrost.blockfrostStakePools proj)
          blockfrostSlotActions <- makeSlotActions slotCachingTime $ Blockfrost.blockfrostGetSlotOfCurrentBlock proj
          pure
            ( blockfrostGetParams
            , blockfrostSlotActions
            , Blockfrost.blockfrostQueryUtxo proj
            , Blockfrost.blockfrostLookupDatum proj
            , Blockfrost.blockfrostSubmitTx proj
            , Blockfrost.blockfrostAwaitTxConfirmed proj
            )

      bracket (Katip.mkKatipLog ns cfgLogging) logCleanUp $ \gyLog' -> do
        (gyQueryUTxO, gySlotActions) <-
            {-if cfgUtxoCacheEnable
            then do
                (gyQueryUTxO, purgeCache) <- CachedQuery.makeCachedQueryUTxO gyQueryUTxO' gyLog'
                -- waiting for the next block will purge the utxo cache.
                let gySlotActions = gySlotActions' { gyWaitForNextBlock' = purgeCache >> gyWaitForNextBlock' gySlotActions'}
                pure (gyQueryUTxO, gySlotActions)
            else-} pure (gyQueryUTxO', gySlotActions')
        e <- try $ f GYProviders {..}
        case e of
            Right a                     -> pure a
            Left (err :: SomeException) -> do
                logRun gyLog' mempty GYError $ printf "ERROR: %s" $ show err
                throwIO err

