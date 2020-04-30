{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}

module Hercules.Agent.Worker
  ( main,
  )
where

import CNix
import qualified CNix.Internal.Raw
import Conduit
import Control.Concurrent.STM
import qualified Data.ByteString as BS
import qualified Data.Conduit
import Data.Conduit.Extras (sinkChan, sinkChanTerminate, sourceChan)
import Data.Conduit.Serialization.Binary
  ( conduitDecode,
    conduitEncode,
  )
import Data.IORef
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Typeable (typeOf)
import Data.UUID (UUID)
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified Hercules.API.Agent.LifeCycle.ServiceInfo
import Hercules.API.Logs.LogEntry (LogEntry)
import qualified Hercules.API.Logs.LogEntry as LogEntry
import Hercules.API.Logs.LogMessage (LogMessage)
import qualified Hercules.API.Logs.LogMessage as LogMessage
import qualified Hercules.Agent.Socket as Socket
import Hercules.Agent.Worker.Build
import qualified Hercules.Agent.Worker.Build.Logger as Logger
import qualified Hercules.Agent.WorkerProtocol.Command as Command
import Hercules.Agent.WorkerProtocol.Command
  ( Command,
  )
import Hercules.Agent.WorkerProtocol.Command.Build (Build)
import qualified Hercules.Agent.WorkerProtocol.Command.Build as Build
import qualified Hercules.Agent.WorkerProtocol.Command.BuildResult as BuildResult
import qualified Hercules.Agent.WorkerProtocol.Command.Eval as Eval
import Hercules.Agent.WorkerProtocol.Command.Eval
  ( Eval,
  )
import qualified Hercules.Agent.WorkerProtocol.Event as Event
import Hercules.Agent.WorkerProtocol.Event
  ( Event (Exception),
  )
import qualified Hercules.Agent.WorkerProtocol.Event.Attribute as Attribute
import qualified Hercules.Agent.WorkerProtocol.Event.AttributeError as AttributeError
import qualified Hercules.Agent.WorkerProtocol.LogSettings as LogSettings
import Katip
import qualified Language.C.Inline.Cpp.Exceptions as C
import Protolude hiding (bracket, evalState)
import qualified System.Environment as Environment
import System.Timeout (timeout)
import UnliftIO.Exception (bracket)
import Prelude ()
import qualified Prelude

data HerculesState
  = HerculesState
      { drvsCompleted :: TVar (Map Text (UUID, BuildResult.BuildStatus)),
        drvsInProgress :: IORef (Set Text),
        herculesStore :: Ptr (Ref HerculesStore),
        wrappedStore :: Ptr (Ref NixStore),
        shortcutChannel :: Chan (Maybe Event)
      }

data BuildException
  = BuildException
      { buildExceptionDerivationPath :: Text,
        buildExceptionDetail :: Maybe Text
      }
  deriving (Show, Typeable)

instance Exception BuildException

main :: IO ()
main = do
  -- setDebug
  --CNix.init
  --Logger.initLogger
  -- setDebug
  [options] <- Environment.getArgs
  -- narinfo-cache-negative-ttl: Always try requesting narinfos because it may have been built in the meanwhile
  let allOptions = Prelude.read options ++ [("narinfo-cache-negative-ttl", "0")]
  for_ allOptions $ \(k, v) -> do
    setGlobalOption k v
    setOption k v
  drvsCompleted_ <- newTVarIO mempty
  drvsInProgress_ <- newIORef mempty
  withStore $ \wrappedStore_ -> withHerculesStore wrappedStore_ $ \herculesStore_ -> do
    setBuilderCallback herculesStore_ mempty
    ch <- liftIO newChan
    let st = HerculesState
          { drvsCompleted = drvsCompleted_,
            drvsInProgress = drvsInProgress_,
            herculesStore = herculesStore_,
            wrappedStore = wrappedStore_,
            shortcutChannel = ch
          }
    let runner =
          ( ( do
                command <- runConduitRes -- Res shouldn't be necessary
                  ( sourceHandle stdin
                      .| conduitDecode
                      .| printCommands
                      .| await
                  )
                  >>= \case
                    Just c -> pure c
                    Nothing -> panic "Not a valid starting command"
                runCommand st ch command
            )
              `catch` ( \e -> do
                          writeChan ch (Just $ Exception (renderException (e :: SomeException)))
                          exitFailure
                      )
          )
            `finally` ( do
                          writeChan ch Nothing
                          putErrText "runner done"
                      )
        writer =
          runConduitRes
            ( sourceChan ch
                .| conduitEncode
                .| concatMapC (\x -> [Chunk x, Flush])
                .| sinkHandleFlush stdout
            )
    void $ do
      withAsync runner $ \runnerAsync -> do
        writer -- runner can stop writer only by passing Nothing in channel (finally)
        putErrText "Writer done"
        wait runnerAsync -- include the potential exception

printCommands :: ConduitT Command Command (ResourceT IO) ()
printCommands =
  mapMC
    ( \x -> do
        liftIO $ hPutStrLn stderr ("Received command: " <> show x :: Text)
        pure x
    )

renderException :: SomeException -> Text
renderException e | Just (C.CppStdException msg) <- fromException e = toSL msg
renderException e
  | Just (C.CppOtherException maybeType) <- fromException e =
    "Unexpected C++ exception" <> foldMap (\t -> " of type " <> toSL t) maybeType
renderException e | Just (FatalError msg) <- fromException e = msg
renderException e = toS $ displayException e

connectCommand :: Chan (Maybe Event) -> ConduitM Command Event (ResourceT IO) () -> IO ()
connectCommand ch conduit =
  runConduitRes
    ( sourceHandle stdin
        .| conduitDecode
        .| printCommands
        .| conduit
        .| sinkChan ch
    )

runCommand :: HerculesState -> Chan (Maybe Event) -> Command -> IO ()
-- runCommand' :: HerculesState -> Command -> ConduitM Command Event (ResourceT IO) ()
runCommand herculesState ch command = do
  -- TODO don't do this
  mainThread <- liftIO $ myThreadId
  case command of
    Command.Eval eval -> connectCommand ch $ do
      void $ liftIO
        $ flip
          forkFinally
          ( \eeu -> case eeu of
              Left e -> throwIO $ FatalError $ "Failed to fork: " <> show e
              Right _ -> pure ()
          )
        $ runConduitRes
          ( Data.Conduit.handleC
              ( \e -> do
                  hPutStrLn stderr $ "Caught exception: " <> renderException e
                  yield $ Event.Error (renderException e)
                  liftIO $ throwTo mainThread e
              )
              ( do
                  runEval herculesState eval
                  liftIO $ throwTo mainThread ExitSuccess
              )
              .| sinkChanTerminate (shortcutChannel herculesState)
          )
      awaitForever $ \case
        Command.BuildResult (BuildResult.BuildResult path attempt result) -> do
          hPutStrLn stderr $ ("BuildResult: " <> show path <> " " <> show result :: Text)
          liftIO $ atomically $ modifyTVar (drvsCompleted herculesState) (M.insert path (attempt, result))
        _ -> pass
    Command.Build build ->
      Logger.withLoggerConduit (logger build) $ do
        connectCommand ch $ runBuild (wrappedStore herculesState) build
    _ ->
      panic "Not a valid starting command"

logger :: Build -> ConduitM () (Vector LogEntry) IO () -> IO ()
logger buildCommand entriesSource = do
  socketConfig <- makeSocketConfig buildCommand
  -- TODO integrate katip more
  withKatip $ Socket.withReliableSocket socketConfig $ \socket -> katipAddNamespace "Build" do
    let conduit =
          entriesSource
            .| Logger.unbatch
            .| Logger.filterProgress
            .| renumber 0
            .| batchAndEnd
            .| socketSink socket
        batch = Logger.batch .| mapC (LogMessage.LogEntries . V.fromList)
        batchAndEnd =
          ( (foldMapTap (Last . ims) `fuseUpstream` batch) >>= \case
              Last (Just (i, ms)) -> yield $ LogMessage.End {i = i + 1, ms = ms}
              Last Nothing -> yield $ LogMessage.End 0 0
          )
          where
            ims (Chunk logEntry) = Just (LogEntry.i logEntry, LogEntry.ms logEntry)
            ims _ = Nothing
        renumber i = await >>= traverse_ \case
          Flush -> yield Flush >> renumber i
          Chunk e -> do
            yield $ Chunk e {LogEntry.i = i}
            renumber (i + 1)
    liftIO $ runConduit $ conduit
    logLocM DebugS "Syncing"
    liftIO (timeout 600_000_000 $ Socket.syncIO $ socket) >>= \case
      Just _ -> pass
      Nothing -> panic "Could not push logs within 10 minutes after completion"
    logLocM DebugS "Logger done"

socketSink :: MonadIO m => Socket.Socket r w -> ConduitT w o m ()
socketSink socket = awaitForever $ liftIO . atomically . Socket.write socket

-- | Perform a foldMap while yielding the original values ("tap").
--
-- '<>' is invoked with the new b on the right.
foldMapTap :: (Monoid b, Monad m) => (a -> b) -> ConduitT a a m b
foldMapTap f = go mempty
  where
    go b = await >>= \case
      Nothing -> pure b
      Just a -> do
        yield a
        go (b <> f a)

withKatip :: (MonadUnliftIO m) => KatipContextT m a -> m a
withKatip m = do
  let format :: forall a. LogItem a => ItemFormatter a
      format = (\_ _ _ -> "@katip ") <> jsonFormat
  handleScribe <- liftIO $ mkHandleScribeWithFormatter format (ColorLog False) stderr (permitItem DebugS) V2
  let makeLogEnv = registerScribe "stderr" handleScribe defaultScribeSettings =<< initLogEnv "Worker" "production"
      initialContext = ()
      extraNs = mempty -- "Worker" is already set in initLogEnv.
        -- closeScribes will stop accepting new logs, flush existing ones and clean up resources
  bracket (liftIO makeLogEnv) (liftIO . closeScribes) $ \logEnv ->
    runKatipContextT logEnv initialContext extraNs m

makeSocketConfig :: Monad m => Build -> IO (Socket.SocketConfig LogMessage Hercules.API.Agent.LifeCycle.ServiceInfo.ServiceInfo m)
makeSocketConfig Build.Build {logSettings = l} = do
  pure Socket.SocketConfig
    { makeHello = pure (LogMessage.LogEntries mempty),
      checkVersion = Socket.checkVersion',
      host = LogSettings.host l,
      path = LogSettings.path l,
      token = toSL $ LogSettings.reveal $ LogSettings.token l
    }

-- TODO: test
autoArgArgs :: Map Text Eval.Arg -> [ByteString]
autoArgArgs kvs = do
  (k, v) <- M.toList kvs
  case v of
    Eval.LiteralArg s -> ["--argstr", toS k, s]
    Eval.ExprArg s -> ["--arg", toS k, s]

withDrvInProgress :: HerculesState -> Text -> IO a -> IO a
withDrvInProgress HerculesState {drvsInProgress = ref} drvPath =
  bracket acquire release . const
  where
    acquire =
      join $ atomicModifyIORef ref $ \inprg ->
        if drvPath `S.member` inprg
          then (inprg, throwIO $ FatalError "Refusing to build derivation that should have been built remotely. Presumably, substitution has failed.")
          else (S.insert drvPath inprg, pass)
    release _ =
      atomicModifyIORef ref $ \inprg ->
        (S.delete drvPath inprg, ())

anyAlternative :: (Foldable l, Alternative f) => l a -> f a
anyAlternative = getAlt . foldMap (Alt . pure)

yieldAttributeError :: Monad m => [ByteString] -> SomeException -> ConduitT i Event m ()
yieldAttributeError path e
  | (Just e') <- fromException e =
    yield $ Event.AttributeError $ AttributeError.AttributeError
      { AttributeError.path = path,
        AttributeError.message =
          "Could not build derivation " <> buildExceptionDerivationPath e'
            <> ", which is required during evaluation."
            <> foldMap (" " <>) (buildExceptionDetail e'),
        AttributeError.errorDerivation = Just (buildExceptionDerivationPath e'),
        AttributeError.errorType = Just "BuildException"
      }
yieldAttributeError path e =
  yield $ Event.AttributeError $ AttributeError.AttributeError
    { AttributeError.path = path,
      AttributeError.message = renderException e,
      AttributeError.errorDerivation = Nothing,
      AttributeError.errorType = Just (show (typeOf e))
    }

maybeThrowBuildException :: MonadIO m => BuildResult.BuildStatus -> Text -> m ()
maybeThrowBuildException result plainDrvText =
  case result of
    BuildResult.Failure -> throwIO $ BuildException plainDrvText Nothing
    BuildResult.DependencyFailure -> throwIO $ BuildException plainDrvText (Just "A dependency could not be built.")
    BuildResult.Success -> pass

runEval :: HerculesState -> Eval -> ConduitM i Event (ResourceT IO) ()
runEval st@HerculesState {herculesStore = hStore, shortcutChannel = shortcutChan, drvsCompleted = drvsCompl} eval = do
  for_ (Eval.extraNixOptions eval) $ liftIO . uncurry setGlobalOption
  for_ (Eval.extraNixOptions eval) $ liftIO . uncurry setOption
  do
    let store = nixStore hStore
    s <- storeUri store
    liftIO $ setBuilderCallback hStore $ \path -> do
      hPutStrLn stderr ("Building " <> show path :: Text)
      let (plainDrv, bangOut) = BS.span (/= fromIntegral (ord '!')) path
          outputName = BS.dropWhile (== fromIntegral (ord '!')) bangOut
          plainDrvText = toS plainDrv
      withDrvInProgress st plainDrvText $ do
        writeChan shortcutChan $ Just $ Event.Build plainDrvText (toSL outputName) Nothing
        derivation <- getDerivation store plainDrv
        outputPath <- getDerivationOutputPath derivation outputName
        hPutStrLn stderr ("Naive ensurePath " <> outputPath)
        ensurePath (wrappedStore st) outputPath `catch` \e0 -> do
          hPutStrLn stderr ("Naive wrapped.ensurePath failed: " <> show (e0 :: SomeException) :: Text)
          (attempt0, result) <-
            liftIO $ atomically $ do
              c <- readTVar drvsCompl
              anyAlternative $ M.lookup plainDrvText c
          maybeThrowBuildException result plainDrvText
          clearSubstituterCaches
          clearPathInfoCache store
          ensurePath (wrappedStore st) outputPath `catch` \e1 -> do
            hPutStrLn stderr ("Fresh ensurePath failed: " <> show (e1 :: SomeException) :: Text)
            writeChan shortcutChan $ Just $ Event.Build plainDrvText (toSL outputName) (Just attempt0)
            -- TODO sync
            result' <-
              liftIO $ atomically $ do
                c <- readTVar drvsCompl
                (attempt1, r) <- anyAlternative $ M.lookup plainDrvText c
                guard (attempt1 /= attempt0)
                pure r
            maybeThrowBuildException result' plainDrvText
            clearSubstituterCaches
            clearPathInfoCache store
            ensurePath (wrappedStore st) outputPath `catch` \e2 -> do
              throwIO $
                BuildException
                  plainDrvText
                  ( Just $
                      "It could not be retrieved on the evaluating agent, despite a successful rebuild. Exception: "
                        <> show (e2 :: SomeException)
                  )
      hPutStrLn stderr ("Built " <> show path :: Text)
    hPutStrLn stderr ("Store uri: " <> s)
    withEvalState store $ \evalState -> do
      hPutStrLn stderr ("EvalState loaded." :: Text)
      args <-
        liftIO $
          evalArgs evalState (autoArgArgs (Eval.autoArguments eval))
      Data.Conduit.handleC (yieldAttributeError []) $
        do
          imprt <- liftIO $ evalFile evalState (toS $ Eval.file eval)
          applied <- liftIO (autoCallFunction evalState imprt args)
          walk evalState args applied
      yield Event.EvaluationDone

walk ::
  Ptr EvalState ->
  Bindings ->
  RawValue ->
  ConduitT i Event (ResourceT IO) ()
walk evalState = walk' True [] 10
  where
    handleErrors path = Data.Conduit.handleC (yieldAttributeError path)
    walk' ::
      -- | If True, always walk this attribute set. Only True for the root.
      Bool ->
      -- | Attribute path
      [ByteString] ->
      -- | Depth of tree remaining
      Integer ->
      -- | Auto arguments to pass to (attrset-)functions
      Bindings ->
      -- | Current node of the walk
      RawValue ->
      -- | Program that performs the walk and emits 'Event's
      ConduitT i1 Event (ResourceT IO) ()
    walk' forceWalkAttrset path depthRemaining autoArgs v =
      -- liftIO $ hPutStrLn stderr $ "Walking " <> (show path :: Text)
      handleErrors path $
        liftIO (match evalState v)
          >>= \case
            Left e ->
              yieldAttributeError path e
            Right m -> case m of
              IsAttrs attrValue -> do
                isDeriv <- liftIO $ isDerivation evalState v
                if isDeriv
                  then do
                    drvPath <- getDrvFile evalState v
                    yield $
                      Event.Attribute Attribute.Attribute
                        { Attribute.path = path,
                          Attribute.drv = drvPath
                        }
                  else do
                    walkAttrset <-
                      if forceWalkAttrset
                        then pure True
                        else-- Hydra doesn't seem to obey this, because it walks the
                        -- x64_64-linux etc attributes per package. Maybe those
                        -- are special cases?
                        -- For now, we will assume that people don't build a whole Nixpkgs
                          liftIO $ getRecurseForDerivations evalState attrValue
                    isfunctor <- liftIO $ isFunctor evalState v
                    if isfunctor && walkAttrset
                      then do
                        x <- liftIO (autoCallFunction evalState v autoArgs)
                        walk' True path (depthRemaining - 1) autoArgs x
                      else do
                        attrs <- liftIO $ getAttrs attrValue
                        void
                          $ flip M.traverseWithKey attrs
                          $ \name value ->
                            when (depthRemaining > 0 && walkAttrset) $
                              walk' -- TODO: else warn
                                False
                                (path ++ [name])
                                (depthRemaining - 1)
                                autoArgs
                                value
              _any -> liftIO $ do
                vt <- rawValueType v
                unless
                  ( lastMay path
                      == Just "recurseForDerivations"
                      && vt
                      == CNix.Internal.Raw.Bool
                  )
                  $ hPutStrLn stderr
                  $ "Ignoring "
                    <> show path
                    <> " : "
                    <> (show vt :: Text)
                pass
