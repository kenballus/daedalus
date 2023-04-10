{
{-# Language TemplateHaskell, OverloadedStrings, BlockArguments #-}
module Daedalus.Parser.Lexer
  ( Lexeme(..), Token(..)
  , lexer, lexerAt
  , SourcePos(..)
  , startPos
  ) where

import AlexTools
import Data.List(foldl')
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.ByteString as BS
import Data.Char(isDigit)

import Daedalus.Parser.Tokens
import Daedalus.Parser.Layout

-- import Debug.Trace

}

$bigAlpha   = [A-Z]
$smallAlpha = [a-z]
$alpha      = [$bigAlpha $smallAlpha _]
$octDigit   = [0-8]
$digit      = [0-9]
$hexDigit   = [0-9a-fA-F]
$binDigit   = [01]
$anybyte    = [\32-\127]
$ws         = [\0\9\10\13\32]

@bigIdent   = $bigAlpha   [$alpha $digit]*
@smallIdent = $smallAlpha [$alpha $digit]*
@setIdent   = \$ @smallIdent
@smallIdentI = \? @smallIdent
@bigIdentI   = \? @bigIdent
@setIdentI   = \? @setIdent
@natural    = $digit+
@integer    = \-? $digit (_ | $digit)*
@hexLiteral = 0 [xX] $hexDigit (_ | $hexDigit)*
@octLiteral = 0 [oO] $octDigit (_ | $octDigit)*
@binLiteral = 0 [bB] $binDigit (_ | $binDigit)*

@esc        = \\ (@natural | \\ | \' | " | n | t | r | & | [xX] $hexDigit $hexDigit* )
@byte       = \' ($anybyte # [\\] | @esc) \'
@bytes      = \" ($anybyte # [\"\\] | @esc)* \"

@b256Literal = 0 [sS] @bytes

@comment    = "--" .* \n

:-

<comment> {
"{-"        { startComment }
"-}"        { endComment }
.           ;
\n          ;
}

<0> {
$ws+        ;
@comment    ;
"{-"        { startComment }
"("         { lexeme OpenParen }
")"         { lexeme CloseParen }
"{"         { lexeme OpenBrace }
"}"         { lexeme CloseBrace }
"{|"        { lexeme OpenBraceBar }
"|}"        { lexeme CloseBraceBar }
"["         { lexeme OpenBracket }
"]"         { lexeme CloseBracket }


"@"         { lexeme AtSign }
"$"         { lexeme Dollar }
"!"         { lexeme Bang }
"^"         { lexeme Hat }
"="         { lexeme Equals }
"=="        { lexeme DoubleEquals }
"!="        { lexeme BangEquals }
"<="        { lexeme TokLeq }
">="        { lexeme TokGeq }
"<"         { lexeme OpenTri }
">"         { lexeme CloseTri }
":"         { lexeme Colon }
";"         { lexeme Semi }
".."        { lexeme DotDot }
"."         { lexeme Dot }
","         { lexeme Comma }
"|"         { lexeme Bar }
".|."       { lexeme DotBarDot }
".&."       { lexeme DotAmpDot }
".^."       { lexeme DotHatDot }
"||"        { lexeme BarBar }
"&&"        { lexeme AmpAmp }
"<|"        { lexeme LtBar }
"$$"        { lexeme DollarDollar }
"+"         { lexeme Plus }
"-"         { lexeme Minus }
"*"         { lexeme Star }
"/"         { lexeme ForwardSlash }
"%"         { lexeme Percent }
"#"         { lexeme Hash }
"<#"        { lexeme LeftHash }
"<<"        { lexeme ShiftL }
">>"        { lexeme ShiftR }
"~"         { lexeme BitwiseComplementT }
"->"        { lexeme RightArrow }
"_"         { lexeme Underscore }

"import"    { lexeme KWImport }
"extern"    { lexeme KWExtern }
"def"       { lexeme KWDef }
"bitdata"   { lexeme KWBitData }
"struct"    { lexeme KWstruct }
"union"     { lexeme KWunion }
"where"     { lexeme KWWhere }

"for"       { lexeme KWFor }
"map"       { lexeme KWMap }
"in"        { lexeme KWIn }
"is"        { lexeme KWIs }
"of"        { lexeme KWOf }
"if"        { lexeme KWIf }
"try"       { lexeme KWTry }
"then"      { lexeme KWThen }
"else"      { lexeme KWElse }
"as"        { lexeme KWAs }
"as!"       { lexeme KWAsBang }
"as?"       { lexeme KWAsQuestion }
"case"      { lexeme KWCase }
"block"     { lexeme KWblock }
"let"       { lexeme KWlet }

"Choose"    { lexeme KWChoose }
"First"     { lexeme KWFirst }
"Accept"    { lexeme KWAccept }
"Optional"  { lexeme KWOptional }
"Optional?" { lexeme KWOptionalQuestion }
"Many"      { lexeme KWMany }
"Many?"     { lexeme KWManyQuestion }
"many"      { lexeme KWmany }
"many?"     { lexeme KWmanyQuestion }
"UInt8"     { lexeme KWUInt8 }
"$any"      { lexeme KWDollarAny }
"Match"     { lexeme KWMatch }
"END"       { lexeme KWEND }
"commit"    { lexeme KWCOMMIT }
"Fail"      { lexeme KWFail }

"empty"     { lexeme KWMapEmpty }
"Insert"    { lexeme KWMapInsert }
"insert"    { lexeme KWMapinsert }
"Lookup"    { lexeme KWMapLookup }
"lookup"    { lexeme KWMaplookup }

"build"     { lexeme KWBuilderbuild}
"emit"      { lexeme KWBuilderemit }
"emitArray" { lexeme KWBuilderemitArray }
"emitBuilder" { lexeme KWBuilderemitBuilder }
"builder"   { lexeme KWBuilderbuilder }

"Offset"    { lexeme KWOffset }
"SetStream" { lexeme KWSetStream }
"GetStream" { lexeme KWGetStream }
"take"      { lexeme KWtake }
"Take"      { lexeme KWTake }
"Drop"      { lexeme KWDrop }
"arrayStream" { lexeme KWArrayStream }
"bytesOfStream" { lexeme KWBytesOfStream }

"Index"     { lexeme KWArrayIndex }
"concat"    { lexeme KWConcat }
"length"    { lexeme KWArrayLength }
"rangeUp"   { lexeme KWRangeUp }
"rangeDown" { lexeme KWRangeDown }

"pi"              { lexeme KWpi }
"wordToFloat"     { lexeme KWWordToFloat }
"wordToDouble"    { lexeme KWWordToDouble }
"isNaN"           { lexeme KWIsNaN }
"isInfinite"      { lexeme KWIsInfinite }
"isDenormalized"  { lexeme KWIsDenormalized }
"isNegativeZero"  { lexeme KWIsNegativeZero }

"true"      { lexeme KWTrue }
"false"     { lexeme KWFalse }

"just"      { lexeme KWJust }
"nothing"   { lexeme KWNothing }

"int"       { lexeme KWInt }
"uint"      { lexeme KWUInt }
"sint"      { lexeme KWSInt }
"float"     { lexeme KWFloat }
"double"    { lexeme KWDouble }
"bool"      { lexeme KWBool }
"maybe"     { lexeme KWMaybe }
"stream"    { lexeme KWStream }

@bigIdent     { lexeme BigIdent }
@smallIdent   { lexeme SmallIdent }
@bigIdentI    { lexeme BigIdentI }
@smallIdentI  { lexeme SmallIdentI }
@setIdent     { lexeme SetIdent }
@setIdentI    { lexeme SetIdentI }
@b256Literal  { lex256Literal }
@byte         { lexByte }
@bytes        { lexBytes }
@integer      { lexInteger }
@hexLiteral   { lexHexLiteral }
@octLiteral   { lexOctLiteral }
@binLiteral   { lexBinLiteral }

.           { do { txt <- matchText
                 ; lexeme (TokError
                            ("Unexpected character: " ++ Text.unpack txt))
                 } }
}

{

lexUnpackLiteral :: Text -> String
lexUnpackLiteral = filter (/= '_') . Text.unpack

lexInteger :: Action s [Lexeme Token]
lexInteger =
  do x <- lexUnpackLiteral <$> matchText
     lexeme $! Number (read x) Nothing

lexHexLiteral :: Action s [Lexeme Token]
lexHexLiteral =
  do x <- lexUnpackLiteral <$> matchText
     -- read supports hex literals too
     lexeme $! Number (read x) (Just ((length x - 2) * 4)) -- - 2 for '0x'

lexOctLiteral :: Action s [Lexeme Token]
lexOctLiteral =
  do x <- lexUnpackLiteral <$> matchText
     -- read supports hex literals too
     lexeme $! Number (read x) (Just ((length x - 2) * 3)) -- - 2 for '0o'

lexBinLiteral :: Action s [Lexeme Token]
lexBinLiteral =
  do ds <- lexUnpackLiteral <$> matchText
     let vs = map (\x -> if x == '0' then 0 else 1) (drop 2 ds) -- removing the '0b'
         r  = foldl (\acc x -> x + 2 * acc) 0 vs
     lexeme $! Number r (Just (length vs))

lexByte :: Action s [Lexeme Token]
lexByte =
  do x <- Text.unpack <$> matchText
     lexeme $! case unEsc (noQuotes x) of
                 Left err -> TokError err
                 Right (a,_) -> Byte a

lexBytes :: Action s [Lexeme Token]
lexBytes =
  do x <- Text.unpack <$> matchText
     lexeme $!
       case checkBytes (noQuotes x) of
         Left err -> TokError err
         Right bs -> Bytes (BS.pack bs)

checkBytes :: String -> Either String [Word8]
checkBytes xs =
  case xs of
    [] -> Right []
    '\\':'&':ys -> checkBytes ys
    _  -> do (c,cs) <- unEsc xs
             rest <- checkBytes cs
             pure (c:rest)

lex256Literal :: Action s [Lexeme Token]
lex256Literal =
  do x <- Text.unpack <$> matchText
     lexeme $!
       case checkBytes (noQuotes (drop 2 x)) of
         Left err -> TokError err
         Right bs  -> Number val (Just (length bs * 8))
           where val = foldl' (\tot d -> tot * 256 + toInteger d) 0 bs

noQuotes :: String -> String
noQuotes = init . drop 1


unEsc :: String -> Either String (Word8,String)
unEsc xs =
  case xs of
    '\\' : esc -> doEsc esc
    c    : cs  -> Right (w8 c, cs)
    _          -> error "Bug: empty byte"

  where
  w8 = toEnum . fromEnum

  doEsc cs =
    case span isDigit cs of
      ([],x : ys) ->
        case x of
          't'   -> Right (w8 '\t', ys)
          'n'   -> Right (w8 '\n', ys)
          'r'   -> Right (w8 '\r', ys)
          '\\'  -> Right (w8 '\\', ys)
          '\''  -> Right (w8 '\'', ys)
          '"'   -> Right (w8 '"', ys)
          'x'   -> getHexEsc ys
          'X'   -> getHexEsc ys
          _     -> error "Bug: unexpected escape"

      (ds,ys) -> let n = read ds
                 in if n < 256 then Right (fromInteger n, ys)
                               else Left "Byte literal is too large."
  getHexEsc cs = let (digits, other) = span isHexDigit cs
                 in case digits of
                      [] -> Left "No digits in hex escape"
                      _  -> let n = read ('0' : 'x' : digits)
                            in if n < 256
                                 then Right (fromInteger n, other)
                                 else Left "Byte hex literal is too large."
  isHexDigit = flip elem (['0'..'9'] ++ ['a' .. 'f'] ++ ['A' .. 'F'])

alexGetByte :: Input -> Maybe (Word8, Input)
alexGetByte = makeAlexGetByte (toEnum . fromEnum)

data LexState = Normal | InComment !SourceRange LexState

startComment :: Action LexState [Lexeme Token]
startComment =
  do r <- matchRange
     s <- getLexerState
     setLexerState (InComment r s)
     pure []

endComment :: Action LexState [Lexeme Token]
endComment =
  do ~(InComment _ s) <- getLexerState
     setLexerState s
     pure []

lexer :: Text -> Text -> [Lexeme Token]
lexer file = lexerAt (startPos file)

lexerAt :: SourcePos -> Text -> [Lexeme Token]
lexerAt loc txt = layout ($makeLexer cfg (initialInputAt loc txt))
  where
  -- dbg xs = trace (unlines [ show (Text.unpack (lexemeText l)) ++
  --          "\t" ++ show (lexemeToken l) |  l <- xs ]) xs

  eof p = Lexeme { lexemeToken = TokEOF
                 , lexemeText  = ""
                 , lexemeRange = AlexTools.range p
                 }
  cfg = LexerConfig { lexerInitialState = Normal
                    , lexerStateMode = \s -> case s of
                                               Normal -> 0
                                               InComment {} -> 1
                    , lexerEOF = \s p ->
                        [ case s of
                            Normal -> eof p
                            InComment r _ ->
                              Lexeme { lexemeToken =
                                           TokError "Unterminated comment."
                                     , lexemeText = ""
                                     , lexemeRange = r
                                     } ]

                    }

test :: String -> IO ()
test txt = mapM_ pp (lexer (Text.pack "(test)") (Text.pack txt))
  where
  pp l = putStrLn $ prettySourceRange (lexemeRange l) ++ ": " ++
                                      show (lexemeToken l)

}

