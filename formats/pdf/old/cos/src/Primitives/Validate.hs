{-# Language BlockArguments, DataKinds, ViewPatterns #-}
module Primitives.Validate where

import qualified Daedalus.RTS.Vector as V
import Daedalus.RTS.Numeric
import RTS.ParseError

import PdfMonad.Transformer

primIsValidated ::
  PdfParser parser => Integer -> Integer ->  V.Vector (UInt 8) -> parser Bool
primIsValidated o g (V.vecToRep -> t) =
  do r <- toRef o g
     isValidated r t

primStartValidating ::
  PdfParser parser => Integer -> Integer -> V.Vector (UInt 8) -> parser ()
primStartValidating o g (V.vecToRep -> t) =
  do r <- toRef o g
     startvalidating r t


toRef :: PdfParser parser => Integer -> Integer -> parser R
toRef obj gen =
  case (toInt obj, toInt gen) of
    (Just o, Just g) -> pure R { refObj = o, refGen = g }
    _ -> pError' FromUser [] $
            "Invalid reference R:" ++ show obj ++ ":" ++ show gen
      -- XXX: location?


