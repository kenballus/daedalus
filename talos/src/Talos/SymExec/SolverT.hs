{-# Language GeneralizedNewtypeDeriving #-}
{-# Language OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

-- | Defines the symbolic parser API.  This wraps the SimpleSMT API

module Talos.SymExec.SolverT (
  -- * Solver interaction monad
  SolverT, runSolverT, mapSolverT, emptySolverState,
  nameToSMTName, fnameToSMTName, tnameToSMTName,
  -- getName,
  SolverState,
  withSolver, SMTVar,
  -- assert, declare, check,
  solverOp, solverState,
  getValue, getValues, getModel,
  -- * Context management
  SolverContext, SolverFrame, getContext, restoreContext,
  freshContext, collapseContext, extendContext, instantiateSolverFrame,
  substSExpr,
  scoped,
  -- * Functions
  SMTFunDef(..), defineSMTFunDefs,
  -- * SMT Polymorphic functions
  PolyFun (..), defineSMTPolyFun, getPolyFun,
  -- * Types
  SMTTypeDef(..), defineSMTTypeDefs,
  typeNameToDefault,
  -- * Context management
  -- modifyCurrentFrame, bindName, -- FIXME: probably should be hidden
  freshName, freshSymbol, defineName, declareName,
  defineSymbol, declareSymbol, declareFreshSymbol, knownFNames,
  reset, assert, check, flush,
  -- * Type Class
  MonadSolver(..),
  -- * Metrics
  contextSize, ContextSize
  ) where

import           Control.Applicative
import           Control.Lens
import           Control.Monad             (MonadPlus, when, void)
import           Control.Monad.Reader      (ReaderT)
import           Control.Monad.State
import           Control.Monad.Trans.Free  (FreeT)
import           Control.Monad.Trans.Maybe (MaybeT)
import           Control.Monad.Writer      (WriterT)
import           Data.Foldable             (for_, toList)
import           Data.Function             (on)
import           Data.Functor              (($>))
import           Data.Generics.Product     (field)
import           Data.Map                  (Map)
import qualified Data.Map                  as Map
import           Data.Maybe                (catMaybes)
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.Text                 (Text)
import           GHC.Generics              (Generic)
import           SimpleSMT                 (SExpr, Solver)
import qualified SimpleSMT                 as S
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Kind as K

import           Daedalus.Core             hiding (freshName)
import qualified Daedalus.Core             as C
import           Daedalus.GUID
import           Daedalus.PP
import           Daedalus.Panic

import           Talos.SymExec.StdLib


-- import Text.Printf (printf)

type SMTVar = String

-- The name of a polymorphic function (map lookup, map insertion, etc)
data PolyFun = PMapLookup SExpr SExpr -- kt vt
             | PMapInsert SExpr SExpr -- kt vt
             | PMapMember SExpr SExpr -- kt vt
             deriving (Eq, Ord, Show)

data QueuedCommand =
  QCAssert SExpr
  | QCDeclare SMTVar SExpr
  | QCDefine  SMTVar SExpr SExpr

-- We manage this explicitly to make sure we are in synch with the
-- solver as push/pop are effectful.
data SolverFrame = SolverFrame
  { frId        :: !Int
  , frCommands   :: !(Seq QueuedCommand)
  -- , frBoundNames :: !(Map Name SMTVar)
  -- ^ May include names bound in closed scopes, to allow for
  --
  -- def P = { x = { $$ = UInt8; $$ > 10 }, ...}
  --
  -- where the execution of the body of x will return
  -- '$$' as it's symbolc result
  } deriving (Generic)

emptySolverFrame :: Int -> SolverFrame
emptySolverFrame i = SolverFrame
  { frId = i
  , frCommands = mempty
  --  , frBoundNames = mempty
  }

nullSolverFrame :: SolverFrame -> Bool
nullSolverFrame fr = {- Map.null (frBoundNames fr) && -} null (frCommands fr)

newtype SolverContext = SolverContext { getSolverContext :: [SolverFrame] }

data SolverState = SolverState
  { solver       :: !Solver
    -- These have to be defined at the top level (before we start pushing etc.)
  , ssKnownTypes :: !(Set TName)
  , ssKnownFuns  :: !(Set FName)
  , ssKnownPolys :: !(Map PolyFun SMTVar)

  , ssFrames          :: ![SolverFrame]
  , ssNFlushedFrames  :: !Int

  , ssCurrentFrame    :: !SolverFrame
  , ssNCurrentFlushed :: !Int

  , ssNextFrameID     :: !Int
  } deriving (Generic)

emptySolverState :: Solver -> SolverState
emptySolverState s = SolverState
  { solver = s
  , ssKnownTypes = mempty
  , ssKnownFuns  = mempty
  , ssKnownPolys = mempty

  , ssFrames          = mempty
  , ssNFlushedFrames  = 0
  , ssCurrentFrame    = emptySolverFrame 0
  , ssNCurrentFlushed = 0
  , ssNextFrameID     = 1
  }

inCurrentFrame :: Monad m => (SolverFrame -> SolverT m a) -> SolverT m a
inCurrentFrame f = SolverT (gets ssCurrentFrame) >>= f

overCurrentFrame :: Monad m => (SolverFrame -> SolverT m (a, SolverFrame)) -> SolverT m a
overCurrentFrame f = do
  (r, frame') <- inCurrentFrame f
  SolverT (modify (\s -> s { ssCurrentFrame = frame' }))
  pure r

modifyCurrentFrame :: Monad m => (SolverFrame -> SolverFrame) -> SolverT m ()
modifyCurrentFrame f = overCurrentFrame (\s -> pure ((), f s))

execQueuedCommand :: MonadIO m => QueuedCommand -> SolverT m ()
execQueuedCommand qc =
  solverOp $ \s ->
    case qc of
      QCAssert se      -> S.assert s se
      QCDeclare v ty   -> void $ S.declare s v ty
      QCDefine  v ty e -> void $ S.define s v ty e

-- | Flushes all pending commands to the solver
flush :: MonadIO m => SolverT m ()
flush = do
  pending <- SolverT $ gets (\s -> drop (ssNFlushedFrames s) (ssFrames s))
    
  for_ pending $ \frame -> do
    mapM_ execQueuedCommand (frCommands frame)
    solverOp S.push

  currentPending <- SolverT $ gets $ \s ->
    Seq.drop (ssNCurrentFlushed s) (frCommands (ssCurrentFrame s))

  mapM_ execQueuedCommand currentPending
  SolverT . modify $ \s -> do
    s { ssNFlushedFrames  = length (ssFrames s)
      , ssNCurrentFlushed = length (frCommands (ssCurrentFrame s))
      }

pushFrame :: MonadIO m => Bool -> SolverT m ()
pushFrame force = do
  s <- SolverT get
  let cf = ssCurrentFrame s
  when (force || not (nullSolverFrame cf)) $ do  
    -- If we have partially executed some commands, execute the rest
    when (ssNCurrentFlushed s > 0) $ do
      flush
      solverOp S.push -- FIXME: This feels wrong here.
      SolverT $ field @"ssNFlushedFrames" += 1

    SolverT $ field @"ssFrames" <>= [cf]
    resetCurrentFrame

--------------------------------------------------------------------------------
-- Exported context/frame management

freshContext :: Monad m => [(SMTVar, SExpr)] -> SolverT m SolverContext
freshContext decls = do
  fr <- freshSolverFrame
  let fr' = fr { frCommands = Seq.fromList $ map (uncurry QCDeclare) decls }
      -- This represents the global namespace, it needs to be there so
      -- we don't overpop.  FIXME: a hack :(  
      baseFrame = emptySolverFrame 0
  pure (SolverContext [baseFrame, fr'])
  
getContext :: MonadIO m => SolverT m SolverContext
getContext = do
  -- We need to save the current frame as extending it later will
  -- break the invariant that equal frame ids is equal contents.
  pushFrame False
  SolverContext <$> SolverT (gets ssFrames)

-- instantiateFrame :: Map SMTVar SExpr -> SolverFrame -> SolverT m SolverFrame

extendContext :: SolverContext -> SolverFrame -> SolverContext
extendContext sc sf
  | nullSolverFrame sf = sc
  | otherwise          = SolverContext ( getSolverContext sc <> [sf])

collapseContext :: Monad m => SolverContext -> SolverT m SolverFrame
collapseContext (SolverContext fs)
  -- kind of a hack, we should ignore empty frames in extendContexet
  | null fs'   = pure (emptySolverFrame 0)
  | [f] <- fs' = pure f
  | otherwise  = do
      fr <- freshSolverFrame
      pure (fr { frCommands = foldMap frCommands fs' })
  where
    fs' = filter (not . nullSolverFrame) fs

-- | This makes all the variables in the solver frame fresh, so that
-- we can use it multiple times.
instantiateSolverFrame :: (Monad m, HasGUID m) =>
                          Map SMTVar SExpr -> SolverFrame ->
                          SolverT m (SolverFrame, Map SMTVar SExpr)
instantiateSolverFrame baseEnv SolverFrame { frCommands = cs } = do
  fr <- freshSolverFrame
  (cs', e) <- runStateT (Seq.fromList . catMaybes . toList <$> traverse go cs) baseEnv
  pure (fr { frCommands = cs' }, e)
  where
    go :: (Monad m, HasGUID m) => QueuedCommand ->
          StateT (Map SMTVar SExpr) (SolverT m) (Maybe QueuedCommand)
    go c = do
      e <- get
      case c of
        QCAssert se      -> pure $ Just $ QCAssert (substSExpr e se)
        QCDeclare v ty
          | v `Map.member` e -> pure Nothing
          | otherwise        -> do
              sym <- freshFor v
              pure $ Just $ QCDeclare sym ty
              
        QCDefine v ty se
          -- Probably doesn't happen
          | Just se' <- Map.lookup v e -> pure $ Just $ QCAssert (S.eq se' se)
          | otherwise  ->  do
              sym <- freshFor v
              let se' = substSExpr e se
              pure $ Just $ QCDefine sym ty se'

    freshFor :: (Monad m, HasGUID m) => String -> StateT (Map SMTVar SExpr) (SolverT m) String
    freshFor sym = do
      -- c.f. freshSymbol
      guid <- lift getNextGUID
      let sym' = stringToSMTName (symPfx sym) guid
      modify (Map.insert sym (S.const sym'))
      pure sym'

    symPfx = takeWhile (/= '@') 

substSExpr :: Map SMTVar SExpr -> SExpr -> SExpr
substSExpr s = go
  where
    go se@(S.Atom a)
      | Just e <- Map.lookup a s = e
      | otherwise = se
    go (S.List ls) = S.List (map go ls)

restoreContext :: MonadIO m => SolverContext -> SolverT m ()
restoreContext (SolverContext fs) = do
  -- Discard current frame.
  solverOp S.pop
  
  fs' <- SolverT (gets ssFrames)
  let commonPfx = takeWhile (uncurry ((==) `on` frId)) (zip fs fs')
      nCommon   = length commonPfx

  nFlushed <- SolverT (gets ssNFlushedFrames)
    
  when (nFlushed > nCommon) $
    solverOp (\s -> S.popMany s (fromIntegral $ nFlushed - nCommon))
  SolverT $ do
    field @"ssFrames"         .= fs
    field @"ssNFlushedFrames" .= min nCommon nFlushed
    
  solverOp S.push -- FIXME: This feels wrong here.
  resetCurrentFrame

--------------------------------------------------------------------------------

-- We always have a common frame representing the global frame.  It is
-- common to all contexts, so should never be popped.
scoped :: MonadIO m => SolverT m a -> SolverT m a
scoped m = do
  pushFrame True
  flush -- This ensures we always have at least 1 frame which is
        -- actually pushed, so we can safely pop in restoreContext.
  m

freshSolverFrame :: Monad m => SolverT m SolverFrame
freshSolverFrame =  emptySolverFrame <$> SolverT (field @"ssNextFrameID" <<+= 1)

resetCurrentFrame :: Monad m => SolverT m ()
resetCurrentFrame = do
  frame <- freshSolverFrame
  SolverT $ do
    field @"ssCurrentFrame"     .= frame
    field @"ssNCurrentFlushed"  .= 0
  
reset :: MonadIO m => SolverT m ()
reset = do
  SolverT (modify (emptySolverState . solver))
  solverOp (\s -> S.ackCommand s (S.app (S.const "reset") []))
  solverOp makeStdLib

-- bindName :: Name -> SMTVar -> SolverFrame -> SolverFrame
-- bindName k v = field @"frBoundNames" %~ Map.insert k v

-- lookupName :: Name -> SolverFrame -> Maybe SExpr
-- lookupName k = fmap S.const . Map.lookup k . frBoundNames

newtype SolverT m a = SolverT { _getSolverT :: StateT SolverState m a }
  deriving (Functor, Applicative, Monad, MonadIO, Alternative, MonadPlus)

withSolver :: (MonadIO m, Monad m) => (Solver -> SolverT m a) -> SolverT m a
withSolver f = do
  s <- SolverT $ gets solver
  f s

data ContextSize = ContextSize
  { csAtomCount :: Int
  , csDeclCount :: Int
  }

instance Semigroup ContextSize where
  cs1 <> cs2 = ContextSize
               { csAtomCount = csAtomCount cs1 + csAtomCount cs2
               , csDeclCount = csDeclCount cs1 + csDeclCount cs2
               }

instance Monoid ContextSize where
  mempty = ContextSize { csAtomCount = 0, csDeclCount = 0 }

-- This is a bit gross, maybe we should use PP 
instance Show ContextSize where
  show cs = "#atoms: " ++ show (csAtomCount cs) ++ " #decls: " ++ show (csDeclCount cs)

-- | A metric over the size of a solver problem, currently the number
-- of atoms.  This is in the monad (as opposed to over `SolverContext`
-- because `getContext` pushes).
contextSize :: Monad m => SolverT m ContextSize
contextSize =
  SolverT $ gets (\s -> foldMap frameSize (ssCurrentFrame s : ssFrames s))

frameSize :: SolverFrame -> ContextSize
frameSize = foldMap queuedCommandSize . frCommands

queuedCommandSize :: QueuedCommand -> ContextSize
queuedCommandSize (QCAssert e) = mempty { csAtomCount = sexprSize e }
queuedCommandSize (QCDeclare {}) = mempty { csDeclCount = 1 }
queuedCommandSize (QCDefine _ _ e) = mempty { csAtomCount = sexprSize e }

-- | A rough guide to the size of an assertion
sexprSize :: SExpr -> Int
sexprSize = go
  where
    go (S.Atom {})    = 1
    go (S.List sexps) = sum (map go sexps)

-- -----------------------------------------------------------------------------
-- Solver operations, over SExprs 

solverOp :: MonadIO m => (Solver -> IO a) -> SolverT m a
solverOp f = withSolver (liftIO . f)

queueSolverOp :: Monad m => QueuedCommand -> SolverT m ()
queueSolverOp qc = 
  modifyCurrentFrame (field @"frCommands" %~ (Seq.|> qc))

-- MonadIO would be enough here.
assert :: MonadIO m => SExpr -> SolverT m ()
assert = queueSolverOp . QCAssert

check :: MonadIO m => SolverT m S.Result
check = flush >> solverOp S.check

getValue :: MonadIO m => SExpr -> SolverT m SExpr
getValue v = do
  res <- getValues [v]
  case res of
    S.List [S.List [_, r]] -> pure r
    _ -> panic (unlines
                 [ "Unexpected response from the SMT solver:"
                 , "  Exptected: a value"
                 , "  Result: " ++ S.showsSExpr res ""
                 ]) []

getValues :: MonadIO m => [SExpr] -> SolverT m SExpr
getValues es = solverOp (\s -> S.command s $ S.fun "get-value" [S.List es])

-- getValues :: MonadIO m => [SExpr] -> SolverT m [(SExpr, SExpr)]
-- getValues es = do
--   res <- solverOp (\s -> S.command s $ S.fun "get-value" [S.List es])
--   case res of
--     S.List vs -> pure (map getVal vs)
--     _ -> bug res
--   where
--     getVal (S.List [e, r]) = (e, r)
--     getVal res = bug res

--     bug res = panic (unlines
--                       [ "Unexpected response from the SMT solver:"
--                       , "  Exptected: a value"
--                       , "  Result: " ++ S.showsSExpr res ""
--                       ]) []

-- Mainly for debugging
getModel :: MonadIO m => SolverT m SExpr
getModel = solverOp (\s -> S.command s $ S.List [S.const "get-model"])

-- -----------------------------------------------------------------------------
-- Names

stringToSMTName :: String -> GUID -> SMTVar
stringToSMTName n g = n ++ "@" ++ showPP g


textToSMTName :: Text -> GUID -> SMTVar
textToSMTName n = stringToSMTName (showPP n)

fnameToSMTName :: FName -> String
fnameToSMTName n = textToSMTName (fnameText n) (fnameId n)

nameToSMTName :: Name -> SMTVar
nameToSMTName n = textToSMTName (maybe "_N" id (nameText n)) (nameId n)

tnameToSMTName :: TName -> SMTVar
tnameToSMTName n = textToSMTName (tnameText n) (tnameId n)

knownFNames :: Monad m => SolverT m (Set FName)
knownFNames = SolverT $ gets ssKnownFuns

getPolyFun :: Monad m => PolyFun -> SolverT m SExpr
getPolyFun pf = do
  m_s <- SolverT $ gets (Map.lookup pf . ssKnownPolys)
  case m_s of
    Just s  -> pure (S.const s)
    Nothing -> panic "Missing polyfun" [show pf]

freshSymbol :: (Monad m, HasGUID m) => Text -> SolverT m SMTVar
freshSymbol pfx = do
  guid <- lift getNextGUID
  pure (textToSMTName pfx guid)

-- Declare a symbol we have previously generated with freshSymbol
declareFreshSymbol :: Monad m => SMTVar -> SExpr -> SolverT m ()
declareFreshSymbol sym ty = queueSolverOp (QCDeclare sym ty)

declareSymbol :: (Monad m, HasGUID m) => Text -> SExpr -> SolverT m SMTVar
declareSymbol pfx ty = do
  sym <- freshSymbol pfx
  queueSolverOp (QCDeclare sym ty)
  pure sym

freshName :: (Monad m, HasGUID m) => Name -> SolverT m SMTVar
freshName n = do
  n' <- lift (C.freshName n)
  let ns = nameToSMTName n'
  -- modifyCurrentFrame (bindName n ns)
  pure ns

defineSymbol :: (MonadIO m, HasGUID m) => Text -> SExpr -> SExpr ->
                SolverT m SMTVar
defineSymbol pfx ty e = do
  sym <- freshSymbol pfx
  queueSolverOp (QCDefine sym ty e)
  pure sym

-- FIXME: we could convert the type here
-- gives a name a value, returns the fresh name
defineName :: (Monad m, HasGUID m) => Name -> SExpr -> SExpr -> SolverT m SMTVar
defineName n ty v = do
  n' <- freshName n
  queueSolverOp (QCDefine n' ty v)
  pure n'

declareName :: (Monad m, HasGUID m) => Name -> SExpr -> SolverT m SMTVar
declareName n ty = do
  n' <- freshName n
  queueSolverOp (QCDeclare n' ty)
  pure n'

solverState :: Monad m => (SolverState -> m (a, SolverState)) -> SolverT m a
solverState f = do
  s <- SolverT get
  (a, s') <- lift (f s)
  SolverT (put s')
  pure a

runSolverT :: SolverT m a -> SolverState -> m (a, SolverState)
runSolverT (SolverT m) s = runStateT m s

mapSolverT :: (m (a, SolverState) -> n (b, SolverState)) -> SolverT m a -> SolverT n b
mapSolverT f (SolverT m) = SolverT (mapStateT f m)

onState :: Monad m => Lens' SolverState a -> (a -> SolverT m a) -> SolverT m ()
onState l f = do
  v <- SolverT $ use l
  r <- f v
  SolverT $ l .= r

--------------------------------------------------------------------------------
-- Types

data SMTTypeDef =
  SMTTypeDef { stdName :: TName
             , stdBody :: [(String, [(String, SExpr)])]
             }

typeNameToDefault :: TName -> SMTVar
typeNameToDefault n = "default-" ++ tnameToSMTName n

-- FIXME: merge into simple-smt

-- Arguments are as for declareDatatype: (name, tparams, constructors)
declareDatatypes :: Solver -> [ (String, [String], [(String, [(String, SExpr)])]) ] -> IO ()
declareDatatypes s ts = S.ackCommand s (S.fun "declare-datatypes" [namesArities, decls])
  where
    namesArities = S.List (map nameArity ts)
    nameArity (n, tparams, _) = S.List [ S.Atom n, S.int (fromIntegral $ length tparams) ]
    decls        = S.List (map decl ts)
    decl (_, [], ctors) = mkbody ctors
    decl (_, tparams, ctors) = S.fun "par" [ S.List (map S.Atom tparams), mkbody ctors ]
    mkbody ctors = S.List [ S.fun ctor [ S.List [ S.Atom fld, ty ]
                                       | (fld, ty) <- flds ]
                          | (ctor, flds) <- ctors
                          ]

defineDefaultType :: MonadIO m => SMTTypeDef -> SolverT m ()
defineDefaultType std = void $ solverOp (\s -> S.declare s n ty)
  where
    ty = S.const (tnameToSMTName (stdName std))
    n  = typeNameToDefault (stdName std)

-- FIXME: merge with defineSMTFunDefs ?
-- FIXME: add defaults
defineSMTTypeDefs :: MonadIO m => Rec SMTTypeDef -> SolverT m ()
defineSMTTypeDefs (NonRec std) = onState (field @"ssKnownTypes") $ \known -> do
  if stdName std `Set.member` known
  then pure known
  else do solverOp doDef
          defineDefaultType std
          pure (Set.insert (stdName std) known)
  where
    doDef s = void $ S.declareDatatype s n' [] (stdBody std)
    n' = tnameToSMTName (stdName std)

defineSMTTypeDefs (MutRec stds) = onState (field @"ssKnownTypes") $ \known -> do
  if not (Set.disjoint allNames known) -- if we define one we should have defined all
  then pure known
  else do solverOp (flip declareDatatypes defs)
          mapM_ defineDefaultType stds
          pure (Set.union allNames known)
  where
    allNames = Set.fromList (map stdName stds)
    defs = map (\std -> (tnameToSMTName (stdName std), [], stdBody std)) stds

-- defineTName :: (MonadIO m) => TName ->  -> SolverT m SExpr
-- defineTName n flds = overCurrentFrame $ \f ->
--   if n `Set.member` frKnownTypes f
--   then pure (sn, f)
--   else do
--     solverOp (\s -> S.declareDatatype s n' [] flds)
--     -- Add a 'default' constant for this type, which is used to
--     -- init. arrays etc.  We never care what it actually is.
--     solverOp (\s -> void $ S.declare s (typeNameToDefault n) sn)

--     pure (sn, f { frKnownTypes = Set.insert n (frKnownTypes f) })

--   where
--     n' = tnameToSMTName n
--     sn = S.const n'



-- -----------------------------------------------------------------------------
-- Functions

data SMTFunDef = SMTFunDef { sfdName :: FName
                           , sfdArgs :: [(SMTVar, SExpr)]
                           , sfdRet  :: SExpr
                           , sfdBody :: SExpr
                           , sfdPureDeps :: Set FName
                           , sfdTyDeps   :: Set TName
                           }

defineSMTFunDefs :: MonadIO m => Rec SMTFunDef -> SolverT m ()
defineSMTFunDefs (NonRec sfd) = onState (field @"ssKnownFuns") $ \funs ->
  if sfdName sfd `Set.member` funs
  then pure funs
  else solverOp doDef $> Set.insert (sfdName sfd) funs
  where
    doDef s = void $ S.defineFun s (fnameToSMTName (sfdName sfd)) (sfdArgs sfd) (sfdRet sfd) (sfdBody sfd)

defineSMTFunDefs (MutRec sfds) = onState (field @"ssKnownFuns") $ \funs ->
  if not (Set.disjoint allNames funs) -- if we define one we should have defined all
  then pure funs
  else solverOp (flip S.defineFunsRec defs) $> Set.union allNames funs
  where
    allNames = Set.fromList (map sfdName sfds)
    defs = map (\sfd -> (fnameToSMTName (sfdName sfd), sfdArgs sfd, sfdRet sfd, sfdBody sfd)) sfds

-- -----------------------------------------------------------------------------
-- Poly functions

defineSMTPolyFun :: (HasGUID m, MonadIO m) => PolyFun -> SolverT m ()
defineSMTPolyFun pf = onState (field @"ssKnownPolys") $ \polys -> do
  if pf `Map.member` polys
    then pure polys
    else case pf of
           PMapLookup kt vt -> do
             fnm <- freshSymbol "mapLookup"
             solverOp (\s' -> mkMapLookup s' fnm kt vt) $> Map.insert pf fnm polys
           PMapMember kt vt -> do
             fnm <- freshSymbol "mapMember"
             solverOp (\s' -> mkMapMember s' fnm kt vt) $> Map.insert pf fnm polys
           PMapInsert kt vt -> do
             fnm <- freshSymbol "mapInsert"
             solverOp (\s' -> mkMapInsert s' fnm kt vt) $> Map.insert pf fnm polys


-- -----------------------------------------------------------------------------
-- Convenience class

class (Monad m, MonadIO (BaseMonad m), HasGUID (BaseMonad m)) => MonadSolver m where
  type BaseMonad m :: K.Type -> K.Type
  liftSolver :: SolverT (BaseMonad m) a -> m a

instance (Monad m, MonadIO m, HasGUID m) => MonadSolver (SolverT m) where
  type BaseMonad (SolverT m) = m
  liftSolver m = m
  
instance (Monad m, MonadSolver m) => MonadSolver (StateT s m) where
  type BaseMonad (StateT s m) = BaseMonad m
  liftSolver = lift . liftSolver  
instance (Monad m, MonadSolver m) => MonadSolver (ReaderT s m) where
  type BaseMonad (ReaderT s m) = BaseMonad m  
  liftSolver = lift . liftSolver
instance (Monoid w, Monad m,  MonadSolver m) => MonadSolver (WriterT w m) where
  type BaseMonad (WriterT w m) = BaseMonad m
  liftSolver = lift . liftSolver  
instance (Monad m, MonadSolver m) => MonadSolver (MaybeT m) where
  type BaseMonad (MaybeT m) = BaseMonad m
  liftSolver = lift . liftSolver
instance (Functor f, Monad m, MonadSolver m) => MonadSolver (FreeT f m) where
  type BaseMonad (FreeT f m) = BaseMonad m
  liftSolver = lift . liftSolver

-- -----------------------------------------------------------------------------
-- instances

instance MonadTrans SolverT where
  lift m = SolverT (lift m)

-- instance Alternative m => Alternative (SolverT m) where


-- instance MonadPlus m => MonadPlus (SolverT m) where

instance PP QueuedCommand where
  pp qc =
    case qc of
      QCAssert e      -> hang "assert" (length ("assert " :: String)) (vcat (map text (lines (S.ppSExpr e ""))))
      QCDeclare v ty  -> "declare" <+> text v <+> text (S.ppSExpr ty "")
      QCDefine v ty e -> "define" <+> text v <+> text (S.ppSExpr ty "") <+> text (S.ppSExpr e "")

instance PP SolverFrame where
  pp sf =
    hang ("index" <> pp (frId sf)) 2 (bullets (map pp (toList $ frCommands sf))) 

instance PP SolverContext where
  pp (SolverContext fs) = bullets (map pp fs)
    
instance (Monad m, HasGUID m) => HasGUID (SolverT m) where
  guidState f = lift (guidState f)
