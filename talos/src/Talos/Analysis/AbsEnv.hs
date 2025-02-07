{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DefaultSignatures #-}

module Talos.Analysis.AbsEnv where

import           Data.Map              (Map)
import qualified Data.Map              as Map
import           Data.Proxy            (Proxy)

import           Daedalus.Core         (ByteSet, Expr, Name, Type)
import           Daedalus.PP
import           Daedalus.Panic        (panic)

import           Talos.Analysis.Eqv
import           Talos.Analysis.Merge  (HasEmpty (..), Merge (..))
import           Talos.Analysis.SLExpr (SLExpr)
import           Talos.Analysis.Slice  (Structural (..))

--------------------------------------------------------------------------------
-- Abstract Environments

-- We use Merge over SemiGroup as we only merge at a given type (i.e.,
-- merge is undefined if called at different types)
class (Ord p, PP p, Merge p) => AbsEnvPred p where
  absPredTop :: p -- absPredTop `merge` p == absPredTop
  absPredOverlaps :: p -> p -> Bool
  absPredEntails  :: p -> p -> Bool

  -- | Does this predicate depend on the structure of the computation?
  -- Mainly useful for sequences where the predicate may be invariant
  -- in the length and arrangement of elements
  absPredStructural :: p -> Structural

  -- | Get an element predicate, given a predicate of list type
  absPredListElement :: p -> Maybe p
  absPredCollection :: Type -> Structural -> Maybe p -> Maybe p -> Maybe p
  
class (AbsEnvPred (AbsPred ae), Eqv ae, PP ae, Merge ae) => AbsEnv ae where
  type AbsPred ae
  -- (\forall x. absProj x ae = Nothing) --> absNullEnv ae
  absNullEnv     :: ae -> Bool
  absEmptyEnv    :: ae
  absPre         :: AbsPred ae -> Expr -> (ae, SLExpr)
  
  -- This is used to refine the branches of case statements. The
  -- result is the abstract environment for the new case node.
  -- absCase        :: Case ae -> ae
  
  absByteSet     :: AbsPred ae -> ByteSet -> ae
  absProj        :: Name -> ae -> Maybe (ae, AbsPred ae)
  absInverse     :: Name -> Expr -> Expr -> ae
  absEnvOverlaps :: ae -> ae -> Bool
  absSubstEnv    :: Map Name Name -> ae -> ae
  -- | Returns all (if any) variables which contain list predicates
  -- which are not structure-dependent.  Used to avoid annoying cases
  -- with pooling (the "exists-forall" problem)
  absNonStructural :: ae -> [Name]
  
data AbsEnvTy = forall ae. AbsEnv ae => AbsEnvTy (Proxy ae) 

-- Just treat the elements pointwise
newtype LiftAbsEnv p = LiftAbsEnv { getLiftAbsEnv :: Map Name p }
  deriving (Functor)

-- -----------------------------------------------------------------------------
-- Helpers

mapLiftAbsEnv :: (Map Name p -> Map Name p) -> (LiftAbsEnv p -> LiftAbsEnv p)
mapLiftAbsEnv f (LiftAbsEnv m) = LiftAbsEnv (f m)

-- | Do two maps overlap, wrt. the definition of overlap from `AbsEnvPred`
mapPredOverlaps :: (Ord k, AbsEnvPred p) => Map k p -> Map k p -> Bool
mapPredOverlaps m1 m2 = 
  any (uncurry absPredOverlaps) (Map.intersectionWith (,) m1 m2)
  
-- -----------------------------------------------------------------------------
-- Instances

instance Eqv p => Eqv (LiftAbsEnv p) where
  eqv (LiftAbsEnv m1) (LiftAbsEnv m2) = eqv m1 m2

-- This is a convenience class so we can just define things at the
-- predicate level and lift them to maps.
class (Eqv p, AbsEnvPred p, PP p, Merge p) => AbsEnvPointwise p where
  absPredPre     :: p -> Expr -> (LiftAbsEnv p, SLExpr)
  absPredByteSet :: p -> ByteSet -> LiftAbsEnv p
  absPredInverse :: Name -> Expr -> Expr -> LiftAbsEnv p
  absPredNonStructural :: p -> Bool

instance AbsEnvPointwise p => AbsEnv (LiftAbsEnv p) where
  type AbsPred (LiftAbsEnv p) = p
  absNullEnv     = Map.null . getLiftAbsEnv
  absEmptyEnv    = LiftAbsEnv Map.empty 
  absPre p e     = absPredPre p e
  
  -- absCase (Case _x [])     = panic "Empty case" []
  -- -- FIXME: this overapproximates by assuming we want all of x
  -- absCase c@(Case x _alts) =
  --   mapLiftAbsEnv (Map.insert x absPredTop) (foldl1 merge c)
    
  absByteSet p e = absPredByteSet p e
  absProj n (LiftAbsEnv m) =
    let (m_r, m') = Map.updateLookupWithKey (\_ _ -> Nothing) n m
    in (,) (LiftAbsEnv m') <$> m_r
  absInverse n e e' = absPredInverse n e e'
  absEnvOverlaps (LiftAbsEnv m1) (LiftAbsEnv m2) =
    mapPredOverlaps m1 m2
  absSubstEnv subst = mapLiftAbsEnv (Map.mapKeysWith merge keyf)
    where
      keyf k | Just k' <- Map.lookup k subst = k'
             | otherwise = panic "Missing key" [showPP k]
  
  absNonStructural (LiftAbsEnv m) =
    [ k | (k, v) <- Map.toList m, absPredNonStructural v ]
    
instance PP p => PP (LiftAbsEnv p) where
  pp (LiftAbsEnv m) = brackets (commaSep (map go (Map.toList m)))
    where
      go (k, v) = pp k <+> "=>" <+> pp v

instance Merge p => Merge (LiftAbsEnv p) where
  LiftAbsEnv m `merge` LiftAbsEnv m' = LiftAbsEnv $ merge m m'

instance Merge p => Semigroup (LiftAbsEnv p) where
  (<>) = merge

-- Useful, although a bit abstraction brekaing.
instance Merge p => Monoid (LiftAbsEnv p) where
  mempty = LiftAbsEnv Map.empty

instance HasEmpty (LiftAbsEnv p) where
  empty = LiftAbsEnv Map.empty
