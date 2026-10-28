# Template Haskell `Q` Effects

This document classifies Template Haskell `Q` operations for the implementation
where the host worker evaluates a splice and sends raw Template Haskell AST
payloads back to the cross-side plugin.

Source descriptions refer to unpatched GHC 9.10.3; worker-specific additions
are identified explicitly. These compiler internals can change between GHC
versions. See [GHC version support](ghc-version-support.md) for the validated
compiler profiles.

## Source Locations

Relevant GHC 9.10.3 source files:

| Area | Source path | Relevant definitions |
| --- | --- | --- |
| Public `Q` API | [`Language/Haskell/TH/Syntax.hs`](https://github.com/ghc/ghc/blob/ghc-9.10.3-release/libraries/template-haskell/Language/Haskell/TH/Syntax.hs) | `class Quasi`, `newtype Q`, `reportWarning`, `reportError`, `recover`, `runIO`, `addDependentFile`, `addTempFile`, `addTopDecls`, `addForeignFile`, `addForeignSource`, `addForeignFilePath`, `addModFinalizer`, `addCorePlugin`, `getQ`, `putQ` |
| GHC implementation | [`GHC/Tc/Gen/Splice.hs`](https://github.com/ghc/ghc/blob/ghc-9.10.3-release/compiler/GHC/Tc/Gen/Splice.hs) | `instance TH.Quasi TcM`, `qAddDependentFile`, `qAddTempFile`, `qAddTopDecls`, `qAddForeignFilePath`, `qAddModFinalizer`, `qAddCorePlugin`, `qGetQ`, `qPutQ`, `runRemoteModFinalizers`, `handleTHMessage` |
| Compiler state | [`GHC/Tc/Types.hs`](https://github.com/ghc/ghc/blob/ghc-9.10.3-release/compiler/GHC/Tc/Types.hs) | `TcGblEnv` fields `tcg_dependent_files`, `tcg_th_topdecls`, `tcg_th_topnames`, `tcg_th_foreign_files`, `tcg_th_modfinalizers`, `tcg_th_coreplugins`, `tcg_th_state` |
| Declaration groups | [`GHC/Tc/Module.hs`](https://github.com/ghc/ghc/blob/ghc-9.10.3-release/compiler/GHC/Tc/Module.hs) | `tc_rn_src_decls` |
| Exact-name lookup | [`GHC/Rename/Env.hs`](https://github.com/ghc/ghc/blob/ghc-9.10.3-release/compiler/GHC/Rename/Env.hs) | `lookupLocalExactGRE` |

## Key Observation

Returning the primary raw Template Haskell payload preserves only this part:

```text
Q result -> TH AST -> binary protocol -> cross-side TH-to-GHC conversion
```

It does not automatically preserve additional effects recorded in the host GHC
session, such as dependency files, extra declarations, foreign files, module
finalizers, diagnostics, or core plugins.

For correctness, every effect that changes GHC compilation state must either be:

1. represented in the worker response and replayed by the cross-side plugin;
2. intentionally treated as host-only;
3. explicitly unsupported.

## Classification

| Operation | GHC 9.10.3 behavior | Current classification | Recommendation |
| --- | --- | --- | --- |
| `addDependentFile` | `qAddDependentFile` prepends the path to `tcg_dependent_files`. | Forwarded to cross GHC. | The worker response includes `dependentFiles :: [FilePath]`; the cross-side plugin appends them to `tcg_dependent_files`. |
| `addTempFile` | `qAddTempFile` allocates a GHC-session temp file through `newTempName`. | Host-only effect, covered by smoke test. | Do not replay temp file allocation directly. If the file is later passed to `addForeignFilePath` or `addDependentFile`, propagate that higher-level effect. |
| `addTopDecls` | Converts TH `Dec`s to `GhcPs` declarations and prepends them to `tcg_th_topdecls`; also tracks exact top names. | Forwarded through the raw TH protocol. | The patched host GHC records raw `[TH.Dec]` values passed to `qAddTopDecls`. The worker response includes those declarations; the cross-side plugin converts them locally and appends them to `tcg_th_topdecls`, or grafts them into a declaration-splice result. `AnnD` is covered by same-GHC-version annotation-wrapper forwarding. |
| `addForeignFile` / `addForeignSource` | `addForeignFile` is a deprecated alias for `addForeignSource`; `addForeignSource` writes source text to a temp file and calls `addForeignFilePath`. | Forwarded through existing `addForeignFilePath` propagation. | Covered by an integration test. The generated temp file path is host-side but is passed to cross GHC as a foreign file path. |
| `addForeignFilePath` | `qAddForeignFilePath` prepends `(ForeignSrcLang, FilePath)` to `tcg_th_foreign_files`. | Forwarded to cross GHC. | The worker response includes `foreignFiles`; the cross-side plugin appends them to `tcg_th_foreign_files`, so the target-side build owns compilation/linking. |
| `addCorePlugin` | Validates the plugin is not from the current home unit and prepends the module name to `tcg_th_coreplugins`. | Unsupported; cross-side replay is not implemented. | Future protocol can carry `corePlugins :: [String]`; cross-side replay must check that the plugin is available to the cross compiler environment. |
| `addModFinalizer` | Stores a finalizer reference for later module-finalizer execution with the local environment. | Unsupported; cross-side finalizer timing and effects are not modeled. | Unsupported in the current implementation. Host execution may run finalizers, but their resulting diagnostics/dependencies/state changes are not automatically visible to cross GHC. |
| `reportWarning` | `qReport False` adds a diagnostic and continues. GHC 9.10.3 represents it as `TcRnTHError (ReportCustomQuasiError False message)`. | Forwarded to cross GHC. | The worker response includes this TH diagnostic; the cross-side plugin replays it with `addDiagnostic`. |
| `reportError` | `qReport True` adds an error; the splice may continue unless it fails. GHC 9.10.3 represents it as `TcRnTHError (ReportCustomQuasiError True message)`. | Partially forwarded. | The protocol can carry this TH diagnostic and the cross-side plugin replays it with `addErr`. If host GHC fails before a splice result is captured, the worker still returns a worker error string. |
| `recover` | `qRecover` uses `tryTcDiscardingErrs`; recovered errors are discarded if the recovery branch is used. | Safe automatically inside host evaluation, covered by integration test. | No replay needed for `recover` itself. Effects produced by the branch that actually runs still need their own classification. |
| `getQ` | Reads module-local TH state from `tcg_th_state`. | Host-local, safe for host-evaluated splices in one module load, covered by integration test. | No cross replay needed while all splices in the module are evaluated by the host worker. Document as unsupported for mixed host/cross TH execution. |
| `putQ` | Writes module-local TH state into `tcg_th_state`. | Host-local, safe for host-evaluated splices in one module load, covered by integration test. | Same as `getQ`. Whole-module host expansion preserves ordering-dependent `Q` state for captured results. |
| `runIO` | Runs arbitrary `IO` in the host process. | Host-only effect, covered by integration test. | The raw TH result reflects the returned value, but external side effects are not replayed. Users must call `addDependentFile` for file dependencies. Target-only IO assumptions are unsupported. |

## Current Support

The implementation transfers the primary raw TH payload and handles these
effects:

```text
addDependentFile propagation
addForeignSource/addForeignFile propagation through generated foreign file paths
addForeignFilePath propagation
addTopDecls propagation for the tested splice contexts described below
reportWarning/reportError diagnostics propagation
runIO host execution
addTempFile host execution
recover host semantics
getQ/putQ host module state
```

`addCorePlugin` and `addModFinalizer` are unsupported. Complete diagnostic
replay and arbitrary `Q` effect replay are not implemented. Unsupported uses
are not always rejected: native execution can produce effects that are never
applied to the cross compilation.

`addDependentFile` and `addForeignFilePath` directly affect build correctness and
have simple replay shapes.

## Response Fields

Current binary response fields carry:

- raw TH payload for the primary splice result;
- `dependentFiles :: [FilePath]`;
- `foreignFiles :: [SpliceForeignFile]`;
- `addedTopDecls :: [TH.Dec]`;
- `diagnostics :: [SpliceDiagnostic]`;
- optional same-GHC-version annotation-wrapper bytes.

## `addTopDecls` Handling

Template Haskell public API:

```haskell
addTopDecls :: [Dec] -> Q ()
```

Source:

- `libraries/template-haskell/Language/Haskell/TH/Syntax.hs`
- `compiler/GHC/Tc/Gen/Splice.hs`, `instance TH.Quasi TcM`, `qAddTopDecls`
- `compiler/GHC/Tc/Module.hs`, `tc_rn_src_decls`
- `compiler/GHC/Rename/Env.hs`, `lookupLocalExactGRE`
- `compiler/GHC/Tc/Types.hs`, `TcGblEnv` fields `tcg_th_topdecls` and
  `tcg_th_topnames`

GHC 9.10.3 implementation shape:

```haskell
qAddTopDecls thds = do
  l <- getSrcSpanM
  th_origin <- getThSpliceOrigin
  let either_hval = convertToHsDecls th_origin l thds
  ds <- case either_hval of
          Left exn -> failWithTc ...
          Right ds -> return ds
  mapM_ (checkTopDecl . unLoc) ds
  th_topdecls_var <- fmap tcg_th_topdecls getGblEnv
  updTcRef th_topdecls_var (\topds -> ds ++ topds)
```

`checkTopDecl` accepts only:

- value declarations, and records exact binders in `tcg_th_topnames`;
- signatures;
- annotations;
- foreign imports, and records the imported exact binder.

Other declaration forms are rejected with `AddTopDeclsError (InvalidTopDecl d)`.
Names recorded in `tcg_th_topnames` must be exact names; non-exact names produce
`THNameError (NonExactName name)`.

Relevant compiler state:

```haskell
tcg_th_topdecls :: TcRef [LHsDecl GhcPs]
tcg_th_topnames :: TcRef NameSet
```

GHC 9.10.3 consumer path:

- `compiler/GHC/Tc/Module.hs`, `tc_rn_src_decls`
- after `rnTopSrcDecls first_group`, GHC reads `tcg_th_topdecls`;
- it immediately clears the ref with `writeTcRef th_topdecls_var []`;
- it calls `findSplice th_ds` and rejects declaration splices inside
  declarations added by `addTopDecls`;
- it renames the added declarations with `rnTopSrcDecls th_group`;
- it appends them to the current renamed declaration group with
  `appendGroups rn_decls th_rn_decls`;
- the combined group then goes through `tcTopSrcDecls rn_decls`.

This confirms that replaying into `tcg_th_topdecls` from `runMetaHook` is not
too late for the current splice group: GHC drains the ref after the splice has
run and before typechecking the combined group.

Exact-name lookup path:

- `compiler/GHC/Rename/Env.hs`, `lookupLocalExactGRE`
- if an exact `Name` is not found in the normal global/local reader
  environments, GHC checks `tcg_th_topnames`;
- this only helps references that are already exact names;
- ordinary source references written later as `RdrName`s are not made visible
  solely by `tcg_th_topnames`.

Why this is harder than `addDependentFile` or `addForeignFilePath`:

- `addTopDecls` changes the declarations typechecked with the current
  declaration group, not just module metadata.
- The host worker can observe the converted `GhcPs` declarations, but the cross
  compiler needs equivalent local `GhcPs` declarations inserted at the right
  declaration-group point.
- Raw replay must still preserve declaration ordering and staging. Simply
  appending declarations to a side list may be too late if later declarations in
  the same group depend on them.
- `tcg_th_topnames` matters for exact-name tracking. The cross-side plugin
  mirrors exact binders for replayed `addTopDecls`. For declaration splices,
  it combines the added declarations and primary result into one `MetaD`
  expansion.

The current code replays non-declaration-splice additions through
`tcg_th_topdecls` and combines declaration-splice additions with the `MetaD`
result.

### Non-declaration splices: replay through `tcg_th_topdecls`

Conceptual flow:

```text
host splice executes
  -> patched host qAddTopDecls records raw [TH.Dec]
  -> worker captures newly added raw declarations
  -> cross plugin converts them with cross GHC
  -> cross plugin appends them to cross tcg_th_topdecls
```

Properties:

- It mirrors GHC's own state shape: `qAddTopDecls` ultimately updates
  `tcg_th_topdecls`.
- It can, in principle, work for expression splices as well as declaration
  splices, because `addTopDecls` can be called from any `Q` action that has
  access to the operation.
- It keeps `addTopDecls` represented as a side effect, separately from the
  primary splice result.

Required implementation details:

- Capture a delta, not the whole `tcg_th_topdecls`, for each splice. The field is
  cumulative, so sending the whole list for every splice would duplicate earlier
  additions. The implementation does this by temporarily clearing `tcg_th_topdecls`
  around one host splice evaluation, reading the declarations produced by that
  splice, and then restoring `addedTopDecls <> previousTopDecls`.
- Preserve GHC's prepend order. GHC uses `ds ++ topds`, so the captured wire
  order must match the order GHC would later consume.
- For non-declaration splices, convert raw `TH.Dec` values on the cross side and
  update `tcg_th_topdecls :: TcRef [LHsDecl GhcPs]`.
- For declaration splices, graft the added declarations into the `MetaD` result
  instead. This avoids losing the useful same-group relationship between the
  declaration-splice result and declarations added by `addTopDecls`.
- Mirror `tcg_th_topnames :: TcRef NameSet` for replayed `addTopDecls` binders.
  The cross-side plugin repeats GHC's top-declaration check and records exact
  binders in this ref.

Current validation:

Replay through `tcg_th_topdecls` passes native-GHC-valid tests where expression
splices call `addTopDecls`. The host worker captures the added declarations,
sends them as `addedTopDecls`, and the cross-side plugin logs
`th-cross: added top decls N` after replay.

Integration coverage now includes:

- success: expression splice adds a supported foreign import declaration;
- success: one splice adds multiple declarations;
- success: multiple splices in one module each call `addTopDecls`;
- success: declarations added through `addTopDecls` can refer to source
  declarations from the same pre-splice group;
- success: annotation declarations (`AnnD`) added through `addTopDecls`, using
  same-GHC-version `MetaAW`/annotation-wrapper forwarding;
- success: top-level typed expression splice using `unsafeCodeCoerce`, confirming
  GHC 9.8.4 routes this case through the existing `MetaE` hook path;
- success: declaration splice where the returned declarations reference a
  binding introduced through `addTopDecls` with an exact `newName`; this uses
  grafting into the `MetaD` result;
- expected failure: invalid declaration passed to `addTopDecls`;
- expected failure: declaration added through `addTopDecls` contains a normal
  typechecking error.
- expected failure: unsupported `foreign import prim` shape adapted from
  upstream `T10638`.
- native GHC control cases for the same success/failure fixtures.

Annotation-wrapper caveat:

- Replayed `AnnD` declarations trigger a later `MetaAW` request. The implementation
  handles that request by returning a binary-encoded GHC `Serialized` payload
  captured by the host worker.
- This is intentionally same-GHC-version support, like the raw TH payloads used
  for normal splice results and `addedTopDecls`.

Important confirmed limitation:

The tests intentionally do not use an ordinary later source reference like:

```haskell
foo = generatedByAddTopDecls
```

That shape is not native-GHC-valid for the tested TH quote style: `addTopDecls`
records exact names, and `lookupLocalExactGRE` only helps when the later
reference is already an exact `Name`. A normal source `RdrName` is not resolved
through `tcg_th_topnames`. This means failing such a test would not demonstrate a
plugin regression unless a corresponding native GHC compilation succeeds.

The primary smoke fixture is intentionally based on a native-GHC-valid shape
accepted by GHC 9.8.4:

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}

module AddTopDeclsExpr where

import Language.Haskell.TH
import Language.Haskell.TH.Syntax (addTopDecls)

marker :: ()
marker =
  $( do
       generatedDecls <-
         [d|
           foreign import ccall "th_cross_add_top_decls_probe"
             th_cross_add_top_decls_probe :: IO Int
           |]
       addTopDecls generatedDecls
       [| () |]
   )
```

Relevant upstream GHC 9.8.4 tests found in `testsuite/tests/th`:

- `TH_invalid_add_top_decl.hs`: invalid declaration passed to `addTopDecls`
  should report `AddTopDeclsError`.
- `T10638.hs`: compile-fail tests for unsupported foreign import shapes.
- `T11680.hs`: compile-fail/suggestion tests involving names introduced by
  `addTopDecls`.
- `T14627.hs` and `T18740c.hs`: compile-fail tests proving declarations added
  through `addTopDecls` are typechecked.
- `T13587.hs` / `T13587A.hs`: `addTopDecls` with foreign imports and typed
  splices. In the GHC 9.8.4 testsuite this test is marked `expect_broken(13587)`,
  so it is not a stable acceptance test for this implementation yet.

### Declaration splices: combine added declarations with the splice result

Conceptual flow:

```text
host declaration splice executes
  -> host captures primary declaration-splice TH result
  -> host also captures raw TH.Dec values passed to addTopDecls
  -> worker returns both raw payloads
  -> cross plugin converts both payloads with convertToHsDecls
  -> runMetaHook returns combined [LHsDecl GhcPs] from MetaD
```

Properties:

- It avoids relying on direct mutation of `tcg_th_topdecls` on the cross side.
- Returned declarations go through the normal `MetaD` result path, so GHC sees
  them as part of the declaration splice expansion.
- It is easier to reason about for top-level declaration splices, because the
  hook already returns `[LHsDecl GhcPs]` at the splice point.

Required implementation details:

- Capture the raw delta of `addTopDecls` produced while evaluating the
  declaration splice. The current patched GHC exposes this through an additional
  `TcGblEnv` ref populated from `qAddTopDecls`.
- Decide ordering between the primary declaration-splice result and declarations
  added through `addTopDecls`. The safest first approximation is to preserve
  GHC's observed order by comparing with native `-ddump-splices` output for
  examples.
- Convert both raw TH payloads on the cross side. Do not pretty-print and
  reparse; that loses exact names.

Main limitation:

For non-declaration splices, raw `addTopDecls` payloads are replayed by
appending converted declarations to cross-side `tcg_th_topdecls`.

Implemented validation shape:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Example where

$( do
     generatedName <- newName "generated"
     let fooName = mkName "foo"
     addTopDecls [ValD (VarP generatedName) (NormalB (LitE (IntegerL 42))) []]
     pure [ValD (VarP fooName) (NormalB (VarE generatedName)) []]
 )
```

This is native-GHC-valid because the returned declaration references the exact
name introduced by `addTopDecls`. Raw replay preserves that relationship because
both the added declarations and the splice result carry the same `NameU`.

### Replay Mechanisms

| Criterion | Replay through `tcg_th_topdecls` | Combine with the `MetaD` result |
| --- | --- | --- |
| Current role | Primary path for non-declaration splices | Primary path for declaration splices |
| Scope | Potentially full `addTopDecls` semantics | Declaration splices only |
| Cross-side mechanism | Mutate GHC TH state refs | Return larger `MetaD` result |
| Ordering risk | Reduced for native-GHC-valid expression-splice cases now covered by tests | Lower for declaration splices, but narrower semantics |
| `tcg_th_topnames` risk | Cross-side replay mirrors exact binders into `tcg_th_topnames` | Normal declaration splice path handles names directly |
| Expression-splice support | Implemented for tested cases | Not applicable |
| Current status | Implemented for a tested subset | Implemented for a tested subset |
| Semantic completeness | Limited to tested contexts | Limited to declaration splices |

Both mechanisms are needed:

- Replay through `tcg_th_topdecls` remains necessary for expression splices,
  including typed expression splices routed through `MetaE`, because they
  cannot return a larger declaration-splice result.
- Combining additions with the `MetaD` result is preferable for declaration
  splices because it avoids a confirmed exact-name loss when the
  declaration-splice result references names introduced by `addTopDecls`.

The current implementation is still subset support, not full semantic support.
Before declaring full support, add native-GHC-valid tests for type and pattern
splice contexts.

## Important Limitations

`runIO` always executes on the build host in this architecture. That is intended
for TH generator code, but it means any IO that assumes target availability is
out of scope.

`getQ` and `putQ` are only safe because the worker evaluates the module through
normal GHC declaration-group ordering. If future code evaluates isolated splice
fragments independently, module-local `Q` state will not be preserved.

`addTempFile` is not a stable wire effect. The temp path is meaningful to the
host GHC session and may be cleaned up by GHC. Any durable consequence must be
represented through another effect, such as `addForeignFilePath`.

## `addForeignSource` / `addForeignFile` Handling

GHC 9.10.3 public API:

```haskell
addForeignFile :: ForeignSrcLang -> String -> Q ()
addForeignSource :: ForeignSrcLang -> String -> Q ()
addForeignFilePath :: ForeignSrcLang -> FilePath -> Q ()
```

Source:

- `libraries/template-haskell/Language/Haskell/TH/Syntax.hs`,
  `addForeignFile`
- `libraries/template-haskell/Language/Haskell/TH/Syntax.hs`,
  `addForeignSource`
- `libraries/template-haskell/Language/Haskell/TH/Syntax.hs`,
  `addForeignFilePath`
- `compiler/GHC/Tc/Gen/Splice.hs`, `qAddForeignFilePath`
- `compiler/GHC/Tc/Types.hs`, `tcg_th_foreign_files`

In GHC 9.10.3, `addForeignFile` is deprecated:

```text
Use 'Language.Haskell.TH.Syntax.addForeignSource' instead
```

and is implemented as:

```haskell
addForeignFile = addForeignSource
```

`addForeignSource` is not a separate compiler-state effect. It reduces source
text emission to temp-file creation plus path registration:

```haskell
path <- addTempFile suffix
runIO (writeFile path src)
addForeignFilePath lang path
```

Then `qAddForeignFilePath` records the path in:

```haskell
tcg_th_foreign_files :: TcRef [(ForeignSrcLang, FilePath)]
```

with:

```haskell
updTcRef var ((lang, fp):)
```

### Current Behavior

The implementation already forwards `tcg_th_foreign_files` through the worker
response as `foreignFiles :: [SpliceForeignFile]`, where each entry contains the
foreign source language and path:

```haskell
SpliceForeignFile
  { spliceForeignFileLang = LangC
  , spliceForeignFilePath = "..."
  }
```

and replays them into cross-side `tcg_th_foreign_files`.

Because `addForeignSource` eventually calls `addForeignFilePath`, it is covered
by the same mechanism. The integration suite includes a smoke test where
host-side TH calls `addForeignSource LangC ...` and the cross-side plugin logs a
replayed `foreign file c ...` entry.

### Support and Limitations

`addForeignSource` and deprecated `addForeignFile` are considered supported to
the same extent as `addForeignFilePath`.

Important caveat:

- the source text is written to a host-side temp file;
- the cross-side GHC receives only the generated file path;
- the file must still exist when cross GHC compiles/links foreign files;
- longer-term builds should ensure these generated files live under a durable
  worker/module build directory, not a temp location that can disappear too
  early.

## `addModFinalizer` Handling

GHC 9.10.3 public API:

```haskell
addModFinalizer :: Q () -> Q ()
```

Source:

- `libraries/template-haskell/Language/Haskell/TH/Syntax.hs`
- `compiler/GHC/Tc/Gen/Splice.hs`, `qAddModFinalizer`
- `compiler/GHC/Tc/Gen/Splice.hs`, `addModFinalizerRef`
- `compiler/GHC/Tc/Gen/Splice.hs`, `runRemoteModFinalizers`
- `compiler/GHC/Tc/Types.hs`, `tcg_th_modfinalizers`

GHC stores module finalizers as delayed `Q ()` actions, not as Haskell source
fragments:

```haskell
tcg_th_modfinalizers :: TcRef [(TcLclEnv, ThModFinalizers)]
```

and:

```haskell
newtype ThModFinalizers = ThModFinalizers [ForeignRef (Q ())]
```

In the `Quasi TcM` instance, `qAddModFinalizer` creates a remote reference to
the `Q ()` action and records it with `addModFinalizerRef`. `addModFinalizerRef`
only works while GHC is collecting finalizers for a running splice; otherwise it
panics with:

```text
addModFinalizer was called when no finalizers were collected
```

Typed splices have an extra staging detail. GHC's note "Collecting modFinalizers
in typed splices" says finalizers are first collected in the local environment
and then moved to the global finalizer list with the current local environment.

### Current Behavior

The current host worker loads the module with native GHC. That means host GHC
may execute module finalizers during the host-side load.

However, this is not a correct cross-side implementation:

- the protocol does not carry finalizer actions;
- the protocol does not carry a post-finalizer effects delta;
- per-splice diagnostics/top declarations are captured before module finalizers
  run;
- dependent/foreign file effects are copied from worker-side `IORef`s that are
  updated during splice capture, not by reading finalizer effects after `load`;
- worker stderr is inherited by the cross GHC process, so a host-side finalizer
  warning might be visible in logs, but that is not the same as replaying a
  cross-side GHC diagnostic.

### Support and Limitations

`addModFinalizer` remains unsupported in the current implementation.

Do not treat host execution of finalizers as support. It is host-only behavior
unless the worker records finalizer-produced effects and the cross-side plugin
replays them explicitly.

Possible future implementation:

1. Let host GHC execute finalizers as part of normal module loading.
2. Capture a module-level post-finalizer effects delta:
   diagnostics, dependent files, foreign files, top declarations, and possibly
   core plugins.
3. Attach those effects to the whole-module expansion cache rather than to one
   arbitrary splice.
4. Replay the module-finalizer effects once on the cross side, after all
   required splice results for the module have been consumed.

This requires careful ordering. Replaying finalizer effects too early could
change normal GHC staging semantics; replaying them per splice would duplicate
effects.

## `addCorePlugin` Handling

GHC 9.10.3 public API:

```haskell
addCorePlugin :: String -> Q ()
```

Source:

- `libraries/template-haskell/Language/Haskell/TH/Syntax.hs`
- `compiler/GHC/Tc/Gen/Splice.hs`, `qAddCorePlugin`
- `compiler/GHC/Tc/Gen/Splice.hs`, `handleTHMessage`, `AddCorePlugin`
- `compiler/GHC/Tc/Types.hs`, `tcg_th_coreplugins`

The public documentation says:

```text
addCorePlugin m has almost the same effect as passing -fplugin=m to ghc
```

with one important restriction: the plugin module must not belong to the current
package, because by the time TH runs it is too late to compile a plugin module
from the same package first.

GHC enforces this restriction in `qAddCorePlugin`:

1. read `HscEnv` with `getTopEnv`;
2. initialize finder options from `DynFlags`;
3. call `findHomeModule` for the requested plugin module name;
4. if the module is found in the home unit, report
   `TcRnTHError (AddInvalidCorePlugin plugin)`;
5. otherwise prepend the plugin string to:

```haskell
tcg_th_coreplugins :: TcRef [String]
```

with:

```haskell
updTcRef th_coreplugins_var (plugin:)
```

### Current Behavior

The current worker does not capture `tcg_th_coreplugins`, and the protocol has
no field for core plugins. If host-side TH calls `addCorePlugin`, native GHC may
record it in the host GHC session, but the cross-side GHC session will not see
that effect.

This is not safe to silently ignore for real builds: a core plugin can change
Core-to-Core optimization or even program semantics.

### Support and Limitations

`addCorePlugin` remains unsupported in the current implementation.

Unlike `addModFinalizer`, this effect would have a simple wire shape:

```haskell
corePlugins :: [String]
```

and cross-side replay would be mechanically similar to:

```haskell
updTcRef (tcg_th_coreplugins tcGblEnv) (plugins <>)
```

However, correctness depends on the plugin being available to the cross compiler
as a compiler plugin, not merely to the host worker. This is especially
important for cross builds:

- the plugin must be build-host executable code loaded by cross GHC;
- it must be present in the cross compiler package environment;
- it must not be confused with target libraries;
- replaying it may make builds depend on a plugin that the original host worker
  happened to find differently.

Recommended future implementation:

1. Add `corePlugins :: [String]` to the worker response or module-level effects.
2. Capture `tcg_th_coreplugins` deltas in the worker.
3. Replay them into cross-side `tcg_th_coreplugins`.
4. Add diagnostics that clearly say the core plugin must be available to the
   cross GHC plugin environment.
5. Add tests only with a separate package/plugin module, not with a plugin from
   the current package, because GHC explicitly rejects that shape.

Until then, a production-facing mode should fail explicitly if the worker
observes a non-empty `tcg_th_coreplugins` delta. The current implementation does not
yet detect that condition.
