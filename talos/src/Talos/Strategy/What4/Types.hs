{-# Language OverloadedStrings #-}
{-# Language GADTs #-}
{-# Language GeneralisedNewtypeDeriving #-}
{-# Language RankNTypes #-}
{-# Language PatternSynonyms #-}
{-# Language TypeOperators #-}
{-# Language DataKinds #-}
{-# Language TypeApplications #-}
{-# Language TypeFamilies #-}
{-# Language KindSignatures #-}
{-# Language ScopedTypeVariables #-}
{-# Language ViewPatterns #-}
{-# Language PolyKinds #-}
{-# Language UndecidableInstances #-}
{-# Language MultiParamTypeClasses #-}
{-# Language MultiParamTypeClasses #-}

module Talos.Strategy.What4.Types(
  -- BaseMaybe
    BaseMaybeType
  , BaseMaybe
  , pattern BaseMaybeRepr
  , getBaseMaybe
  , mkBaseMaybe
  -- BaseUnion
  , BaseUnionType
  , BaseUnion
  , BaseUnionRepr
  , pattern BaseUnionRepr
  , mkBaseUnion
  , getBaseUnion
  , muxBaseUnion
  , ArrayIndexType
  , ArrayIndex
  , ArrayLenType
  , ArrayLen
  , pattern ArrayLenRepr
  , pattern ArrayIndexRepr
  , singletonArrayLen
  , mkConcreteArrayLen
  , asConcreteArrayLen
  , arrayLenPrefix
  , concatArrays
  , arrayLenSize
  , concreteArrayIndex
  -- interpreting Daedalus types
  , typeToRepr
  , lookupTName
  , getFieldIndex
  , mkFlds
  , SymbolicVector
  , mkSymbolicVector
  , getSymbolicVector
  , groundSymbolicVector
  , SymbolicChoice
  , mkSymbolicChoice
  , getSymbolicChoice
  , groundSymbolicChoice
  , vectorToList
) where

import qualified Data.BitVector.Sized as BVS
import qualified Data.Map                        as Map

import           Data.Parameterized.NatRepr
import qualified Data.Parameterized.Context      as Ctx
import           Data.Parameterized.Some
import           Data.Parameterized.Fin
import qualified What4.Interface                 as W4
import qualified What4.Concrete                  as W4
import qualified What4.Expr.ArrayUpdateMap       as AUM

import           Daedalus.Core                   hiding (streamOffset)
import qualified Daedalus.Core.Basics              as I
import           Daedalus.Panic
import           Daedalus.PP
import           Talos.Strategy.Monad

import           Talos.Strategy.What4.SymM
import           Talos.Strategy.What4.Solver

import GHC.Num.Integer (integerLog2)
import Data.Functor.WithIndex (FunctorWithIndex(imap))
import Control.Monad.IO.Class
import Data.Parameterized.Vector (Vector)
import qualified Data.Parameterized.Vector as V
import Control.Monad.Trans.State
import Control.Monad.Trans
import Control.Monad.State.Class
import Control.Monad (foldM, forM)
import GHC.Base (Nat)

------------------------------------------------------------
-- Helper symbolic datatypes

-- | A container for 'n' values each with an associated predicate
data SymbolicVector sym (n :: Nat) a = 
  1 <= n => SymbolicVector (W4.SymExpr sym (W4.BaseBVType n))  (V.Vector n a)

instance Functor (SymbolicVector sym n) where
  fmap f (SymbolicVector e v) = SymbolicVector e (fmap f v)

mkSymbolicVector ::
  forall sym m k a.
  (Monad m, MonadIO m, 1 <= k) =>
  W4.IsSymExprBuilder sym =>
  sym ->
  NatRepr k ->
  (forall n. (n + 1 <= k) => W4.NatRepr n -> m (W4.Pred sym, a)) ->
  m (SymbolicVector sym k a)
mkSymbolicVector sym k f = do
  Refl <- return $ W4.minusPlusCancel k (knownNat @1)
  (v :: V.Vector k (W4.Pred sym, a)) <- V.generateM (W4.decNat k) $ \(n :: W4.NatRepr n) -> do
    let (n_leq_k :: W4.LeqProof n (k-1)) = W4.leqProof n (W4.decNat k)
    W4.LeqProof <- return $ W4.leqAdd2 n_leq_k (W4.leqRefl (knownNat @1))
    f n
  W4.LeqProof <- return $ W4.addPrefixIsLeq k (knownNat @1)
  let 
    acts :: [W4.SymExpr sym (W4.BaseBVType k) -> m (W4.SymExpr sym (W4.BaseBVType k))]
    acts = natForEach (knownNat @0) (W4.decNat k) $ \(n :: W4.NatRepr n) bv -> do
        let (n_leq_k :: W4.LeqProof n (k-1)) = W4.leqProof n (W4.decNat k)
        W4.LeqProof <- return $ W4.leqAdd2 n_leq_k (W4.leqProof (knownNat @1) (knownNat @1))
        let (p, _) = V.elemAt n v
        liftIO $ W4.bvSet sym bv (natValue n) p
  zero <- liftIO $ W4.bvLit sym k (BVS.mkBV k 0)
  bv <- foldM (\bv act -> act bv) zero acts 
  return $ SymbolicVector bv (fmap snd v)

vectorToList ::
  Vector n a -> (a,[a])
vectorToList v = let (v':vs) = V.toList v in (v',vs)

getSymbolicVector ::
  forall sym m n a.
  (Monad m, MonadIO m) =>
  W4.IsSymExprBuilder sym =>
  sym ->
  SymbolicVector sym n a ->
  m (Vector n (W4.Pred sym, a))
getSymbolicVector sym (SymbolicVector bv v) | W4.BaseBVRepr n <- W4.exprType bv = do
  Refl <- return $ W4.minusPlusCancel n (knownNat @1)
  V.generateM (W4.decNat n) $ \(k :: W4.NatRepr k) ->do
    let (k_leq_n :: W4.LeqProof k (n-1)) = W4.leqProof k (W4.decNat n)
    W4.LeqProof <- return $ W4.leqAdd2 k_leq_n (W4.leqRefl (knownNat @1))
    p <- liftIO $ W4.testBitBV sym (natValue k) bv
    let val = V.elemAt k v
    return $ (p, val)

groundSymbolicVector ::
  forall sym m n a.
  (Monad m, MonadIO m) =>
  W4.IsSymExprBuilder sym =>
  sym ->
  SymGroundEvalFn sym ->
  SymbolicVector sym n a ->
  m (Vector n (Maybe a))
groundSymbolicVector _sym fn (SymbolicVector bv v) = do
  bv_ground <- execGroundFn fn bv
  return $ imap (\nf a -> viewFin (\n ->
    case BVS.testBit n bv_ground of
      True -> Just a
      False -> Nothing) nf
    ) v

newtype SymbolicChoice sym (n :: Nat) a = SymbolicChoice (SymbolicVector sym n a)
  deriving Functor

mkSymbolicChoice ::
  forall sym m k a.
  (Monad m, MonadIO m) =>
  W4.IsSymExprBuilder sym =>
  sym ->
  W4.SymExpr sym (W4.BaseBVType k) {- interpreted as an integer that selects the value. Wraps around. -} ->
  (forall n. (n + 1 <= k) => W4.NatRepr n -> m a) ->
  m (SymbolicChoice sym k a)
mkSymbolicChoice sym bv_shift f | W4.BaseBVRepr k <- W4.exprType bv_shift = do
  Refl <- return $ W4.minusPlusCancel k (knownNat @1)
  (v :: V.Vector k a) <- V.generateM (W4.decNat k) $ \(n :: W4.NatRepr n) -> do
    let (n_leq_k :: W4.LeqProof n (k-1)) = W4.leqProof n (W4.decNat k)
    W4.LeqProof <- return $ W4.leqAdd2 n_leq_k (W4.leqRefl (knownNat @1))
    f n
  W4.LeqProof <- return $ W4.addPrefixIsLeq k (knownNat @1)
  one <- liftIO $ W4.bvLit sym k (BVS.mkBV k 1)
  -- we use rotate to wrap around if the given number is too large, so we
  -- necessarily always have one selection
  bv <- liftIO $ W4.bvRol sym one bv_shift
  return $ SymbolicChoice $ SymbolicVector bv v

-- | Returns the value at 'k' along with a predicate that is true if 'k' is the choice
getSymbolicChoice ::
  forall sym m k a.
  (Monad m, MonadIO m) =>
  W4.IsSymExprBuilder sym =>
  sym ->
  (W4.Pred sym -> a -> a -> m a) ->
  SymbolicChoice sym k a ->
  m a
getSymbolicChoice sym mux (SymbolicChoice sv) = do
  ((_, firstChoice),choices) <- vectorToList <$> getSymbolicVector sym sv
  foldM (\b' (p, a) -> mux p a b') firstChoice choices

-- | Returns the single result that is chosen in the given model
groundSymbolicChoice ::
  forall sym m n a.
  (Monad m, MonadIO m) =>
  W4.IsSymExprBuilder sym =>
  sym ->
  SymGroundEvalFn sym ->
  SymbolicChoice sym n a ->
  m a
groundSymbolicChoice _sym fn (SymbolicChoice (SymbolicVector bv v)) | W4.BaseBVRepr n <- W4.exprType bv = do
  bv_ground <- execGroundFn fn bv
  -- the invariant of SymbolicChoice is that exactly one bit is set in the
  -- bitvector, so this should return a non-zero index into the vector
  let index = integerLog2 (BVS.asUnsigned bv_ground)
  case W4.someNat index of
    Just (Some k) | Just W4.LeqProof <- W4.testLeq (W4.incNat k) n -> do
      return $ V.elemAt k v
    _ -> liftIO $ fail $ "groundSymbolicChoice: impossible result:" ++ show index

------------------------------------------------------------
-- Daedalus types encoded as What4 types

-- Maybe type

type BaseMaybeType tp = W4.BaseStructType (Ctx.EmptyCtx Ctx.::> W4.BaseBoolType Ctx.::> tp)
type BaseMaybe sym tp = W4.SymExpr sym (BaseMaybeType tp)

getBaseMaybe :: 
  W4.IsSymExprBuilder sym =>
  sym -> 
  BaseMaybe sym tp -> 
  IO (W4.SymExpr sym tp, W4.Pred sym)
getBaseMaybe sym e = do
  p <- W4.structField sym e Ctx.i2of2
  e' <- W4.structField sym e Ctx.i1of2
  return (p, e')

mkBaseMaybe ::
  W4.IsSymExprBuilder sym =>
  sym ->
  W4.SymExpr sym tp ->
  W4.Pred sym ->
  IO (W4.SymExpr sym (BaseMaybeType tp))  
mkBaseMaybe sym e p = W4.mkStruct sym (Ctx.Empty Ctx.:> p Ctx.:> e)

pattern BaseMaybeRepr :: () => (tp_outer ~ BaseMaybeType tp_inner) => W4.BaseTypeRepr tp_inner -> W4.BaseTypeRepr tp_outer
pattern BaseMaybeRepr x = W4.BaseStructRepr (Ctx.Empty Ctx.:> W4.BaseBoolRepr Ctx.:> x)


-- Struct index type

-- Index into an n-field struct represented as an n-width bitvector with exactly
-- one bit set

-- For completeness, we use a type family where an index into an empty struct is just
-- an empty struct. This just avoids the need for carrying around non-empty assumptions.
type family StructIdxType (ctx :: Ctx.Ctx W4.BaseType) :: W4.BaseType
type instance StructIdxType (ctx Ctx.::> _) = W4.BaseBVType (1 + Ctx.CtxSize ctx)
type instance StructIdxType Ctx.EmptyCtx = W4.BaseStructType Ctx.EmptyCtx

type StructIdx sym (ctx :: Ctx.Ctx W4.BaseType) = W4.SymExpr sym (StructIdxType ctx)
type StructIdxRepr ctx = W4.BaseTypeRepr (StructIdxType ctx)


-- inverting a struct repr back into a context size
data StructIdxReprProof (tp :: W4.BaseType) where
  StructIdxReprProof :: Ctx.Size tps -> StructIdxReprProof (StructIdxType tps)

-- FIXME: add unsafe variant?
asStructIdxReprProof :: forall tp. W4.BaseTypeRepr tp -> Maybe (StructIdxReprProof tp)
asStructIdxReprProof repr = case repr of
  W4.BaseStructRepr Ctx.Empty -> Just (StructIdxReprProof Ctx.zeroSize)
  W4.BaseBVRepr w -> case testEquality w (knownNat @1) of
    Just Refl -> Just (StructIdxReprProof (Ctx.incSize Ctx.zeroSize))
    Nothing | w' <- W4.decNat w, Just LeqProof <- W4.isPosNat w',
      Just (StructIdxReprProof sz) <- asStructIdxReprProof (W4.BaseBVRepr w'),
      Just Refl <- testEquality (Ctx.sizeToNatRepr sz) w',
      Refl <- W4.plusComm w' (knownNat @1),
      Refl <- W4.minusPlusCancel w (knownNat @1) ->
      Just (StructIdxReprProof (Ctx.incSize sz))
    Nothing -> Nothing
  _ -> Nothing

lenPos :: Ctx.Size (tps Ctx.::> tp) -> LeqProof 1 (Ctx.CtxSize (tps Ctx.::> tp))
lenPos sz = case Ctx.viewSize sz of
  Ctx.IncSize sz' | sz'_n <- Ctx.sizeToNatRepr sz'
    , W4.LeqProof <- W4.addPrefixIsLeq sz'_n (knownNat @1) 
    , Refl <- W4.plusComm sz'_n (knownNat @1) 
    -> LeqProof

structIdxRepr :: Ctx.Size tps -> StructIdxRepr tps
structIdxRepr sz = case Ctx.viewSize sz of
  Ctx.ZeroSize -> W4.BaseStructRepr Ctx.Empty
  Ctx.IncSize{} | W4.LeqProof <- lenPos sz -> W4.BaseBVRepr (Ctx.sizeToNatRepr sz)

pattern StructIdxRepr :: () => (tp_outer ~ StructIdxType tps) => Ctx.Size tps -> W4.BaseTypeRepr tp_outer
pattern StructIdxRepr sz <- ((\x -> asStructIdxReprProof x) -> Just (StructIdxReprProof sz)) where
  StructIdxRepr sz = structIdxRepr sz

mkStructIdx ::
  W4.IsSymExprBuilder sym =>
  sym ->
  Ctx.Size tps ->
  Ctx.Index tps tp ->
  IO (StructIdx sym tps)
mkStructIdx sym sz idx =
  case Ctx.viewSize sz of
  Ctx.IncSize _ -> do
    W4.LeqProof <- return $ lenPos sz
    let w = (Ctx.sizeToNatRepr sz)
    zero <- W4.bvLit sym w (BVS.mkBV w 0)
    W4.bvSet sym zero (fromIntegral (Ctx.indexVal idx)) (W4.truePred sym)
  Ctx.ZeroSize -> fail "Impossible (found index into zero-width context)"

-- Unions

-- A struct with an additional field indicating which value the union represents
type BaseUnionType tps = W4.BaseStructType (tps Ctx.::> StructIdxType tps)
type BaseUnion sym tps = W4.SymExpr sym (BaseUnionType tps)
type BaseUnionRepr tps = W4.BaseTypeRepr (BaseUnionType tps)

data BaseUnionReprProof (tp :: W4.BaseType) where
  BaseUnionReprProof :: 
    Ctx.Assignment W4.BaseTypeRepr tps -> 
    BaseUnionReprProof (BaseUnionType tps)


data SameStructIdxType tps1 tps2 where
  SameStructIdxType :: 
    Ctx.Size tps1 -> 
    Ctx.Size tps2 -> 
    Ctx.CtxSize tps1 :~: Ctx.CtxSize tps2 ->
    StructIdxType tps1 :~: StructIdxType tps2 -> 
    SameStructIdxType tps1 tps2

-- FIXME: add safe/unsafe variants?
sameStructIdxType :: Ctx.Size ctx1 -> Ctx.Size ctx2 -> Maybe (SameStructIdxType ctx1 ctx2)
sameStructIdxType sz1 sz2 = case (Ctx.viewSize sz1, Ctx.viewSize sz2) of
  (Ctx.ZeroSize, Ctx.ZeroSize) -> return $ SameStructIdxType sz1 sz2 Refl Refl
  (Ctx.IncSize sz1_, Ctx.IncSize sz2_) -> do
    SameStructIdxType _ _ Refl Refl <- sameStructIdxType sz1_ sz2_
    return $ SameStructIdxType sz1 sz2 Refl Refl
  _ -> Nothing

data IsStructIdxPrfFor tps tp where
  IsStructIdxPrfFor :: Ctx.Size tps -> IsStructIdxPrfFor tps (StructIdxType tps)

isValidIdxRepr :: Ctx.Size ctx -> W4.BaseTypeRepr tp -> Maybe (IsStructIdxPrfFor ctx tp)
isValidIdxRepr sz repr = case repr of
  StructIdxRepr sz' -> do
    SameStructIdxType _ _ Refl Refl <- sameStructIdxType sz sz'
    return $ IsStructIdxPrfFor sz
  _ -> Nothing

asBaseUnion :: W4.BaseTypeRepr tp -> Maybe (BaseUnionReprProof tp)
asBaseUnion (W4.BaseStructRepr (vs Ctx.:> idxRepr)) = do
  IsStructIdxPrfFor _ <- isValidIdxRepr (Ctx.size vs) idxRepr
  return $ BaseUnionReprProof vs
asBaseUnion _ = Nothing

baseUnionRepr :: Ctx.Assignment W4.BaseTypeRepr tps -> BaseUnionRepr tps
baseUnionRepr ctx = W4.BaseStructRepr (ctx Ctx.:> structIdxRepr (Ctx.size ctx))

pattern BaseUnionRepr :: () => (tp_outer ~ BaseUnionType tps) => Ctx.Assignment W4.BaseTypeRepr tps -> W4.BaseTypeRepr tp_outer
pattern BaseUnionRepr tps <- ((\x -> asBaseUnion x) -> Just (BaseUnionReprProof tps)) where
  BaseUnionRepr tps = baseUnionRepr tps

mkBaseUnion ::
  W4.IsSymExprBuilder sym =>
  sym ->
  Ctx.Assignment W4.BaseTypeRepr tps ->
  W4.SymExpr sym tp ->
  Ctx.Index tps tp ->
  IO (BaseUnion sym tps)
mkBaseUnion sym reprs v idx = do
  structIdx <- mkStructIdx sym (Ctx.size reprs) idx
  vls <- Ctx.traverseWithIndex (\idx_ repr -> case testEquality idx idx_ of
    Just Refl -> return v
    -- other values don't matter here
    Nothing -> W4.baseDefaultValue sym repr) reprs
  W4.mkStruct sym (vls Ctx.:> structIdx)

getBaseUnion ::
  forall tps tp sym.
  W4.IsSymExprBuilder sym =>
  sym ->
  BaseUnion sym tps ->
  Ctx.Index tps tp ->
  IO (W4.SymExpr sym tp, W4.Pred sym)
getBaseUnion sym e idx = do
  W4.BaseStructRepr repr <- return $ W4.exprType e
  e' <- W4.structField sym e (Ctx.skipIndex idx)
  structIdx <- W4.structField sym e (Ctx.lastIndex (Ctx.size repr))
  p <- case W4.exprType structIdx of
    W4.BaseBVRepr{} -> do
      W4.testBitBV sym (fromIntegral (Ctx.indexVal idx)) structIdx
    _ -> return $ W4.falsePred sym
  return (e', p)

muxBaseUnion ::
  forall tps sym.
  W4.IsSymExprBuilder sym =>
  sym ->
  W4.Pred sym ->
  BaseUnion sym tps ->
  BaseUnion sym tps ->
  IO (BaseUnion sym tps)
muxBaseUnion sym p uT uF = do
  BaseUnionRepr reprs <- return $ W4.exprType uT
  -- zip the values together, but we only need to mux
  -- entries which are present in both unions
  vls <- Ctx.traverseWithIndex (\idx _repr -> do
        (vT, pT) <- getBaseUnion sym uT idx
        (vF, pF) <- getBaseUnion sym uF idx
        case (W4.asConstantPred pT, W4.asConstantPred pF) of
          (Just True, Just False) -> return vT
          (Just False, Just True) -> return vF
          _ -> W4.baseTypeIte sym p vT vF)
         reprs
  let lastIdx = Ctx.lastIndex (Ctx.incSize (Ctx.size reprs))
  -- the union index itself is the actual mux
  structIdxT <- W4.structField sym uT lastIdx
  structIdxF <- W4.structField sym uF lastIdx
  structIdx <- W4.baseTypeIte sym p structIdxT structIdxF
  W4.mkStruct sym (vls Ctx.:> structIdx)


-- Array type

-- an integer-indexed array combined with a known length
type ArrayIndexType = W4.BaseBVType 64
type ArrayIndex sym = W4.SymExpr sym ArrayIndexType

type ArrayLenType tp = W4.BaseStructType (Ctx.EmptyCtx Ctx.::> (W4.BaseArrayType (Ctx.EmptyCtx Ctx.::> ArrayIndexType) tp) Ctx.::> ArrayIndexType)
type ArrayLen sym tp = W4.SymExpr sym (ArrayLenType tp)

singletonArrayLen ::
  W4.IsSymExprBuilder sym =>
  sym ->
  W4.SymExpr sym tp ->
  IO (ArrayLen sym tp)
singletonArrayLen sym e = mkConcreteArrayLen sym (W4.exprType e) [e]


mkConcreteArrayLen ::
  W4.IsSymExprBuilder sym =>
  sym ->
  W4.BaseTypeRepr tp ->
  [W4.SymExpr sym tp] ->
  IO (ArrayLen sym tp)
mkConcreteArrayLen sym repr vals = do
  let idxrepr = Ctx.singleton ArrayIndexRepr
  let mkidx i = Ctx.singleton (W4.BVIndexLit (knownNat @64) (BVS.mkBV (knownNat @64) i))
  let aum = AUM.fromAscList repr (map (\(i,v) -> (mkidx i, v)) (zip [0..] vals))
  empty_e <- W4.freshConstant sym W4.emptySymbol repr
  arr <- liftIO $ W4.arrayFromMap sym idxrepr aum empty_e
  len_bv <- W4.bvLit sym (knownNat @64) $ BVS.mkBV (knownNat @64) (fromIntegral (length vals))
  liftIO $ W4.mkStruct sym (Ctx.empty Ctx.:> arr Ctx.:> len_bv)

arrayLenPrefix ::
  W4.IsSymExprBuilder sym =>
  sym ->
  Integer ->
  ArrayLen sym tp ->
  IO ([W4.SymExpr sym tp])
arrayLenPrefix sym n arr = do
  arr' <- W4.structField sym arr Ctx.i1of2
  forM [0..n] $ \i -> do
    i_bv <- W4.bvLit sym (knownNat @64) $ BVS.mkBV (knownNat @64) i
    W4.arrayLookup sym arr' (Ctx.singleton i_bv)  

asConcreteArrayLen ::
  W4.IsSymExprBuilder sym =>
  sym ->
  ArrayLen sym tp ->
  IO (Maybe ([W4.SymExpr sym tp]))
asConcreteArrayLen sym arr = do
  sz <- arrayLenSize sym arr
  case concreteArrayIndex sym sz of
    Just n -> Just <$> arrayLenPrefix sym n arr 
    Nothing -> return Nothing

arrayLenSize ::
  W4.IsSymExprBuilder sym =>
  sym ->
  ArrayLen sym tp ->
  IO (ArrayIndex sym)
arrayLenSize sym arr = W4.structField sym arr Ctx.i2of2

concreteArrayIndex ::
  W4.IsSymExprBuilder sym =>
  sym ->
  ArrayIndex sym ->
  Maybe Integer
concreteArrayIndex _sym idx = case W4.asConcrete idx of
  Just (W4.ConcreteBV _ bv) -> Just (BVS.asUnsigned bv)
  _ -> Nothing


concatArrays ::
  W4.IsSymExprBuilder sym =>
  sym ->
  ArrayLen sym tp ->
  ArrayLen sym tp ->
  IO (ArrayLen sym tp)
concatArrays sym arrL arrR = do
  arrL' <- W4.structField sym arrL Ctx.i1of2
  arrL_len <- W4.structField sym arrL Ctx.i2of2
  arrR' <- W4.structField sym arrR Ctx.i1of2
  arrR_len <- W4.structField sym arrR Ctx.i2of2
  zero <- W4.bvLit sym knownNat (BVS.mkBV knownNat 0)
  arr_result <- W4.arrayCopy sym arrL' arrL_len arrR' zero arrR_len
  len_result <- W4.bvAdd sym arrL_len arrR_len
  W4.mkStruct sym (Ctx.empty Ctx.:> arr_result Ctx.:> len_result)

pattern ArrayIndexRepr :: forall tp_outer. () => (tp_outer ~ ArrayIndexType) => W4.BaseTypeRepr tp_outer
pattern ArrayIndexRepr <- 
  (((\x -> case x of { W4.BaseBVRepr w | Just Refl <- W4.testEquality w (knownNat @64) -> Just Refl; _ -> Nothing })) -> 
    Just (Refl :: tp_outer :~: ArrayIndexType)) where
  ArrayIndexRepr = W4.BaseBVRepr (knownNat @64)

pattern ArrayLenRepr :: () => (tp_outer ~ ArrayLenType tp_inner) => W4.BaseTypeRepr tp_inner -> W4.BaseTypeRepr tp_outer
pattern ArrayLenRepr x = W4.BaseStructRepr (Ctx.Empty Ctx.:> (W4.BaseArrayRepr (Ctx.Empty Ctx.:> ArrayIndexRepr) x) Ctx.:> ArrayIndexRepr)


-- Resolving types

sizeToRepr :: I.SizeType -> Maybe (Some (W4.NatRepr))
sizeToRepr (I.TSize n) = W4.someNat n
sizeToRepr (I.TSizeParam{}) = Nothing

typeToRepr ::
  forall sym m.
  I.Type -> 
  W4SolverT sym m (Some (W4.BaseTypeRepr))
typeToRepr v = go v
  where
    go :: I.Type -> W4SolverT sym m (Some (W4.BaseTypeRepr))
    go (I.TUInt n) = do
      Some nr <- liftMaybe $ sizeToRepr n
      W4.LeqProof <- liftMaybe $ W4.isPosNat nr
      return $ Some (W4.BaseBVRepr nr)
    go (I.TSInt n) = do
      Some nr <- liftMaybe $ sizeToRepr n
      W4.LeqProof <- liftMaybe $ W4.isPosNat nr
      return $ Some (W4.BaseBVRepr nr)
    go (TInteger) = return (Some W4.BaseIntegerRepr)
    go (TBool) = return (Some W4.BaseBoolRepr)
    go TUnit = return (Some (W4.BaseStructRepr Ctx.Empty))
    go (TMaybe t) = do
      Some repr <- go t
      return $ (Some (W4.BaseStructRepr (Ctx.Empty Ctx.:> W4.BaseBoolRepr Ctx.:> repr)))
    go (TMap tkey tvalue) = do
      Some rkey <- go tkey
      Some rvalue <- go tvalue
      return $ (Some (W4.BaseArrayRepr (Ctx.Empty Ctx.:> rkey) rvalue))
    go (TArray tvalue) = do
      Some rvalue <- go tvalue
      return $ (Some (ArrayLenRepr rvalue))
    go (TUser ut) | [] <- utTyArgs ut, [] <- utNumArgs ut = do
      lookupTName (utName ut)
    go t = panic "typeToRepr: unsupported type" [showPP v, showPP t]

mkFlds :: [(Label, Type)] -> W4SolverT sym m (Some (Ctx.Assignment W4.BaseTypeRepr))
mkFlds lbls = Ctx.fromList <$> mapM (\(_,t) -> typeToRepr t) lbls

lookupTName :: TName -> W4SolverT sym m (Some (W4.BaseTypeRepr))
lookupTName nm = do
  tdefs <- getTypeDefs
  case Map.lookup nm tdefs of
    Just tdecl -> case tDef tdecl of
      TUnion flds -> do
        Some reprs <- mkFlds flds
        return $ Some (baseUnionRepr reprs)
      _ -> panic "lookupTName: unsupported type" [showPP nm]
    _ -> panic "lookupTName: missing type" [showPP nm]
  
getFieldIndex ::
  [(Label, Type)] -> 
  Ctx.Size tps ->
  Label -> 
  W4SolverT sym m (Some (Ctx.Index tps), Type)
getFieldIndex ((lbl,t):lbls) sz lblCheck = case Ctx.viewSize sz of
  Ctx.IncSize sz' -> case lbl == lblCheck of
    True -> return $ (Some (Ctx.lastIndex sz), t)
    False -> do
      (Some idx, t') <- getFieldIndex lbls sz' lblCheck
      return (Some (Ctx.skipIndex idx), t')
  Ctx.ZeroSize -> panic "getFieldIndex" ["Missing field:", showPP lblCheck]
getFieldIndex [] _ lblCheck = panic "getFieldIndex" ["Missing field:", showPP lblCheck]