# `runMetaHook` in GHC 9.8.4

This note is for GHC `9.8.4` only. Source paths below refer to the upstream GHC
tree at tag/branch `ghc-9.8.4-release`.

## Relevant Source Files

- `compiler/GHC/Types/Meta.hs`
- `compiler/GHC/Driver/Hooks.hs`
- `compiler/GHC/Driver/Plugins.hs`
- `compiler/GHC/Driver/Env/Types.hs`
- `compiler/GHC/Tc/Gen/Splice.hs`
- `compiler/GHC/Tc/Utils/Monad.hs`
- `compiler/GHC/Tc/Types.hs`

Upstream source URLs:

- <https://gitlab.haskell.org/ghc/ghc/-/raw/ghc-9.8.4-release/compiler/GHC/Types/Meta.hs>
- <https://gitlab.haskell.org/ghc/ghc/-/raw/ghc-9.8.4-release/compiler/GHC/Driver/Hooks.hs>
- <https://gitlab.haskell.org/ghc/ghc/-/raw/ghc-9.8.4-release/compiler/GHC/Tc/Gen/Splice.hs>

## Hook Field Type

Module: `GHC.Driver.Hooks`

Source path: `compiler/GHC/Driver/Hooks.hs`

`Hooks` contains:

```haskell
data Hooks = Hooks
  { ...
  , runMetaHook :: !(Maybe (MetaHook TcM))
  , ...
  }
```

The default `emptyHooks` value sets:

```haskell
runMetaHook = Nothing
```

So installing a hook means updating `HscEnv.hsc_hooks.runMetaHook`.

## `MetaHook`, `MetaRequest`, and `MetaResult`

Module: `GHC.Types.Meta`

Source path: `compiler/GHC/Types/Meta.hs`

Exact definitions:

```haskell
data MetaRequest
  = MetaE  (LHsExpr GhcPs   -> MetaResult)
  | MetaP  (LPat GhcPs      -> MetaResult)
  | MetaT  (LHsType GhcPs   -> MetaResult)
  | MetaD  ([LHsDecl GhcPs] -> MetaResult)
  | MetaAW (Serialized     -> MetaResult)

data MetaResult
  = MetaResE  { unMetaResE  :: LHsExpr GhcPs   }
  | MetaResP  { unMetaResP  :: LPat GhcPs      }
  | MetaResT  { unMetaResT  :: LHsType GhcPs   }
  | MetaResD  { unMetaResD  :: [LHsDecl GhcPs] }
  | MetaResAW { unMetaResAW :: Serialized      }

type MetaHook f = MetaRequest -> LHsExpr GhcTc -> f MetaResult
```

`MetaResult` constructors are not exported. A hook must use the wrapper function
carried by the `MetaRequest` constructor to build the correctly typed result:

```haskell
hook :: MetaHook TcM
hook request spliceExpr =
  case request of
    MetaE wrap -> do
      parsedExpr <- ...
      pure (wrap parsedExpr)
    MetaP wrap -> ...
    MetaT wrap -> ...
    MetaD wrap -> ...
    MetaAW wrap -> ...
```

## Splice Expression Type

The hook receives:

```haskell
LHsExpr GhcTc
```

This is a located, typechecked splice expression. It is the expression producing
the TH value, for example an expression of type `Q Exp`, `Q Pat`, `Q Type`, or
`Q [Dec]`.

Convenience functions in `GHC.Types.Meta` specialize a `MetaHook`:

```haskell
metaRequestE  :: Functor f => MetaHook f -> LHsExpr GhcTc -> f (LHsExpr GhcPs)
metaRequestP  :: Functor f => MetaHook f -> LHsExpr GhcTc -> f (LPat GhcPs)
metaRequestT  :: Functor f => MetaHook f -> LHsExpr GhcTc -> f (LHsType GhcPs)
metaRequestD  :: Functor f => MetaHook f -> LHsExpr GhcTc -> f [LHsDecl GhcPs]
metaRequestAW :: Functor f => MetaHook f -> LHsExpr GhcTc -> f Serialized
```

## Distinguishing Splice Kinds

Match on `MetaRequest`:

- `MetaE`: expression splice, result must be `LHsExpr GhcPs`.
- `MetaP`: pattern splice, result must be `LPat GhcPs`.
- `MetaT`: type splice, result must be `LHsType GhcPs`.
- `MetaD`: declaration splice, result must be `[LHsDecl GhcPs]`.
- `MetaAW`: annotation wrapper evaluation, not one of the basic source splice
  kinds. Treat separately or delegate.

## Current Typechecker Environment

Module: `GHC.Tc.Utils.Monad`

Source path: `compiler/GHC/Tc/Utils/Monad.hs`

Use:

```haskell
getGblEnv :: TcRnIf gbl lcl gbl
getGblEnv = do { Env{..} <- getEnv; return env_gbl }
```

In a `MetaHook TcM`, this specializes to:

```haskell
getGblEnv :: TcM TcGblEnv
```

`TcGblEnv` is exported from `GHC.Tc.Types`.

## Current Module

Module: `GHC.Tc.Types`

`TcGblEnv` exports the field:

```haskell
tcg_mod :: Module
```

In a hook:

```haskell
tcg <- getGblEnv
let modl = tcg_mod tcg
```

For display:

```haskell
moduleNameString (moduleName modl)
```

Relevant imports:

```haskell
import GHC.Tc.Types (TcGblEnv(..))
import GHC.Tc.Utils.Monad (TcM, getGblEnv)
import GHC.Unit.Module (moduleName, moduleNameString)
```

## Source Location of the Splice Expression

The hook argument is located:

```haskell
spliceExpr :: LHsExpr GhcTc
```

Use:

```haskell
getLocA spliceExpr :: SrcSpan
```

`GHC.Tc.Gen.Splice.runMeta'` uses exactly this for splice execution:

```haskell
let expr_span = getLocA expr
setSrcSpan expr_span $ ...
```

`qLocation` in `GHC.Tc.Gen.Splice` uses:

```haskell
getSrcSpanM :: TcRn SrcSpan
```

from `GHC.Tc.Utils.Monad`, then converts `RealSrcSpan` using:

```haskell
srcSpanFile
srcSpanStartLine
srcSpanStartCol
srcSpanEndLine
srcSpanEndCol
```

For a hook, prefer `getLocA spliceExpr`; it is the span of the actual splice
expression passed to the hook. Use `getSrcSpanM` only for the current monadic
source context.

Relevant imports:

```haskell
import GHC.Parser.Annotation (getLocA)
import GHC.Types.SrcLoc
  ( SrcSpan(..), srcSpanFile
  , srcSpanStartLine, srcSpanStartCol
  , srcSpanEndLine, srcSpanEndCol
  )
```

## Pretty-Printing the Splice Expression

Use `ppr` from `GHC.Utils.Outputable`:

```haskell
ppr spliceExpr
```

To render inside `TcM` for a prototype, use the exported `showSDocUnsafe`:

```haskell
let rendered = showSDocUnsafe (ppr spliceExpr)
```

Relevant imports:

```haskell
import GHC.Utils.Outputable (ppr, showSDocUnsafe)
```

## How GHC Dispatches to the Hook

Module: `GHC.Tc.Gen.Splice`

Source path: `compiler/GHC/Tc/Gen/Splice.hs`

The dispatch function is:

```haskell
runMeta :: (MetaHook TcM -> LHsExpr GhcTc -> TcM hs_syn)
        -> LHsExpr GhcTc
        -> TcM hs_syn
runMeta unwrap e = do
    hooks <- getHooks
    case runMetaHook hooks of
        Nothing -> unwrap defaultRunMeta e
        Just h  -> unwrap h e
```

The public splice runners are:

```haskell
runMetaE :: LHsExpr GhcTc -> TcM (LHsExpr GhcPs)
runMetaE = runMeta metaRequestE

runMetaP :: LHsExpr GhcTc -> TcM (LPat GhcPs)
runMetaP = runMeta metaRequestP

runMetaT :: LHsExpr GhcTc -> TcM (LHsType GhcPs)
runMetaT = runMeta metaRequestT

runMetaD :: LHsExpr GhcTc -> TcM [LHsDecl GhcPs]
runMetaD = runMeta metaRequestD
```

`getHooks` comes from `GHC.Driver.Hooks`:

```haskell
class HasHooks m where
    getHooks :: m Hooks
```

`TcM` has a `HasHooks` instance through the typechecker environment.

## Default Splice Evaluation

Module: `GHC.Tc.Gen.Splice`

Source path: `compiler/GHC/Tc/Gen/Splice.hs`

The default implementation is:

```haskell
defaultRunMeta :: MetaHook TcM
defaultRunMeta (MetaE r)
  = fmap r . runMeta' True ppr (runQResult TH.pprint convertToHsExpr runTHExp)
defaultRunMeta (MetaP r)
  = fmap r . runMeta' True ppr (runQResult TH.pprint convertToPat runTHPat)
defaultRunMeta (MetaT r)
  = fmap r . runMeta' True ppr (runQResult TH.pprint convertToHsType runTHType)
defaultRunMeta (MetaD r)
  = fmap r . runMeta' True ppr (runQResult TH.pprint convertToHsDecls runTHDec)
defaultRunMeta (MetaAW r)
  = fmap r . runMeta' False (const empty) (const $ fmap Right . convertAnnotationWrapper)
```

`runMeta'` performs the normal TH path:

1. `recordThSpliceUse`.
2. `failIfErrsM`.
3. Run `spliceRunAction` plugins with `withPlugins`.
4. Desugar the typechecked expression via `initDsTc (dsLExpr expr')`.
5. Compile/link the desugared Core using:

   ```haskell
   GHC.Driver.Main.hscCompileCoreExpr hsc_env src_span ds_expr
   ```

6. Record runtime dependencies with `recordThNeededRuntimeDeps`.
7. Set the source span to `getLocA expr` so `qLocation` reports the splice
   location.
8. Run the appropriate TH action using `runTHExp`, `runTHPat`, `runTHType`, or
   `runTHDec`.
9. Convert the resulting `template-haskell` AST back to parsed GHC syntax using
   `convertToHsExpr`, `convertToPat`, `convertToHsType`, or `convertToHsDecls`.

Important consequence: direct delegation is available to plugins by importing
`defaultRunMeta` from `GHC.Tc.Gen.Splice` and applying it to the original
`MetaRequest` and `LHsExpr GhcTc`.

## Top-Level Typed Expression Splices

`runTopSplice` in `GHC.Tc.Gen.Splice` handles delayed typed top-level splices in
the zonker. It eventually calls:

```haskell
runMetaE zonked_q_expr
```

So typed expression splices still reach `runMetaHook` as `MetaE`.

## Minimal Plugin Installation Example

This is the smallest hook installation shape for GHC 9.8.4:

```haskell
{-# LANGUAGE LambdaCase #-}

module THCross.Plugin (plugin) where

import GHC.Driver.Env.Types (HscEnv(..))
import GHC.Driver.Hooks (Hooks(..))
import GHC.Driver.Plugins
  ( CommandLineOption
  , Plugin(..)
  , defaultPlugin
  , purePlugin
  )
import GHC.Tc.Gen.Splice (defaultRunMeta)
import GHC.Tc.Types (TcGblEnv(..), TcM)
import GHC.Tc.Utils.Monad (getGblEnv)
import GHC.Types.Meta (MetaHook, MetaRequest(..))
import GHC.Unit.Module (moduleName, moduleNameString)

plugin :: Plugin
plugin =
  defaultPlugin
    { driverPlugin = install
    , pluginRecompile = purePlugin
    }

install :: [CommandLineOption] -> HscEnv -> IO HscEnv
install _ hsc_env =
  let hooks0 = hsc_hooks hsc_env
      hooks1 = hooks0 { runMetaHook = Just thCrossHook }
  in pure hsc_env { hsc_hooks = hooks1 }

thCrossHook :: MetaHook TcM
thCrossHook request spliceExpr = do
  tcg <- getGblEnv
  let modText = moduleNameString (moduleName (tcg_mod tcg))
  -- log/use modText, request, and spliceExpr here
  defaultRunMeta request spliceExpr
```

For logging, add:

```haskell
import GHC.Driver.DynFlags (getDynFlags)
import GHC.Parser.Annotation (getLocA)
import GHC.Tc.Utils.Monad (liftIO)
import GHC.Utils.Outputable (ppr, showSDocUnsafe)
```

and inside the hook:

```haskell
let kindText = case request of
      MetaE{}  -> "expression"
      MetaP{}  -> "pattern"
      MetaT{}  -> "type"
      MetaD{}  -> "declaration"
      MetaAW{} -> "annotation-wrapper"
let spanText = showSDocUnsafe (ppr (getLocA spliceExpr))
let exprText = showSDocUnsafe (ppr spliceExpr)
liftIO $ putStrLn ("module: " <> modText)
liftIO $ putStrLn ("kind: " <> kindText)
liftIO $ putStrLn ("location: " <> spanText)
liftIO $ putStrLn ("expression: " <> exprText)
```

## Practical Notes for the Prototype

- The hook result must be `GhcPs`, not `GhcRn` or `GhcTc`.
- Do not transfer `GhcPs` between host and cross processes. Parse textual
  fragments locally in the cross GHC process and return local `GhcPs`.
- Delegate `MetaAW` to `defaultRunMeta` for the MVP unless annotation support is
  explicitly needed.
- For expression-only proof of concept, match `MetaE wrap` and return
  `wrap parsedExpr`; delegate or reject all other constructors.
