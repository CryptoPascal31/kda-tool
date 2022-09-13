{-# LANGUAGE OverloadedStrings #-}

module Commands.GenTx
  ( genTxCommand
  ) where

------------------------------------------------------------------------------
import           Control.Error
import           Control.Monad.Trans
import           Data.Aeson
import           Data.Bifunctor
import qualified Data.ByteString.Lazy as LB
import qualified Data.Map as M
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Data.Text.IO as T
import qualified Data.Text as T
import           Data.Text.Encoding
import qualified Data.YAML.Aeson as Y
import           System.IO
import           Text.Printf
------------------------------------------------------------------------------
import           TxTemplate
import           Types.Env
------------------------------------------------------------------------------

genTxCommand :: GenTxArgs -> IO ()
genTxCommand args = do
  tplContents <- T.readFile $ _genTxArgs_templateFile args
  res <- runExceptT $ do
    (tpl,holes :: S.Set Text) <- hoistEither $ parseAndGetVars tplContents
    case _genTxArgs_operation args of
      Left _ -> do
        lift $ mapM_ (\h -> T.putStrLn $ h <> ": null") holes
        pure []
      Right gd -> do
        dataContents <- lift $ maybe (pure "{}") T.readFile $ _genData_dataFile gd
        vars :: M.Map Text Value <- hoistEither $ first show $ Y.decode1 (LB.fromStrict $ encodeUtf8 dataContents)
        let remainingHoles = map fst $ filter (isEmptyHole . snd) $ map (\k -> (k, M.lookup k vars)) $ S.toList holes
        rest <- if null remainingHoles
          then pure mempty
          else lift $ do
            hSetBuffering stdout NoBuffering
            vs <- mapM askForValue remainingHoles
            pure $ M.fromList vs
        let augmentedVars = M.union (M.filter (/= Null) vars) rest
        cmds <- hoistEither $ first prettyFailure $ fillValueVars tpl augmentedVars
        let outPat = maybe (defaultOutPat augmentedVars) T.pack $ _genData_outFilePat gd
        (fpTmpl, fpVars) <- hoistEither $ parseAndGetVars outPat
        fps <- hoistEither $ first prettyFailure $ fillFilenameVars fpTmpl (M.restrictKeys augmentedVars fpVars)
        let ps = zip fps cmds
        lift $ mapM_ (\(fp,cmd) -> T.writeFile (T.unpack fp) cmd) ps
        pure ps
  case res of
    Left e -> error e
    Right [] -> pure ()
    Right ps -> putStrLn $ "Wrote commands to: " <> show (map fst ps)

defaultOutPat :: M.Map Text Value -> Text
defaultOutPat m =
    if S.member "chain" arrayKeys
      then "tx-{{chain}}.yaml"
      else case S.toList arrayKeys of
             [] -> "tx.yaml"
             (t:_) -> T.pack $ printf "tx-{{%s}}.yaml" t
  where
    arrayKeys = M.keysSet $ M.filter isArray m

askForValue :: Text -> IO (Text, Value)
askForValue k = do
  T.putStr (k <> ": ")
  str <- T.getLine
  case Y.decode1 (LB.fromStrict $ encodeUtf8 str) of
    Left _ -> putStrLn "Not a valid YAML value" >> askForValue k
    Right v -> pure (k, v)


isArray :: Value -> Bool
isArray (Array _) = True
isArray _ = False

isEmptyHole :: Maybe Value -> Bool
isEmptyHole Nothing = True
isEmptyHole (Just v) = v == Null
