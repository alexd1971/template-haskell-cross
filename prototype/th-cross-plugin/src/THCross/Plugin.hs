{-# LANGUAGE LambdaCase #-}

-- | Prototype GHC plugin for intercepting Template Haskell splice evaluation.
--
-- The plugin installs a custom 'runMetaHook' through the driver plugin hook.
-- By default it logs each splice and delegates to GHC's normal Template
-- Haskell evaluator. With @-fplugin-opt=THCross.Plugin:dummy-expr@ it replaces
-- expression splices with the parsed-side AST for @42@ without executing the
-- original splice expression.
module THCross.Plugin (plugin) where

import GHC.Driver.Env.Types (HscEnv (..))
import GHC.Driver.Hooks (Hooks (..))
import GHC.Driver.Plugins
  ( CommandLineOption
  , Plugin (..)
  , defaultPlugin
  , purePlugin
  )
import GHC.Parser.Annotation (getLocA)
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (getGblEnv, liftIO)
import GHC.Types.Meta (MetaHook, MetaRequest (..))
import GHC.Unit.Module (moduleName, moduleNameString)
import GHC.Utils.Outputable (ppr, showSDocUnsafe)
import THCross.ParseFragment (parseExpressionFragment)

-- | Entry point discovered by GHC when @-fplugin=THCross.Plugin@ is used.
--
-- The plugin only mutates 'HscEnv' to install 'loggingMetaHook'; it does not
-- alter Core, typechecking, or parsed/renamed module results.
plugin :: Plugin
plugin =
  defaultPlugin
    { driverPlugin = installHook
    , pluginRecompile = purePlugin
    }

-- | Install the custom 'runMetaHook' into the current compiler session.
--
-- GHC calls this once after loading the plugin. The hook is stored in
-- 'hsc_hooks', so all subsequent TH splice evaluation in this session goes
-- through 'loggingMetaHook'.
installHook :: [CommandLineOption] -> HscEnv -> IO HscEnv
installHook opts hscEnv =
  let hooks0 = hsc_hooks hscEnv
      hooks1 = hooks0 {runMetaHook = Just (loggingMetaHook (enableDummyExpr opts))}
   in pure hscEnv {hsc_hooks = hooks1}

-- | Log metadata for every intercepted TH request and then evaluate it.
--
-- In normal mode this delegates to 'defaultRunMeta', preserving stock GHC TH
-- behavior. In dummy expression mode, only 'MetaE' requests are replaced with
-- @42@; all other request kinds still delegate to GHC.
loggingMetaHook :: Bool -> MetaHook TcM
loggingMetaHook dummyExpr request spliceExpr = do
  tcg <- getGblEnv
  let modText = moduleNameString (moduleName (tcg_mod tcg))
      kindText = metaRequestKind request
      spanText = showSDocUnsafe (ppr (getLocA spliceExpr))
      exprText = showSDocUnsafe (ppr spliceExpr)
  liftIO $ putStrLn "THCross.Plugin intercepted Template Haskell splice"
  liftIO $ putStrLn ("module: " <> modText)
  liftIO $ putStrLn ("kind: " <> kindText)
  liftIO $ putStrLn ("location: " <> spanText)
  liftIO $ putStrLn ("expression: " <> exprText)
  case request of
    MetaE wrap
      | dummyExpr -> do
          liftIO $ putStrLn "replacement: 42"
          generated <- parseExpressionFragment "42"
          pure (wrap generated)
    _ -> defaultRunMeta request spliceExpr

-- | Whether expression splices should be replaced with @42@.
--
-- Enabled by:
--
-- @
-- -fplugin-opt=THCross.Plugin:dummy-expr
-- @
enableDummyExpr :: [CommandLineOption] -> Bool
enableDummyExpr = elem "dummy-expr"

-- | Human-readable splice kind used in prototype logging.
metaRequestKind :: MetaRequest -> String
metaRequestKind = \case
  MetaE{} -> "expression"
  MetaP{} -> "pattern"
  MetaT{} -> "type"
  MetaD{} -> "declaration"
  MetaAW{} -> "annotation-wrapper"
