
module Talos.Analysis.Merge where

import           Daedalus.Core (Case (..))

-- Merging
--
-- Similar to a semigroup, but with more restrictions about how it can
-- be used (i.e., the merged objects come from the same program)

class Merge a where
  merge :: a -> a -> a

instance Merge a => Merge (Case a) where
  merge (Case e alts1) (Case _e alts2) = Case e (zipWith goAlt alts1 alts2)
    where
      goAlt (p, a1) (_p, a2) = (p, merge a1 a2)