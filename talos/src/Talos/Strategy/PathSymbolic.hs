{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# Language OverloadedStrings #-}

-- Symbolic but the only non-symbolic path choices are those in
-- recursive functions (i.e., we only unroll loops).

-- FIXME: factor out commonalities with Symbolic.hs
module Talos.Strategy.PathSymbolic (pathSymbolicStrat) where


import           Control.Lens                 (_1, _2, at, each, over, (%=),
                                               (%~), (&), (+~), (.=), (.~), Lens', use, (?=))
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Writer         (pass, censor)
import           Data.Bifunctor               (second)
import qualified Data.ByteString              as BS
import           Data.Foldable                (find)
import           Data.Functor.Identity        (Identity (Identity))
import           Data.Generics.Product        (field)
import           Data.List.NonEmpty           (NonEmpty)
import qualified Data.List.NonEmpty           as NE
import           Data.Map                     (Map)
import qualified Data.Map                     as Map
import           Data.Maybe                   (catMaybes, mapMaybe)
import           Data.Set                     (Set)
import qualified Data.Set                     as Set
import qualified Data.Vector                  as Vector
import           Data.Word                    (Word8)
import           GHC.Generics                 (Generic)
import qualified SimpleSMT                    as S
import           System.IO                    (hFlush, stdout)
import           Text.Printf                  (printf)

import           Daedalus.Core                hiding (streamOffset, tByte)
import           Daedalus.Core.Free           (freeVars)
import qualified Daedalus.Core.Semantics.Env  as I
import qualified Daedalus.Core.Semantics.Expr as I
import           Daedalus.Core.Type
import           Daedalus.GUID                (getNextGUID)
import           Daedalus.PP                  (Doc, brackets, commaSep, pp,
                                               showPP, text)
import           Daedalus.Panic
import           Daedalus.Rec                 (topoOrder)
import           Daedalus.Time                (timeIt)
import qualified Daedalus.Value               as I

import           Talos.Analysis.Exported      (ExpCallNode (..), ExpSlice,
                                               SliceId, sliceToCallees)
import           Talos.Analysis.Slice
import           Talos.Strategy.Monad
import           Talos.Strategy.MuxValue      (GuardedSemiSExpr,
                                               GuardedSemiSExprs, MuxValue (..),
                                               ValueMatchResult (..), vUnit)
import qualified Talos.Strategy.MuxValue      as MV
import           Talos.Strategy.OptParser     (Opt, parseOpts)
import qualified Talos.Strategy.OptParser     as P
import           Talos.Strategy.PathCondition (PathCondition,
                                               PathConditionCaseInfo, PathVar,
                                               pathVarToSExpr, loopCountVarToSExpr, LoopCountVar)
import qualified Talos.Strategy.PathCondition as PC
import           Talos.Strategy.PathSymbolicM
import qualified Talos.SymExec.Expr           as SE
import           Talos.SymExec.Funs           (defineSliceFunDefs,
                                               defineSlicePolyFuns)
import           Talos.SymExec.ModelParser    (evalModelP, pNumber, pValue, ModelP)
import           Talos.SymExec.Path
import           Talos.SymExec.SolverT        (SMTVar, SolverT, declareName,
                                               declareSymbol, liftSolver, reset,
                                               scoped)
import qualified Talos.SymExec.SolverT        as Solv
import           Talos.SymExec.StdLib
import           Talos.SymExec.Type           (defineSliceTypeDefs, symExecTy)


-- ----------------------------------------------------------------------------------------
-- Backtracking random strats

pathSymbolicStrat :: Strategy
pathSymbolicStrat = Strategy
  { stratName  = name
  , stratDescr = descr
  , stratParse = mkinst
  }
  where
    name  = "pathsymb"
    descr = "Symbolic execution including non-recursive paths"

    mkinst = do
      c <- parseOpts configOpts defaultConfig
      pure StrategyInstance
        { siName  = name
        , siDescr = descr -- <> parens (text s)
        , siFun   = symbolicFun c
        }

-- ----------------------------------------------------------------------------------------
-- Configuration

data Config = Config { cMaxRecDepth :: Int
                     , cNModels :: Int
                     , cMaxUnsat :: Maybe Int
                     , cNLoopElements :: Int
                     }
  deriving (Generic)

defaultConfig :: Config
defaultConfig = Config 10 1 Nothing 10

configOpts :: [Opt Config]
configOpts = [ P.option "max-depth"  (field @"cMaxRecDepth") P.intP
             , P.option "num-models" (field @"cNModels")     P.intP
             , P.option "max-unsat"  (field @"cMaxUnsat")    (Just <$> P.intP)
             , P.option "num-loop-elements" (field @"cNLoopElements") P.intP
             ]

-- ----------------------------------------------------------------------------------------
-- Main functions

-- FIXME: define all types etc. eagerly
symbolicFun :: Config ->
               ProvenanceTag ->
               ExpSlice ->
               StratGen
symbolicFun config ptag sl = StratGen $ do
  -- defined referenced types/functions
  reset -- FIXME

  md <- getModule
  deps <- sliceToDeps sl
  let slAndDeps = map snd deps ++ [sl]

  forM_ slAndDeps $ \sl' -> do
    defineSliceTypeDefs md sl'
    defineSlicePolyFuns sl'
    defineSliceFunDefs md sl' -- FIXME: not needed 
    
  -- FIXME: this should be calculated once, along with how it is used
  -- by e.g. memoSearch
  scoped $ do
    let topoDeps = topoOrder (second sliceToCallees) deps
    (m_res, sm) <- runSymbolicM (sl, topoDeps) (cMaxRecDepth config) (cNLoopElements config) ptag (stratSlice sl) 
    let go (_, pb) = do
          rs <- buildPaths (cNModels config) (cMaxUnsat config) sm pb
          liftIO $ printf "\tGenerated %d models " (length rs)
          liftIO $ hFlush stdout
          pure (rs, Nothing) -- FIXME: return a generator here.

    case m_res of
      Nothing -> pure ([], Nothing)
      Just rs -> go rs

-- We need to get types etc for called slices (including root slice)
sliceToDeps :: (Monad m, LiftStrategyM m) => ExpSlice -> m [(SliceId, ExpSlice)]
sliceToDeps sl = go Set.empty (sliceToCallees sl) []
  where
    go seen new acc
      | Just (n, rest) <- Set.minView new = do
          sl' <- getSlice n
          let new' = sliceToCallees sl' `Set.difference` seen
          go (Set.insert n seen) (new' `Set.union` rest) ((n, sl') : acc)

    go _ _ acc = pure acc

-- We return the symbolic value (which may contain bound variables, so
-- those have to be all at the top level) and a computation for
-- constructing the path --- we do it in this way to avoid doing a lot
-- of work that gets thrown away on backtracking, so this gets run
-- once in the final (satisfying) state.  Note that the path
-- construction code shouldn't backtrack, so it could be in (SolverT IO)

stratSlice :: ExpSlice -> SymbolicM Result
stratSlice = go
  where
    go sl =  do
      -- liftIO (putStrLn "Slice" >> print (pp sl))
      case sl of
        SHole -> pure (vUnit, SelectedHole)

        SPure e -> do
          let mk v = (v, SelectedHole)
          mk <$> synthesiseExpr e

        SDo x lsl rsl -> do
          let goL = extendPathCursorM PCDoLeft (go lsl)
          
              goR :: PathBuilder -> SymbolicM Result
              goR lpath = over _2 (SelectedDo lpath) <$>
                          extendPathCursorM PCDoRight (go rsl)
                          
          bindNameIn x goL goR

        -- FIXME: we could pick concrete values here if we are willing
        -- to branch and have a concrete bset.
        SMatch bset -> do
          sym <- liftSolver (declareSymbol "b" tByte)
          let bse = S.const sym
              bv  = MV.vOther mempty (Typed TByte sym)

          bassn <- synthesiseByteSet bset bse
          -- This just constrains the byte, we expect it to be satisfiable
          -- (byte sets are typically not empty)
          assertSExpr bassn
          -- liftSolver check -- required?
          ptag <- asks sProvenance
          pure (bv, SelectedBytes ptag (ByteResult sym))

        SChoice sls -> stratChoice sls Nothing --  =<< asks sCurrentSCC

        SCall cn -> stratCallNode cn

        SCase total c -> stratCase total c Nothing -- =<< asks sCurrentSCC

        SLoop lc -> stratLoop lc

        SInverse n ifn p -> do
          n' <- MV.vSExpr mempty (typeOf n) =<< liftSolver (declareName n (symExecTy (typeOf n)))
          primBindName n n' $ do
            pe <- synthesiseExpr p
            ienv <- getIEnv
            assertSExpr (MV.toSExpr (I.tEnv ienv) TBool pe)

            -- Once we have a model, we need to convert all the free
            -- variables in the inverse function expression into values,
            -- and then call the inverse function in the _interpreter_.
            -- Note that n is free in ifn.
            -- 
            -- We could also have the solver execute the function for
            -- us.
            --
            -- We need to resolve any locally bound variables before we
            -- return the path constructor.

            let fvM = Map.fromSet id $ freeVars ifn
            -- Resolve all Names (to semisexprs and solver names)
            venv <- traverse getName fvM
            ptag <- asks sProvenance
            pure (n', SelectedBytes ptag (InverseResult venv ifn))

-- This function runs the given monadic action under the current pathc
-- extended with the give path condition.  In practice, it will run
-- the action, collect any assertions, predicate them by the path
-- condition, and also update the value.  If the computation fails,
-- then the negated path condition will be asserted and 
guardedChoice :: PathVar -> Int -> SymbolicM Result ->
                 SymbolicM (Maybe (GuardedSemiSExprs, (Int, PathBuilder)))
guardedChoice pv i m = pass $ do
  m_r <- getMaybe m
  pure $ case m_r of
           -- Refining should always succeed.
           Just (v, p)
             | Just v' <- MV.refine g v -> (Just (v', (i, p)), extendPath pathGuard)
           _ -> (Nothing, notFeasible)
  where
    g = PC.insertChoice pv i mempty
    pathGuard = PC.toSExpr g

    notFeasible _ = mempty { smAsserts = [S.not pathGuard] }

stratChoice :: [ExpSlice] -> Maybe (Set SliceId) -> SymbolicM Result
-- stratChoice ptag sls (Just sccs)
--   | any hasRecCall sls = do
--       -- Just pick randomly if there is recursion.
--       (i, sl) <- randL (enumerate sls)
--       over _2 (SelectedChoice . ConcreteChoice i) <$> stratSlice ptag sl
--   where
--     hasRecCall sl = not (sliceToCallees sl `Set.disjoint` sccs)

stratChoice sls _ = do
  pv <- freshPathVar (length sls)
  (vs, paths) <-
    unzip . catMaybes <$>
    zipWithM (guardedChoice pv) [0..] (map stratSlice sls)
  -- FIXME: vs should never be empty.
  v <- hoistMaybe (MV.unions' vs)

  -- Record that we have this choice variable, and the possibilities
  recordChoice pv (map fst paths)

  -- liftIO $ print ("choice " <> block "[" "," "]" (map (pp . length . MV.guardedValues) vs)
  --                 <> " ==> " <> pp (length (MV.guardedValues v)))
  pure (v, SelectedChoice (SymbolicChoice pv paths))

stratLoop :: SLoopClass Expr ExpSlice ->
             SymbolicM Result
stratLoop lc =
  case lc of
    SLoopPool sem b -> do
      ltag <- freshSymbolicLoopTag
      -- PCNode would also work, but this is a little less confusing.
      (v, m) <- extendPathCursorM (PCSequence 0) $ stratSlice b
      let xs = VSequence (Just ltag) False [v]
          slv = SLMPerValue
            { slmpCollectionTag = Nothing -- no collection
            , slmpGuard         = [] -- No values we rely on
            , slmpPathBuilder   = [m] -- Single element
            }
          v' = case sem of
                 SemNo  -> vUnit
                 SemYes -> MV.singleton mempty xs
      recordLoop ltag (makeSymbolicLoopModel [slv] [] Nothing)
      pure (v', SelectedLoop (PathLoopPool ltag)) -- We will update later with the contents

    -- Should be SLoopPool
    SManyLoop StructureIndependent _lb _m_ub _b ->
      panic "BUG: saw SManyLoop StructureIndependent" []
    SManyLoop StructureIsNull lb m_ub b -> do
      ltag <- freshSymbolicLoopTag
      -- Here we can assert that the list is empty or non-empty (i.e.,
      -- size 1 to allow pooling).  Note that the _length_ of the
      -- _final list_ is not important to this slice, just
      -- whether it is null/non-null
      lv <- freshLoopCountVar 0 1
      
      let nullCase = pass $ do            
            let g = PC.insertLoopCount lv 0 mempty
                pathGuard = PC.toSExpr g
                -- We don't use the tag as there is no need to gather
                -- later.
                v = VSequence Nothing False []
            pure (MV.singleton g v, extendPath pathGuard)

          nonNullCase = pass $ do
            -- PCNode would also work, but this is a little less confusing.
            (v, m) <- extendPathCursorM (PCSequence 0) $ stratSlice b
            let v' = VSequence (Just ltag) False [v]
                slv = SLMPerValue
                  { slmpCollectionTag = Nothing -- no collection
                  , slmpGuard         = [] -- No values we rely on
                  , slmpPathBuilder   = [m] -- Single element
                  }
            
                g = PC.insertLoopCount lv 1 mempty
                pathGuard = PC.toSExpr g
                -- We don't use the tag as there is no need to gather
                -- later.

            pure (MV.singleton g v', extendPath pathGuard)

      vs <- sequence [nullCase, nonNullCase]
      -- FIXME: vs should never be empty.
      v <- hoistMaybe (MV.unions' vs)
      
      
      -- recordLoop ltag (makeSymbolicLoopModel [v] [] Nothing)
      pure (v, SelectedLoop (PathLoopPool ltag)) -- We will update later with the contents
      undefined
      
    SManyLoop StructureDependent lb m_ub b -> do
      ltag <- freshSymbolicLoopTag      
      undefined

      
    SRepeatLoop str n e b -> undefined
    SMorphismLoop lm -> undefined

-- We represent disjunction by having multiple values; in this case,
-- if we have matching values for the case alternative v1, v2, v3,
-- with guards g1, g2, g3, then for each value returned by the RHS
-- of the pattern we will combine with each g1, g2, g3 (to get 3
-- sets of values) which we then union.  As a formula, we have
--
-- (ga, va) \/ (gb, vb) \/ ... = RHS
-- return  (ga /\ g1, va) \/ (gb /\ g1, vb) \/ (gc /\ g1, vc)
--      \/ (ga /\ g2, va) \/ (gb /\ g2, vb) \/ (gc /\ g2, vc)
--      \/ ...
--
-- This can greatly increase the number of values

-- FIXME: merge with the above?
guardedCase :: NonEmpty PathCondition -> Pattern -> SymbolicM Result ->
               SymbolicM (Maybe (GuardedSemiSExprs, (Pattern, PathBuilder)))
guardedCase gs pat m = pass $ do
  m_r <- getMaybe m
  pure $ case m_r of
           Just r  -> (mk r, extendPath pathGuard)
           Nothing -> (Nothing, notFeasible)
  where
    mk (v, pb) = do
      x <-  MV.unions' (mapMaybe (flip MV.refine v) (NE.toList gs))
      pure (x, (pat, pb))

    pathGuard = MV.orMany (map PC.toSExpr (NE.toList gs))
    notFeasible _ = mempty { smAsserts = [S.not pathGuard] }

stratCase ::  Bool -> Case ExpSlice -> Maybe (Set SliceId) -> SymbolicM Result
stratCase _total cs m_sccs = do
  inv <- getName (caseVar cs)
  (alts, preds) <- liftSemiSolverM (MV.semiExecCase cs)
  let mk1 (gs, (pat, a)) = guardedCase gs pat (stratSlice a)
  case m_sccs of
    Just sccs
      | any (hasRecCall sccs . snd . snd) alts -> do
          -- In this case we just pick a random alt (and maybe
          -- backtrack at some point?).  We ignore preds, as we assert
          -- that the alt is reachable.

          -- FIXME(!): this is incomplete
          (v, (_pat, pb)) <- putMaybe . mk1 =<< randL alts
          pure (v, SelectedCase (ConcreteCase pb))

    _ -> do
      stag <- freshSymbolicCaseTag

      (vs, paths) <- unzip . catMaybes <$> mapM mk1 alts
      v <- hoistMaybe (MV.unions' vs)
      -- liftIO $ print ("case " <> pp (caseVar cs) <> " " <> block "[" "," "]" (map (pp . length . MV.guardedValues) vs)
      --                 <> " ==> " <> pp (length (MV.guardedValues v))
      --                 <> pp (text . typedThing <$> snd (head (MV.guardedValues v))))

      -- preds here is a list [(PathCondition, SExpr)] where the PC is the
      -- condition for the value, and the SExpr is a predicate on when
      -- that value is enabled (matches some guard).  We require that at
      -- least 1 alternative is enabled, so we assert the disjunction of
      -- (g <-> s) for (g,s) in preds.  We could also assert the
      -- conjunction of (g --> s), which does not assert that the guard
      -- holds (only that the enabling predicate holds when that value is
      -- enabled).

      enabledChecks preds
      recordCase stag (caseVar cs) [ (pcs, pat) | (pcs, (pat, _)) <- alts ]

      pure (v, SelectedCase (SymbolicCase stag inv paths))

  where
    enabledChecks preds
      --  | total     = pure ()
      -- FIXME: Is it OK to omit this if the case is total?      
      | otherwise = do
          let preds' = over (each . _1) PC.toSExpr preds
              patConstraints =
                MV.andMany ([ S.implies g c | (g, SymbolicMatch c) <- preds' ]
                            ++ [ S.not g | (g, NoMatch) <- preds' ])

          oneEnabled <- case [ g | (g, vmr) <- preds', vmr /= NoMatch ] of
                          [] -> do
                            inv <- getName (caseVar cs)
                            liftIO $ putStrLn ("No matches " ++ showPP cs ++ "\nValue\n"
                                               ++ showPP (text . typedThing <$> inv)
                                               ++ "\n" ++ show preds')
                            infeasible
                          ps -> pure (MV.orMany ps)

          assertSExpr oneEnabled
          assertSExpr patConstraints

    hasRecCall sccs = \sl -> not (sliceToCallees sl `Set.disjoint` sccs)

-- FIXME: this is copied from BTRand
stratCallNode :: ExpCallNode ->
                 SymbolicM Result
stratCallNode cn = do
  -- liftIO $ print ("Entering: " <> pp cn)
  sl <- getSlice (ecnSliceId cn)
  over _2 (SelectedCall (ecnIdx cn))
    <$> enterFunction (ecnSliceId cn) (ecnParamMap cn)
          (extendPathCursorM PCNode (stratSlice sl))

-- -----------------------------------------------------------------------------
-- Merging values


-- The idea here is that we have e.g. a choose where we have a number
-- of results, depending on which path is chosen.  Where possible we
-- would like to keep values in Haskell (i.e. avoid turning everything
-- into an sexpr) so we can simplify e.g. field access.  In particular
-- we would like to avoid having to use recursive functions in the
-- solver, so we try to keep e.g. arrays in Haskell too.

-- Consider
--
-- def P = block
--   a = First
--      lA = @${'a']
--      bA = @$['A']
--   b = First
--      lB = @${'b']
--      bB = @$['B']
--   { a is lA; b is lB } | {a is bA; b is bB }
--
-- i.e., we are not allows bA, lB or lA, bB.  We could represent a as
--
--  [ (lA, ca = 0), (bA, ca = 1) ]
--
-- where ca is the choice variable for a, and similarly for b.  Now,
-- when we get to the LHS of the predicate (call the choice variable
-- cP) we will have a 'case a of lA -> ()' for the first 'is', which
-- generates the path condition
--
-- cP = 0 --> (ca = 0 /\ ca \neq 1)
--
-- where the 'ca \neq 1' is because the case is partial (any
-- constructor without a corresponding alternative is
-- negated). Likewise, we get a similar constraint for 'b is lB'.

-- Consider
--
-- def P = block
--   x = Choose
--     x1 = ^ 1
--     x2 = ^ 2
--   n = ^ case x of
--     x1 v -> v
--     x2 v -> v
--   ...
--
-- the interesting question here being what should n look like?  An
-- obvious answer is
--
--  [ (1, cx = 0), (2, cx = 1) ]
--
-- and so for 'n + n' we would have
--
-- [ (2, cx = 0 /\ cx = 0)
-- , (3, cx = 0 /\ cx = 1)
-- , (3, cx = 1 /\ cx = 0)
-- , (4, cx = 1 /\ cx = 1)
-- ]
--
-- where, if no other processing is donw, we may get large numbers of
-- infeasible values (as for 'n + n = 3' in this example).  For choice
-- variables this should be easy, but for cases over constants 'case x
-- of 1,2,3 -> ...' we can have equality between expressions and
-- literals.


-- def M_P n b i =
--   if i < n then
--     block
--       let v = P
--       let b' = push v b
--       M_P n b' (i + 1)
--   else pure b

-- def C_M_P =
--   n = UInt8
--   rs = M_P n emptyBuilder 0
--   s = Q
--   map (r in rs) (R r s)

-- def M = block
--   x = P
--   ys = Many n (Q x)




 --  { r = [0, 1, 2] }

-- M_P n emptyBuilder 0 { [0, 1, 2] }
-- (unfold M_P)
--
-- if i < n then
--   block
--     let v = UInt8
--     M_P n (push v b) (i + 1)
-- else pure b
-- { [0, 1, 2] | bs = [] }

-- i < n /\
--     let v1 = UInt8 /\
--       WP (if i + 1 < n then
--         block
--         let v2 = UInt8
--         M_P n (push v2 (push v1 b)) ((i + 1) + 1)
--        else pure (push v1 b), { [0, 1, 2] | bs = [] })

-- n <= i /\ b = [0, 1, 2] /\ bs = []

-- { [0, 1, 2] | bs = [] }


-- { b = [0, 1, 2] /\ i = n /\ bs = []
-- \/ (b = [1, 2] /\ i + 1 = n /\ bs = [0] )
-- \/ (b = [2] /\ i + 2 = n /\ bs = [0, 1] )
-- \/ (b = [] /\ i + 3 = n /\ bs = [0, 1, 2]) }

--   (0 + 3 = n /\ bs = [0, 1, 2])

--  ==> n = 3 /\ bs = [0, 1, 2]

-- ================================================================================

-- if i < n then
--   block
--     let v = UInt8
--     M_P { n = n, b = push v b', i = i' + 1 }
-- else (i >= n /\ b = [0, 1, 2]) pure b 

-- (i >= n /\ b = [0, 1, 2])

-- {  }
-- if i < n then
--   block
--     let v' = UInt8
--     { i' + 1 >= n /\ push v' b' = [0, 1, 2] } === { i' + 1 >= n /\ v' = 0 /\ b' = [1, 2] }

-- if i < n then
--   block
--     { i' + 1 >= n /\ push v' b' = [0, 1, 2] }

-- ================================================================================

-- if i < n then
--   block
--     let v = UInt8
--     M_P n (push v b) (i + 1)
-- else pure b
-- { RESULT = vs }
--
-- {i >= n /\ b = vs}
--
-- (vs = [] /\ i = 0) -- initial call was the one we wanted
--
-- { b = push v' b', i = i' + 1) (b = vs /\ (vs \neq [] \/ i \neq 0))
--
-- push v' b' = vs /\ (vs \neq [] \/ i + 1 \neq 0)
-- {\exists v'. v' = UInt8 /\ push v' b' = vs /\ i' < n } M_P n b' i'

-- case vs of
--   []      -> emit [] >> pure 0
--   v : vs' -> emit v >> n' = G vs' (i - 1) >> return (n' + 1)
--

-- def M_P n =
--  if n = 0 then pure []
--  else { let v = P; vs = M_P (n - 1); ^ v : vs }

-- { RESULT = vs }

-- def S = { $['(']; $$ = S; $[')']; } <| $[ !['(',')] ]
-- 
-- { RESULT = 'foo' }

-- ----------------------------------------------------------------------------------------
-- Solver helpers

synthesiseExpr :: Expr -> SymbolicM GuardedSemiSExprs
synthesiseExpr e = do
  liftSemiSolverM . MV.semiExecExpr $ e

-- Not a GuardedSemiSExprs here as there is no real need
synthesiseByteSet :: ByteSet -> S.SExpr -> SymbolicM S.SExpr
synthesiseByteSet bs b = liftSymExecM $ SE.symExecByteSet b bs

-- ----------------------------------------------------------------------------------------
-- Utils

enumerate :: Traversable t => t a -> t (Int, a)
enumerate t = evalState (traverse go t) 0
  where
    go a = state (\i -> ((i, a), i + 1))


-- ----------------------------------------------------------------------------------------
-- Model parsing and enumeration.
--
-- This code uses the Monad instance for Maybe pretty heavily, sorry :/

data ModelState = ModelState
  { msPathVars :: Map PathVar Int
  , msValues   :: Map SMTVar I.Value
  , msLoopCounts :: Map LoopCountVar Int
  } deriving Generic

-- Only works if we merge disjoint/agreeing models  
instance Semigroup ModelState where
  ms <> ms' = ModelState
    { msPathVars   = msPathVars ms <> msPathVars ms'
    , msValues     = msValues ms <> msValues ms'
    , msLoopCounts = msLoopCounts ms <> msLoopCounts ms'
    }

instance Monoid ModelState where
  mempty = ModelState mempty mempty mempty

data ModelParserState = ModelParserState
  { mpsContext :: ModelState
  -- ^ Read-only, used to cache the solver model in the context.
  , mpsState   :: ModelState
  -- ^ Captures the curent solver model.
  , mpsMMS      :: MultiModelState
  -- ^ The stats across multiple models
  , mpsLoopInfo :: ()
  } deriving Generic

-- FIXME: clag
getByteVar :: SMTVar -> ModelParserM Word8
getByteVar symB = I.valueToByte <$> getValueVar (Typed TByte symB)

getModelVar :: Lens' ModelState (Map a b) ->
               (a -> S.SExpr) ->
               ModelP b ->
               (a -> b -> MultiModelState -> MultiModelState) ->
               a ->
               ModelParserM b
getModelVar msLens toSExpr pVal updateStats pv = do
  m_i <- use (field @"mpsContext" . msLens . at pv)   
  case m_i of
    Just i -> pure i
    Nothing -> do
      m_i <- use (field @"mpsState" . msLens . at pv)
      case m_i of
        Just i -> pure i
        Nothing -> do
          sexp <- lift (Solv.getValue (toSExpr pv))
          n <- case evalModelP pVal sexp of
                 []    -> panic "No parse" []
                 b : _ -> pure b
          field @"mpsState" . msLens . at pv ?= n
          field @"mpsMMS" %= updateStats pv n
          pure n

getPathVar :: PathVar -> ModelParserM Int
getPathVar =
  getModelVar (field @"msPathVars") PC.pathVarToSExpr
              (fromIntegral <$> pNumber)
              updateStats 
  where
    -- bit gross doing this here ...
    updateStats pv n mms
      | Just chi <- Map.lookup pv (mmsChoices mms)
      , n `notElem` mmschiSeen chi =
        -- If we have seen all the choices then exhaust.
        let res | length (mmschiSeen chi) + 1 == length (mmschiAllChoices chi) = Nothing
                | otherwise  = Just (chi & field @"mmschiSeen" %~ (n :))
        in mms & field @"mmsChoices" . at pv .~ res
               & field @"mmsNovel" +~ 1
      | otherwise = mms & field @"mmsSeen" +~ 1

-- Maybe not worth caching?
getLoopVar :: LoopCountVar -> ModelParserM Int
getLoopVar =
  getModelVar (field @"msLoopCounts") PC.loopCountVarToSExpr
              (fromIntegral <$> pNumber)
              updateStats 
  where
    -- FIXME: update this
    updateStats _v _n mms = mms

getValueVar :: Typed SMTVar -> ModelParserM I.Value
getValueVar (Typed ty x) = do
  getModelVar (field @"msValues") S.const
              (pValue ty)
              updateStats x
  where
    updateStats _ _ mms = mms

type ModelParserM a = StateT ModelParserState (SolverT StrategyM) a

runModelParserM :: MultiModelState -> ModelParserM a -> SolverT StrategyM (a, MultiModelState)
runModelParserM mms mp =
  (_2 %~ mpsMMS) <$> runStateT mp (ModelParserState mempty mempty mms)

data MMSCaseInfo = MMSCaseInfo
  { -- Read only
    mmsciName    :: Name      -- ^ Name of the case var, for debugging
  , mmsciAllPats :: [(S.SExpr, Pattern)] -- ^ All patterns (read only)
  , mmsciPath    :: S.SExpr -- ^ Path to the case
  -- Updated
  , mmsciSeen    :: [Pattern] -- ^ Case alts we have already seen
  } deriving Generic
  
data MMSChoiceInfo = MMSChoiceInfo
  { -- Read only
    mmschiAllChoices :: [Int] -- ^ All choices (read only)
  , mmschiPath       :: S.SExpr -- ^ Path to the choice
  -- Updated  
  , mmschiSeen       :: [Int]     -- ^ Choice alts we have already seen
  } deriving Generic
  
-- This contains all the choices we haven't yet seen.  It might be
-- better to just negate the seen choices, but this is a bit simpler
-- for now.
data MultiModelState = MultiModelState
  { mmsChoices :: Map PathVar MMSChoiceInfo
  , mmsCases   :: Map SymbolicCaseTag MMSCaseInfo
  , mmsNovel   :: Int -- ^ For a run, how many novel choices/cases we saw.
  , mmsSeen    :: Int -- ^ For a run, how many seen choices/cases we saw.
  } deriving Generic

-- This just picks one at a time, we could also focus on a particular (e.g.) choice until exhausted.
nextChoice :: MultiModelState -> SolverT StrategyM (Maybe (S.SExpr, MultiModelState -> MultiModelState, Doc))
nextChoice mms
  -- FIXME: just picks the first, we could be e.g. random
  | Just ((pv, chi), _mmsC) <- Map.minViewWithKey (mmsChoices mms) = do
      let notSeen = S.distinct (pathVarToSExpr pv : map (S.int . fromIntegral) (mmschiSeen chi))
          exhaust = over (field @"mmsChoices") (Map.delete pv)
      pure (Just (MV.andMany [notSeen, mmschiPath chi]
                 , exhaust
                 , pp pv <> " in " <> brackets (commaSep [ pp i | i <- mmschiAllChoices chi, i `notElem` mmschiSeen chi])))
  | Just ((stag, ci), _mmsC) <- Map.minViewWithKey (mmsCases mms) = do
      let notSeen = S.not (MV.orMany [ p | (p, pat) <- mmsciAllPats ci, pat `elem` mmsciSeen ci ])
          exhaust = over (field @"mmsCases") (Map.delete stag)
          -- p = MV.orMany (map PC.toSExpr (NE.toList vcond))
      pure (Just ( MV.andMany [notSeen, mmsciPath ci]
                 , exhaust
                 , pp (mmsciName ci) <> "." <> pp stag <> " in "
                   <> brackets (commaSep [ pp pat | (_, pat) <- mmsciAllPats ci, pat `notElem` mmsciSeen ci])))  -- <> commaSep (map pp (mmsciSeen ci))))
  | otherwise = pure Nothing

modelChoiceCount :: MultiModelState -> Int
modelChoiceCount mms = choices + cases
  where
    choices = sum $ [ length (mmschiAllChoices chi) - length (mmschiSeen chi)
                    | chi <- Map.elems (mmsChoices mms)
                    ]
    cases   = sum $ [ length (mmsciAllPats ci) - length (mmsciSeen ci)
                    | ci <- Map.elems (mmsCases mms)
                    ]


symbolicModelToMMS :: SymbolicModel -> MultiModelState
symbolicModelToMMS sm = MultiModelState
  { mmsChoices = fmap mkCh (smChoices sm)
  , mmsCases   = fmap mkCi (smCases   sm)
  , mmsNovel   = 0
  , mmsSeen    = 0
  }
  where
    mkCh (paths, idxs) = MMSChoiceInfo
      { mmschiAllChoices = idxs
      , mmschiPath = MV.andMany paths
      , mmschiSeen = []
      }
    mkCi (name, paths, pats) = MMSCaseInfo
      { mmsciName    = name
      , mmsciAllPats = over (each . _1) (MV.orMany . map PC.toSExpr . NE.toList) pats
      , mmsciPath    = MV.andMany paths
      , mmsciSeen    = []
      }

nullMMS :: MultiModelState -> Bool
nullMMS ms = Map.null (mmsCases ms) && Map.null (mmsChoices ms)
      
buildPaths :: Int -> Maybe Int -> SymbolicModel -> PathBuilder -> SolverT StrategyM [SelectedPath]
buildPaths ntotal nfails sm pb = do
  liftIO $ printf "\n\t%d choices and cases" (modelChoiceCount st0)
  (_, tassert) <- timeIt $ do
    mapM_ Solv.assert (smAsserts sm)
    Solv.flush
  liftIO $ printf "; initial model time: %.3fms\n" (fromInteger tassert / 1000000 :: Double)

  if not (nullMMS st0)
    then Solv.getContext >>= go 0 0 st0 []
    else do -- Only 1 choice, so take it.      
      (r, tcheck) <- timeIt Solv.check
      liftIO $ printf "\t(single): solve time: %.3fms" (fromInteger tcheck / 1000000 :: Double)
      check st0 r >>= \case
        Left errReason -> do
          liftIO $ printf " (%s)\n" errReason
          pure []
        Right (p, _st', tbuild) -> do
          liftIO $ printf ", build time: %.3fms\n" (fromInteger tbuild / 1000000 :: Double)
          pure [p]

  where
    st0 = symbolicModelToMMS sm
    go :: Int -> Int -> MultiModelState -> [SelectedPath] -> Solv.SolverContext ->
          SolverT StrategyM [SelectedPath]
    go _na _nf _st acc ctxt | length acc == ntotal = acc <$ Solv.restoreContext ctxt
    go _na nf  _st acc ctxt | Just nf == nfails    = acc <$ Solv.restoreContext ctxt
    go na nf st acc ctxt = do
      Solv.restoreContext ctxt
      m_next <- nextChoice st
      case m_next of
        Nothing -> pure acc -- Done, although we could try for different byte values?
        Just (assn, exhaust, descr) -> do
          (_, tassert) <- timeIt $ do
            Solv.assert assn
            Solv.flush
          (r, tcheck) <- timeIt Solv.check
          
          liftIO $ printf "\t%d: (%s) %d choices and cases, assert time: %.3fms, solve time: %.3fms"
                          na
                          (show descr) (modelChoiceCount st)
                          (fromInteger tassert / 1000000 :: Double)
                          (fromInteger tcheck / 1000000 :: Double)
          
          check st r >>= \case
            Left errReason -> do
              liftIO $ printf " (%s)\n" errReason
              go (na + 1) (nf + 1) (exhaust st) acc ctxt
            Right (p, st', tbuild) -> do
              liftIO $ printf ", build time: %.3fms, novel: %d, reused: %d\n"
                (fromInteger tbuild / 1000000 :: Double)
                (mmsNovel st') (mmsSeen st')
              go (na + 1) nf st' (p : acc) ctxt
    check :: MultiModelState -> S.Result ->
             SolverT StrategyM (Either String
                                 (SelectedPath, MultiModelState, Integer))
    check st r = do
      case r of
        S.Unsat   -> pure (Left "unsat")
        S.Unknown -> pure (Left "unknown")
        S.Sat     -> do
          ((p, st'), tbuild) <- timeIt $ buildPath st pb
          pure (Right (p, st', tbuild))

-- FIXME: we could get all the sexps from the solver in a single query.
buildPath :: MultiModelState -> PathBuilder ->
             SolverT StrategyM (SelectedPath, MultiModelState)
buildPath mms0 = runModelParserM mms . go
  where
    -- reset counters
    mms = mms0 { mmsNovel = 0, mmsSeen = 0 }
    go :: PathBuilder -> ModelParserM SelectedPath
    go SelectedHole = pure SelectedHole
    go (SelectedBytes ptag r) = SelectedBytes ptag <$> resolveResult r
    go (SelectedDo l r) = SelectedDo <$> go l <*> go r
    go (SelectedChoice pib) = SelectedChoice <$> buildPathChoice pib
    go (SelectedCall i p) = SelectedCall i <$> go p
    go (SelectedCase pib) = SelectedCase <$> buildPathCase pib
    go (SelectedLoop lp) = SelectedLoop <$> buildLoop lp
      
    buildLoop (PathLoopElements m_v els) = do
      len <- maybe (pure (length els)) getLoopVar m_v
      ps <- mapM go (take len els)
      pure (SelectedLoopElements (Map.fromList (zip [0..] ps)))

    buildLoop (PathLoopPool tag) = undefined

    buildPathChoice :: PathChoiceBuilder PathBuilder ->
                       ModelParserM (PathIndex SelectedPath)
    buildPathChoice (ConcreteChoice i p) = PathIndex i <$> go p
    buildPathChoice (SymbolicChoice pv ps) = do
      i <- getPathVar pv
      let p = case lookup i ps of
                Nothing  -> panic "Missing choice" []
                Just p'  -> p'
      PathIndex i <$> go p

    buildPathCase :: PathCaseBuilder PathBuilder ->
                     ModelParserM (Identity SelectedPath)
    buildPathCase (ConcreteCase p) = Identity <$> go p
    buildPathCase (SymbolicCase stag gses ps) = do
      m_v <- gsesModel gses
      v <- case m_v of
             Nothing  -> do
               panic "Missing case value" [showPP (text . typedThing <$> gses)]
             Just v'  -> pure v'
      let (pat, p) = case find (flip I.matches v . fst) ps of
            Nothing ->
              panic "Missing case alt" [showPP v
                                       , showPP (text . typedThing <$> gses)
                                       , showPP (commaSep (map (pp . fst) ps))
                                       ]
            Just r -> r

      field @"mpsMMS" %= updateCaseStats stag pat

      Identity <$> go p

    -- c.f. getPathVar
    updateCaseStats stag pat mms'
      | Just ci <- Map.lookup stag (mmsCases mms')
      , pat `notElem` mmsciSeen ci =
        let res | length (mmsciSeen ci) + 1 == length (mmsciAllPats ci) = Nothing
                | otherwise  = Just (ci & field @"mmsciSeen" %~ (pat :))
        in mms' & field @"mmsCases" . at stag .~ res
                & field @"mmsNovel" +~ 1
      | otherwise = mms' & field @"mmsSeen" +~ 1

    resolveResult :: SolverResult -> ModelParserM BS.ByteString
    resolveResult (ByteResult b) = BS.singleton <$> getByteVar b
    resolveResult (InverseResult env ifn) = do
      -- FIXME: we should maybe make this lazy
      m_venv <- sequence <$> traverse gsesModel env
      case m_venv of
        Nothing -> panic "Couldn't construct environment" []
        Just venv -> do
          ienv <- liftStrategy getIEnv -- for fun defns
          let ienv' = ienv { I.vEnv = venv }
          pure (I.valueToByteString (I.eval ifn ienv'))

-- short-circuiting
andM :: Monad m => [m Bool] -> m Bool
andM [] = pure True
andM (m : ms) = do
  b <- m
  if b then andM ms else pure False

-- short-circuiting
firstM :: Monad m => (a -> m Bool) -> [a] -> m (Maybe a)
firstM _f [] = pure Nothing
firstM f (x : xs) = do
  b <- f x
  if b then pure (Just x) else firstM f xs

pathConditionModel :: PathCondition -> ModelParserM Bool
pathConditionModel PC.Infeasible = pure False
pathConditionModel (PC.FeasibleMaybe pci) = do
  -- We try choices first as they are more likely to fail (?)  
  choiceb <- andM [ (==) i <$> getPathVar pv
                  | (pv, i) <- Map.toList (PC.pcChoices pci) ]
  if choiceb
    then andM [ pcciModel x vgci
              | (x, vgci) <- Map.toList (PC.pcCases pci) ]
    else pure False
  where
    pcciModel :: SMTVar -> PathConditionCaseInfo -> ModelParserM Bool
    pcciModel x vgci =
      PC.pcciSatisfied vgci <$> getValueVar (Typed (PC.pcciType vgci) x)

gseModel :: GuardedSemiSExpr -> ModelParserM (Maybe I.Value)
gseModel gse =
  case gse of
    VValue v -> pure (Just v)
    VOther x -> Just <$> getValueVar x
    VUnionElem l gses -> fmap (I.VUnionElem l) <$> gsesModel gses
    VStruct flds -> do
      let (ls, gsess) = unzip flds
      m_gsess <- sequence <$> mapM gsesModel gsess
      pure (I.VStruct . zip ls <$> m_gsess)

    VSequence _ True gsess ->
      fmap (I.VBuilder . reverse) . sequence <$> mapM gsesModel gsess
    VSequence _ False gsess ->
      fmap (I.VArray . Vector.fromList) . sequence <$> mapM gsesModel gsess

    VJust gses -> fmap (I.VMaybe . Just) <$> gsesModel gses
    VMap els -> do
      let (ks, vs) = unzip els
      m_kvs <- sequence <$> mapM gsesModel ks
      m_vvs <- sequence <$> mapM gsesModel vs
      pure (I.VMap . Map.fromList <$> (zip <$> m_kvs <*> m_vvs))

  -- We support symbolic keys, so we can't use Map here
    VIterator els -> do
      let (ks, vs) = unzip els
      m_kvs <- sequence <$> mapM gsesModel ks
      m_vvs <- sequence <$> mapM gsesModel vs
      pure (I.VIterator <$> (zip <$> m_kvs <*> m_vvs))

gsesModel :: GuardedSemiSExprs -> ModelParserM (Maybe I.Value)
gsesModel gses = join <$> (traverse (gseModel . snd) =<< firstM go els)
  where
    go  = pathConditionModel . fst
    els = MV.guardedValues gses

-- -----------------------------------------------------------------------------
-- Loops

-- We deal with loops as follows:
-- 
--  1. We start by processing the model builder as per usual, just
--     recording which loop ids we see, along with their corresponding
--     SymbolicLoopModel/SMLPerValues (maybe filtered by which is enabled);
--  2. We thus have a set of loop tags which can then be grouped into
--     root/deps (this is only fully known when we have parsed everything);
--  3. The models for each tag are parsed, which may, in turn generate
--     new sets of tags (for the nested loops);
--  4. 

-- FIXME:
--   - Do we need the guard for the slmpervalue, as we know which the generator generates
--   - We have to be careful about the nestings of loops, e.g. 
--     def Main = block
--       xs = Many P1
--       ys = Many P2
--       zs = map (y in ys) block
--              z = P3
--              ws = map (x in xs) (P4 y z)
--

  















