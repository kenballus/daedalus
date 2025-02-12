module Daedalus.VM.TypeRep where

import Daedalus.Panic(panic)
import Daedalus.VM
import qualified Daedalus.Core as Src

data TypeRep =
    NoRefs  -- ^ Types with no memory management
            -- (passed by value, contain no references)
  | HasRefs -- ^ Types passed by valuekdd references
    deriving Eq

typeRepOf :: HasType t => t -> TypeRep
typeRepOf = typeRep . getType

ifRefs :: HasType t => Ownership -> t -> Ownership
ifRefs o x = case typeRepOf x of
               NoRefs  -> Unmanaged
               HasRefs -> o

class GetTypeRep t where
  typeRep :: t -> TypeRep

instance GetTypeRep VMT where
  typeRep ty =
    case ty of
      TThreadId {} -> NoRefs
      TSem sty     -> typeRep sty

instance GetTypeRep Src.Type where
  typeRep ty =
    case ty of
      Src.TStream       -> HasRefs    -- array of bytes
      Src.TUInt n       -> numRep n
      Src.TSInt n       -> numRep n
      Src.TInteger      -> HasRefs
      Src.TBool         -> NoRefs
      Src.TFloat        -> NoRefs
      Src.TDouble       -> NoRefs
      Src.TUnit         -> NoRefs
      Src.TArray {}     -> HasRefs
      Src.TMaybe t      -> typeRep t
      Src.TMap {}       -> HasRefs
      Src.TBuilder {}   -> HasRefs
      Src.TIterator {}  -> HasRefs
      Src.TUser ut      -> if Src.tnameBD (Src.utName ut)
                              then NoRefs
                              else HasRefs  -- hm, an unboxed struct full of
                                            -- ints wouldn't have any refs...
      Src.TParam {}     -> panic "typeRep" ["Unexpepected type paramer"]
    where
    numRep n =
      case n of
        Src.TSize x
          | x <= 64   -> NoRefs
          | otherwise -> panic "typeRep" [ "Bitvectors > 64 not implemented." ]
        Src.TSizeParam {} ->
          panic "typeRep" [ "Unexpceted size type parameter" ]



