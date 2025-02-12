{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
{-# LANGUAGE TypeFamilies, FlexibleContexts, StandaloneDeriving, UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}

-- This module contains the datastructure representing future path
-- constraints for a variable.  A path may be thought of as an
-- abstraction of the input DDL program.

module Talos.Analysis.Domain where


import           Control.DeepSeq                 (NFData)
import           Data.Either                     (partitionEithers)
import           Data.Function                   (on)
import           Data.List                       (foldl1', partition)
import           Data.Map                        (Map)
import qualified Data.Map                        as Map
import qualified Data.Set                        as Set
import           GHC.Generics                    (Generic)

import           Daedalus.Core                   (FName, Name)
import           Daedalus.Core.Free              (FreeVars (..))
import           Daedalus.Core.TraverseUserTypes
import           Daedalus.PP
import           Daedalus.Panic

import           Talos.Analysis.AbsEnv
import           Talos.Analysis.Eqv
import           Talos.Analysis.Merge
import           Talos.Analysis.SLExpr           (SLExpr)
import           Talos.Analysis.Slice
import Data.Maybe (isNothing)

--------------------------------------------------------------------------------
-- Domains

data GuardedSlice ae = GuardedSlice
  { gsEnv   :: ae
  , gsPred  :: Maybe (AbsPred ae)
  -- ^ The predicate(s) used to generate the result in this slice.  If
  -- non-empty, this slice returns a value (i.e., the last grammar
  -- isn't a hole or a non-result call)
  , gsSlice :: Slice
  }
  deriving (Generic)

instance AbsEnv ae => Merge (GuardedSlice ae) where
  merge gs gs' = GuardedSlice
    { gsEnv  = gsEnv gs `merge` gsEnv gs'
    , gsPred = gsPred gs `merge` gsPred gs'
    , gsSlice = merge (gsSlice gs) (gsSlice gs')
    }

instance AbsEnv ae => Eqv (GuardedSlice ae) where
  eqv gs gs' =
    eqv (gsEnv gs) (gsEnv gs') &&
    gsPred gs == gsPred gs' && -- FIXME, we have (==) over preds
    eqv (gsSlice gs) (gsSlice gs')

mapGuardedSlice :: (Slice -> Slice) ->
                   GuardedSlice ae -> GuardedSlice ae
mapGuardedSlice f gs = gs { gsSlice = f (gsSlice gs) }

bindGuardedSlice :: AbsEnv ae => Name ->
                    GuardedSlice ae -> GuardedSlice ae -> GuardedSlice ae
bindGuardedSlice x lhs rhs = GuardedSlice
  { gsEnv = gsEnv lhs `merge` gsEnv rhs
  , gsPred = gsPred rhs
  , gsSlice = SDo x (gsSlice lhs) (gsSlice rhs)
  }

-- A guarded slice is closed if it is not a result slice, and it has
-- no free variables.  We use absNullEnv as a proxy for empty free vars.
closedGuardedSlice :: AbsEnv ae => GuardedSlice ae -> Bool
closedGuardedSlice gs = isNothing (gsPred gs) && absNullEnv (gsEnv gs)

deriving instance (NFData (AbsPred ae), NFData ae) => NFData (GuardedSlice ae)

data Domain ae = Domain
  { elements      :: [ GuardedSlice ae ]
  -- ^ In-progress (open, containing free vars) elements
  , closedElements :: Map Name [Slice]
  -- ^ Finalised (closed, no free vars, internal) elements.  We may
  -- have multiple starting from a single var, e.g.
  --
  --    x = ParseTuple ...
  --    Guard (x.fst > 0)
  --    Guard (x.snd > 42)
  --    ... (x not free) ...
  --
  -- might yield [ SDo x (ParseTuple | fst) (SAssertion (x.fst > 0))
  --             , SDo x (ParseTuple | snd) (SDo _ SHole (SAssertion (x.snd > 0)))]
  -- for x
  }
  deriving (Generic)

deriving instance (NFData (AbsPred ae), NFData ae) => NFData (Domain ae)

instance AbsEnv ae => Merge (Domain ae) where
  merge dL dR = Domain
    { elements       = mergeOverlapping overlaps (elements dL) (elements dR)
    , closedElements = Map.unionWith (<>) (closedElements dL) (closedElements dR)
    }
    where
      overlaps = absEnvOverlaps `on` gsEnv

-- FIXME: does this satisfy the laws?  Maybe for a sufficiently
-- general notion of equality?
-- instance Semigroup Domain where
--   (<>) = merge

emptyDomain :: Domain ae
emptyDomain = Domain
  { elements = []
  , closedElements = Map.empty
  }

singletonDomain :: AbsEnv ae => GuardedSlice ae -> Domain ae
singletonDomain gs
  -- If the element is not a result element (i.e., has no preds
  -- associated with it) and has a null env (i.e., no free vars) it is
  -- closed, otherwise it gets put in elements.
  --
  -- A non-result element with a null environment must start with SDo
  | closedGuardedSlice gs, SDo x _ _ <- gsSlice gs = mkSingleton x

  -- We ensure that any other binding site (e.g. in loops) that may be
  -- the root of a slice binds a variable, so that variable will then
  -- be the root.
  | closedGuardedSlice gs = panic "Expecting a slice headed by a SDo" [showPP gs]
  | otherwise = Domain { elements = [gs], closedElements = Map.empty }
  where
    mkSingleton x =
      Domain { elements = [], closedElements = Map.singleton x [gsSlice gs] }

-- | Constructs a domain from the possibly-overlapping elements.
domainFromElements :: AbsEnv ae => [GuardedSlice ae] -> Domain ae
domainFromElements = foldl merge emptyDomain . map singletonDomain

nullDomain :: Domain ae -> Bool
nullDomain (Domain [] ce) = Map.null ce
nullDomain _              = False

closedDomain :: Domain ae -> Bool
closedDomain (Domain [] _) = True
closedDomain _             = False

squashDomain :: AbsEnv ae => Domain ae -> Domain ae
squashDomain d@(Domain { elements = []}) = d
squashDomain d = d { elements = [ foldl1' merge (elements d) ] }

-- This is maybe too strict, as we require that the order of elements is the same.
domainEqv :: AbsEnv ae => Domain ae -> Domain ae -> Bool
domainEqv dL dR =
  elements dL `eqv` elements dR &&
  eqv (closedElements dL) (closedElements dR)

--------------------------------------------------------------------------------
-- Helpers

-- | Removes `x` the given slice, returning `Right` if `x` isn't
-- constrained, `Left` otherwise.
partitionSliceForVar :: AbsEnv ae => Name -> GuardedSlice ae ->
                        Either (GuardedSlice ae, AbsPred ae) (GuardedSlice ae)
partitionSliceForVar x gs =
  case absProj x (gsEnv gs) of
    Nothing      -> Right gs
    Just (e, p)  -> Left (gs { gsEnv = e }, p)

-- | Removes `x` from the domain, returning any slices mentioning x
-- and the domain less those slices
partitionDomainForVar :: AbsEnv ae => Name ->
                         Domain ae ->
                         ( [ (GuardedSlice ae, AbsPred ae) ], Domain ae )
partitionDomainForVar x d = ( matching, d' )
  where
    (matching, nonMatching) = partitionEithers (map (partitionSliceForVar x) (elements d))
    d' = d { elements = nonMatching }

partitionDomainForResult :: AbsEnv ae =>
                            (AbsPred ae -> Bool) ->
                            Domain ae ->
                            ( [ GuardedSlice ae ], Domain ae )
partitionDomainForResult f d = ( matching, d' )
  where
    (matching, nonMatching) = partition (maybe False f . gsPred) (elements d)
    d' = d { elements = nonMatching }

-- Maps over non-closed slices
mapSlices :: (Slice -> Slice) -> Domain ae -> Domain ae
mapSlices f d = d { elements = map (mapGuardedSlice f) (elements d) }

domainElements :: Domain ae -> ([GuardedSlice ae], Domain ae)
domainElements d = (elements d, d { elements = [] })

--------------------------------------------------------------------------------
-- Debugging etc.

--------------------------------------------------------------------------------
-- Internal slices (used during analysis)

data CallNode =
  CallNode { callClass        :: FInstId
           , callName         :: FName
           -- ^ The called function
           , callSlices      :: Map Int [Maybe Name]
           -- ^ The slices that we use --- if the args are disjoint
           -- this will be a singleton map for this slice, but we
           -- might need to merge, hence we have multiple.  The map
           -- just allows us to merge easily.
           --           , callArgs        :: [Name]
           }
  deriving (Generic, NFData)

instance Eqv CallNode where
  eqv CallNode { callClass = cl1, callSlices = paths1 }
      CallNode { callClass = cl2, callSlices = paths2 } =
    -- trace ("Eqv " ++ showPP cn ++ " and " ++ showPP cn') $
    cl1 `eqv` cl2 && paths1 == paths2

instance Merge CallNode where
  merge cn@CallNode { callClass = cl1, callSlices = sls1}
           CallNode { callClass = cl2, callSlices = sls2 }
    | cl1 /= cl2 = panic "Saw different function classes" []
    -- FIXME: check that the sets don't overlap
    | otherwise =
      -- trace ("Merging " ++ showPP cn ++ " and " ++ showPP cn') $
      -- Note: it is OK to use as the maps are disjoint
      cn { callSlices = Map.union sls1 sls2 }

instance FreeVars CallNode where
  freeVars cn  = foldMap freeVars (Map.elems (callSlices cn))
  freeFVars cn = Set.singleton (callName cn)

instance TraverseUserTypes CallNode where
  traverseUserTypes f cn  =
    (\n' sls' -> cn { callName = n', callSlices = sls' })
       <$> traverseUserTypes f (callName cn)
       <*> traverse (traverse (traverseUserTypes f)) (callSlices cn)

instance PP CallNode where
  ppPrec n CallNode { callName = fname, callClass = cl, callSlices = sls } =
    wrapIf (n > 0) $ (pp fname <> parens (pp cl))
    <+> vcat (map (\(n', vs) -> brackets (pp n') <> parens (commaSep (map ppA vs))) (Map.toList sls))
    where
      ppA Nothing = "_"
      ppA (Just v) = pp v

type Slice = Slice' CallNode SLExpr

--------------------------------------------------------------------------------
-- Class instances

instance AbsEnv ae => PP (GuardedSlice ae) where
  pp gs = vcat [ pp (gsEnv gs)
               , "For" <+> brackets (maybe " (non-result) " pp (gsPred gs))
               , pp (gsSlice gs)  ]

instance AbsEnv ae => PP (Domain ae) where
  pp d =
    hang "Open" 2 (vcat (map pp (elements d)))
    $+$
    hang "Closed" 2 (vcat (map go (Map.toList (closedElements d))))
    where
      go (k, v) = hang (pp k) 2 (bullets (map pp v))

-- instance PP Domain where
--   pp d = vcat (map pp_el (elements d))
--     where
--       pp_el (vs, fp) = pp vs <> " => " <> pp fp
