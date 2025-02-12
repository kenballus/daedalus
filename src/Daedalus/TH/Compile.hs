module Daedalus.TH.Compile where

import Data.Text(Text)
import qualified Data.Text as Text
import qualified Data.Map as Map
import Control.Exception(try)
import Control.Monad.IO.Class(liftIO)
import System.FilePath(takeFileName, dropExtension)
import System.Directory(canonicalizePath)

import Daedalus.SourceRange(SourcePos(..))
import qualified Daedalus.TH as TH

import Daedalus.AST(ModuleName)
import qualified Daedalus.Core.Inline as Core
import qualified Daedalus.VM as VM
import qualified Daedalus.VM.Backend.Haskell as VM
import qualified Daedalus.VM.Compile.Decl as VM (moduleToProgram)

import qualified Daedalus.Driver as DDL

data CompileConfig = CompileConfig
  { userMonad       :: Maybe TH.TypeQ
  , userPrimitives  :: [(Text, [TH.ExpQ] -> TH.ExpQ)]
  , userEntries     :: [String]
  , specPath        :: [FilePath]
  , nicerErrors     :: Bool
  }

defaultConfig :: CompileConfig
defaultConfig = CompileConfig
  { userMonad      = Nothing
  , userPrimitives = []
  , userEntries    = ["Main"]
  , specPath       = ["."]
  , nicerErrors    = True
  }

data DDLText = Inline SourcePos Text
             | FromFile FilePath
             | FromModule ModuleName -- assumes it's parsed

compileDDL :: DDLText -> TH.DecsQ
compileDDL = compileDDLWith defaultConfig

compileDDLWith :: CompileConfig -> DDLText -> TH.DecsQ
compileDDLWith cfg ddlText =
  do case ddlText of
       FromFile f -> do f' <- liftIO (canonicalizePath f)
                        liftIO (putStrLn ("Compiling: " ++ show f'))
                        TH.addDependentFile f'
       _          -> pure ()
     mb <-
        liftIO $ try $ DDL.daedalus
           do DDL.ddlSetOpt DDL.optSearchPath (specPath cfg)
              ast <- loadDDLVM cfg ddlText
              let getPrim (x,c) =
                    do mb <- DDL.ddlGetFNameMaybe "Main" x
                       case mb of
                         Nothing -> DDL.ddlThrow
                            (DDL.ADriverError ("Unknown primitive: " <> show x))
                         Just f  -> pure (f,c)
              primMap <- Map.fromList <$> mapM getPrim (userPrimitives cfg)
              pure (ast,primMap)

     (ast,primMap) <- case mb of
                        Left e  -> fail =<< liftIO (DDL.prettyDaedalusError e)
                        Right a -> pure a

     let c = VM.defaultConfig { VM.userMonad = userMonad cfg
                              , VM.userPrimitives = primMap
                              }

     VM.compileModule c ast

loadDDLVM :: CompileConfig -> DDLText -> DDL.Daedalus VM.Module
loadDDLVM cfg src =
  do let roots = userEntries cfg
     mo <- case src of
             Inline loc txt ->
               do let mo = "Main"
                  DDL.parseModuleFromText mo loc txt
                  pure mo
             FromFile f ->
               do let mo = Text.pack (dropExtension (takeFileName f))
                  DDL.parseModuleFromFile mo f
                  pure mo
             FromModule mo -> pure mo
     DDL.ddlLoadModule mo

     let specMod = "MainCore"
     let rootPs = [(mo, Text.pack root) | root <- roots ]
     DDL.passSpecialize specMod rootPs
     DDL.passCore specMod
     -- rootFs <- mapM (uncurry DDL.ddlGetFName) rootPs
     -- DDL.passInline Core.AllBut rootFs specMod
     DDL.passDeterminize specMod
     DDL.passNorm specMod
     DDL.ddlSetOpt DDL.optDebugMode (nicerErrors cfg)
     DDL.passVM specMod
     m <- DDL.ddlGetAST specMod DDL.astVM

     pure $ head $ VM.pModules $ VM.moduleToProgram [m]

saveDDLWith :: CompileConfig -> DDLText -> Maybe FilePath -> IO ()
saveDDLWith cfg src mbfile =
  do ds <- TH.runQ (compileDDLWith cfg src)
     let txt = show (TH.ppr_list ds)
     case mbfile of
       Nothing   -> putStrLn txt
       Just file -> writeFile file txt
