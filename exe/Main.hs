{-# Language OverloadedStrings, ScopedTypeVariables, BlockArguments #-}
module Main where

import qualified Data.Text as Text
import qualified Data.Map as Map
import Control.Exception( catches, Handler(..), SomeException(..)
                        , displayException
                        )
import Control.Monad(when,forM_)
import Data.Maybe(fromMaybe)
import System.FilePath hiding (normalise)
import qualified Data.ByteString as BS
import System.Directory(createDirectoryIfMissing)
import System.Exit(exitSuccess,exitFailure,exitWith)
import System.IO(stdin,stdout,stderr,hSetEncoding,utf8)
import System.Console.ANSI
import Data.Traversable(for)
import Data.Foldable(for_,toList)
import Text.Show.Pretty (ppDoc)

import Hexdump

import Daedalus.PP
import Daedalus.SourceRange

import Daedalus.Driver

import qualified RTS.ParserAPI as RTS
import qualified RTS.Input as RTS

import Daedalus.AST hiding (Value)
import Daedalus.Interp
import Daedalus.Interp.Value(valueToJS)
import Daedalus.Compile.LangHS
import qualified Daedalus.ExportRuleRanges as Export
import Daedalus.Type.AST(TCModule(..))
import Daedalus.ParserGen as PGen
import qualified Daedalus.Core as Core
import qualified Daedalus.Core.Semantics.Value as Core
import qualified Daedalus.Core.Semantics.Decl as Core
import qualified Daedalus.VM as VM
import qualified Daedalus.VM.Compile.Decl as VM
import qualified Daedalus.VM.BorrowAnalysis as VM
import qualified Daedalus.VM.InsertCopy as VM
import qualified Daedalus.VM.GraphViz as VM
import qualified Daedalus.VM.Backend.C as C

import CommandLine
import CPPDriver

main :: IO ()
main =
  do opts <- inputHack <$> getOptions
     when (optForceUTF8 opts)
       do hSetEncoding stdout utf8
          hSetEncoding stderr utf8
          hSetEncoding stdin  utf8
     daedalus (handleOptions opts)
       `catches`
       [ Handler \e ->
           do putStrLn =<< prettyDaedalusError e
              exitFailure

       , Handler \e -> exitWith e

       , Handler \(SomeException e) ->
           do putStrLn (displayException e)
              exitFailure
       ]


-- Currently during specialization we combine all input modules into a single
-- module.  This is the name of the resulting module
specMod :: ModuleName
specMod = "DaedalusMain"

handleOptions :: Options -> Daedalus ()
handleOptions opts
  | DumpRuleRanges <- optCommand opts =
    do mm   <- ddlPassFromFile passResolve (optParserDDL opts)
       mods <- mapM (`ddlGetAST` astParse) =<< ddlBasis mm
       ddlPutStrLn (Export.jsModules mods)
       ddlIO exitSuccess

  | DumpRaw <- optCommand opts =
    do mm   <- ddlPassFromFile passParse (optParserDDL opts)
       mo <- ddlGetAST mm astParse
       ddlPrint (ppDoc mo)

  | otherwise =
    do mm <- ddlPassFromFile ddlLoadModule (optParserDDL opts)
       allMods <- ddlBasis mm
       let mainRule = (mm,"Main")

       case optCommand opts of

         DumpTC ->
           for_ allMods \m -> ddlPrint . pp =<< ddlGetAST m astTC

         DumpSpec ->
           do passSpecialize specMod [mainRule]
              mo <- ddlGetAST specMod astTC
              ddlPrint (pp mo)

         DumpNorm ->
           do passSpecialize specMod [mainRule]
              mapM_ (ddlPrint . pp) =<< normalizedDecls

         DumpCore ->
            do _ <- doToCore opts mm
               ddlPrint . pp =<< ddlGetAST specMod astCore

         DumpVM -> ddlPrint . pp =<< doToVM opts mm

         DumpGraph onlyFun ->
           do prog <- doToVM opts mm
              let sty = if onlyFun then VM.OnlyCalls else VM.Everything
              ddlPutStrLn (VM.toGraphViz sty prog)


         DumpGen ->
           do passSpecialize specMod [mainRule]
              prog <- ddlGetAST specMod astTC
              -- prog <- normalizedDecls
              ddlIO (
                do let aut = PGen.buildArrayAut [prog]
                   PGen.autToGraphviz aut
                   let llas = PGen.buildPipelineLLA aut
                   PGen.llaToGraphviz aut llas
                   PGen.statsLLA aut llas
                )

         Interp inp ->
           case optBackend opts of
             UseInterp ->
               do prog <- for allMods \m -> ddlGetAST m astTC
                  ddlIO (interpInterp (optShowJS opts) inp prog mainRule)

             UseCore -> interpCore opts mm inp

             UsePGen flagMetrics ->
               do passSpecialize specMod [mainRule]
                  prog <- ddlGetAST specMod astTC
                  ddlIO (interpPGen (optShowJS opts) inp [prog] flagMetrics)
               --do passSpecialize specMod [mainRule]
               --   prog <- normalizedDecls
               --   ddlIO (interpPGen inp prog)

         DumpRuleRanges -> error "Bug: DumpRuleRanges"
         DumpRaw -> error "Bug: DumpRaw"

         CompileHS ->
            mapM_ (saveHS (optOutDir opts) cfg) allMods
            where
            cfg = CompilerCfg
                    { cPrims      = Map.empty -- Don't support prims
                    , cParserType = "Parser"
                    , cImports    = [Import "RTS.Parser" Unqualified]
                    , cQualNames  = UseQualNames
                    }

         CompileCPP ->
           -- XXX: this is a backend in a different sense
           case optBackend opts of
             UseInterp -> generateCPP opts mm
             UseCore   -> generateCPP opts mm
             UsePGen _ ->
               do passSpecialize specMod [mainRule]
                  prog <- ddlGetAST specMod astTC
                  let outDir = fromMaybe "." $ optOutDir opts
                  compilePGen [prog] outDir

         ShowHelp -> ddlPutStrLn "Help!" -- this shouldn't happen


interpInterp ::
  Bool -> Maybe FilePath -> [TCModule SourceRange] -> (ModuleName,Ident) ->
    IO ()
interpInterp useJS inp prog (m,i) =
  do (_,res) <- interpFile inp prog (ModScope m i)
     dumpResult (dumpInterpVal useJS) (dumpErr useJS) res
     case res of
       Results {}   -> exitSuccess
       NoResults {} -> exitFailure

interpCore :: Options -> ModuleName -> Maybe FilePath -> Daedalus ()
interpCore opts mm inpMb =
  do ents <- doToCore opts mm
     env  <- Core.evalModuleEmptyEnv <$> ddlGetAST specMod astCore
     inp  <- ddlIO (RTS.newInputFromFile inpMb)
     let showVal = dumpCoreVal (optShowJS opts)
         showErr = dumpErr (optShowJS opts)
     ddlIO $ forM_ ents \ent -> dumpResult showVal showErr (Core.runEntry env ent inp)

doToCore :: Options -> ModuleName -> Daedalus [Core.FName]
doToCore opts mm =
  do let entries = parseEntries opts mm
     passSpecialize specMod entries
     passCore specMod
     ents <- mapM (uncurry ddlGetFName) entries
     when (optInline opts) (passInline ents specMod)
     when (optStripFail opts) (passStripFail specMod)
     pure ents

doToVM :: Options -> ModuleName -> Daedalus VM.Program
doToVM opts mm =
  do ents <- doToCore opts mm
     passVM specMod
     m <- ddlGetAST specMod astVM
     let addMM = VM.addCopyIs . VM.doBorrowAnalysis
     pure $ addMM $ VM.moduleToProgram ents [m]




parseEntries :: Options -> ModuleName -> [(ModuleName,Ident)]
parseEntries opts mm =
  case optEntries opts of
    [] -> [(mm,"Main")]
    es -> map parseEntry es
  where
  parseEntry x =
    case break (== '.') x of
      (as,_:bs) -> (Text.pack as, Text.pack bs)
      _         -> (mm, Text.pack x)


generateCPP :: Options -> ModuleName -> Daedalus ()
generateCPP opts mm =
  do let makeExe = null (optEntries opts)
     when (makeExe && optOutDir opts == Nothing)
       $ ddlIO $ throwOptError
           [ "Generating a parser executable requires an output director" ]

     prog <- doToVM opts mm
     let outFileRoot = "main_parser" -- XXX: parameterize on this
         (hpp,cpp) = C.cProgram outFileRoot prog

     ddlIO (saveFiles makeExe outFileRoot hpp cpp)

  where
  saveFiles makeExe outFileRoot hpp cpp =
    do dir <- case optOutDir opts of
                Nothing -> pure "."
                Just d  -> do createDirectoryIfMissing True d
                              pure d

       let root = dir </> outFileRoot
       writeFile (addExtension root "h") (show hpp)
       writeFile (addExtension root "cpp") (show cpp)

       when makeExe
         do let save (x,b) =
                  do putStrLn ("Saving " ++ x)
                     let d = dir </> takeDirectory x
                     createDirectoryIfMissing True d
                     BS.writeFile (dir </> x) b
            mapM_ save template_files



interpPGen :: Bool -> Maybe FilePath -> [TCModule SourceRange] -> Bool -> IO ()
interpPGen useJS inp moduls flagMetrics =
  do let aut = PGen.buildArrayAut moduls
     let lla = PGen.createLLA aut                   -- LL
     let repeatNb = 1 -- 200
     do
       mapM_
         (\ i ->
           do bytes <-
                case inp of
                  Nothing -> pure BS.empty
                  Just f  -> BS.readFile f
              let results = PGen.runnerLL bytes aut lla flagMetrics  -- LL
              -- let results = PGen.runnerBias bytes aut
              let resultValues = PGen.extractValues results
              if null resultValues
                then
                  do putStrLn $ PGen.extractParseError bytes results
                     exitFailure
                else
                  do
                    if (i == 1)
                      then dumpValues (dumpInterpVal useJS) resultValues
                      else return ()
                    if flagMetrics
                      then
                      let countBacktrack = fst (extractMetrics results)
                          countLL =        snd (extractMetrics results)
                      in
                        do putStrLn
                             ( "\nScore (LL / (Backtrack + LL)): " ++
                               (if (countBacktrack + countLL) == 0
                                then "NA"
                                else (show ((countLL * 100) `div` (countBacktrack + countLL))) ++ "%")
                             )
                      else return ()
                    exitSuccess -- comment this with i > 1
         ) [(1::Int)..repeatNb]

compilePGen :: [TCModule SourceRange] -> FilePath -> Daedalus ()
compilePGen moduls outDir =
  do let aut = PGen.buildArrayAut moduls
     t <- ddlIO $ PGen.generateTextIO aut
     -- TODO: This needs more thought
     finalText <- completeContent t
     let outFile = outDir </> "grammar.c"
     ddlIO $ writeFile outFile finalText
     where
       completeContent t = do
         let templateFile = "." </> "rts-pgen-c" </> "template.c"
         template <- ddlIO $ readFile templateFile
         return $ template ++ t




inputHack :: Options -> Options
inputHack opts =
  case optCommand opts of
    DumpTC | let f = optParserDDL opts
             , takeExtension f == ".input"
             , let xs = takeWhile (/= '.') (takeFileName f) ->
               opts { optParserDDL = addExtension (takeDirectory f </> xs) "ddl"
                    , optCommand = Interp (Just f)
                    }
    _ -> opts



dumpResult :: (a -> Doc) -> (ParseError -> IO ()) -> RTS.Result a -> IO ()
dumpResult ppVal ppErr r =
  case r of
   RTS.NoResults err -> ppErr err
   RTS.Results as -> dumpValues ppVal (toList as)

dumpValues :: (a -> Doc) -> [a] -> IO ()
dumpValues ppVal as =
  do putStrLn $ "--- Found " ++ show (length as) ++ " results:"
     print $ vcat' $ map ppVal as


dumpInterpVal :: Bool -> Value -> Doc
dumpInterpVal useJS = if useJS then valueToJS else pp

dumpCoreVal :: Bool -> Core.Value -> Doc
dumpCoreVal useJS = if useJS then pp else pp -- XXX: JS

dumpErr :: Bool -> ParseError -> IO ()
dumpErr useJS err
  | useJS = print (RTS.errorToJS err)
  | otherwise =
  do putStrLn "--- Parse error: "
     print (RTS.ppParseError err)
     let ctxtAmt = 32
         bs      = RTS.inputTopBytes (RTS.peInput err)
         errLoc  = RTS.peOffset err
         start = max 0 (errLoc - ctxtAmt)
         end   = errLoc + 10
         len   = end - start
         ctx = BS.take len (BS.drop start bs)
         startErr =
            setSGRCode [ SetConsoleIntensity
                         BoldIntensity
                       , SetColor Foreground Vivid Red ]
         endErr = setSGRCode [ Reset ]
         cfg = defaultCfg { startByte = start
                          , transformByte =
                             wrapRange startErr endErr
                             errLoc errLoc }
     putStrLn "File context:"
     putStrLn $ prettyHexCfg cfg ctx


