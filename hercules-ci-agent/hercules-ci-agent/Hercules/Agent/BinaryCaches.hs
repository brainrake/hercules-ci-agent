{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DataKinds #-}
module Hercules.Agent.BinaryCaches
  ( BinaryCaches(..)
  , parseFile
  )
where

import           Protolude

import           Hercules.Agent.Bag
import           Hercules.Agent.Config
import           Hercules.Agent.Log
import           Hercules.Formats.CachixCache
import           Hercules.Error
import           Data.Aeson
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Map                      as M

data BinaryCaches = BinaryCaches {
  cachixCaches :: Map Text CachixCache,
  unknownKinds :: Map Text UnknownKind
}
noCaches :: BinaryCaches
noCaches = BinaryCaches mempty mempty

data UnknownKind = UnknownKind { kind :: Text }
  deriving (Generic, FromJSON)

instance FromJSON BinaryCaches where
  -- note that parseBag already preserves object names.
 parseJSON = parseBag
  (BinaryCaches
  <$> part (\_name -> whenKind "CachixCache" $ \v -> pure $ (parseJSON v))
  <*> part (\_name v -> Just $ parseJSON v)
  )

parseFile :: Config 'Final -> KatipContextT IO BinaryCaches
parseFile cfg = case binaryCachesPath cfg of
  Just fname -> do
    bytes <- liftIO $ BL.readFile $ toS fname
    bcs <- escalateAs (FatalError . toS) $ eitherDecode bytes
    validate (toS fname) bcs
    pure bcs
  Nothing -> do
    logLocM WarningS
      $ "You did not configure any caches. This is ok for evaluation purposes,\
      \ but a cache is required for multi-agent operation and\
      \ to work well across garbage collection."
    pure noCaches

validate :: FilePath -> BinaryCaches -> KatipContextT IO ()
validate fname BinaryCaches { unknownKinds = uks } =
  forM_ (M.toList uks) $ \(k, v) ->
    logLocM WarningS
      $ "In file "
      <> show fname
      <> " in entry "
      <> show k
      <> ": unknown kind "
      <> show (kind v)