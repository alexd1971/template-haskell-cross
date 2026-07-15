# Template Haskell `Q` Effects

Target: GHC 9.8.4.

This document classifies Template Haskell `Q` operations for the prototype where
the host worker evaluates a splice and sends only textual generated Haskell back
to the cross-side plugin.

## Source Locations

Relevant GHC 9.8.4 source files:

| Area | Source path | Relevant definitions |
| --- | --- | --- |
| Public `Q` API | `libraries/template-haskell/Language/Haskell/TH/Syntax.hs` | `class Quasi`, `newtype Q`, `reportWarning`, `reportError`, `recover`, `runIO`, `addDependentFile`, `addTempFile`, `addTopDecls`, `addForeignFile`, `addForeignFilePath`, `addModFinalizer`, `addCorePlugin`, `getQ`, `putQ` |
| GHC implementation | `compiler/GHC/Tc/Gen/Splice.hs` | `instance TH.Quasi TcM`, `qAddDependentFile`, `qAddTempFile`, `qAddTopDecls`, `qAddForeignFilePath`, `qAddModFinalizer`, `qAddCorePlugin`, `qGetQ`, `qPutQ`, `runRemoteModFinalizers`, `handleTHMessage` |
| Compiler state | `compiler/GHC/Tc/Types.hs` | `TcGblEnv` fields `tcg_dependent_files`, `tcg_th_topdecls`, `tcg_th_foreign_files`, `tcg_th_modfinalizers`, `tcg_th_coreplugins`, `tcg_th_state` |

Exact GHC 9.8.4 details:

| Item | Location |
| --- | --- |
| `Quasi` methods | `Language/Haskell/TH/Syntax.hs`, around lines 94-141 |
| Public wrappers | `Language/Haskell/TH/Syntax.hs`, around lines 479, 494, 761, 796-882 |
| `TcM` `Quasi` instance | `GHC/Tc/Gen/Splice.hs`, around lines 1382-1501 |
| Remote TH request forwarding | `GHC/Tc/Gen/Splice.hs`, around lines 1816-1839 |
| `TcGblEnv` TH fields | `GHC/Tc/Types.hs`, around lines 557-576 |

## Key Observation

Returning only the primary generated Haskell fragment preserves only this part:

```text
Q result -> TH AST -> textual Haskell -> cross parser -> GhcPs AST
```

It does not automatically preserve additional effects recorded in the host GHC
session, such as dependency files, extra declarations, foreign files, module
finalizers, diagnostics, or core plugins.

For correctness, every effect that changes GHC compilation state must either be:

1. represented in the worker response and replayed by the cross-side plugin;
2. intentionally treated as host-only;
3. explicitly unsupported.

## Classification

| Operation | GHC 9.8.4 behavior | Prototype classification | Recommendation |
| --- | --- | --- | --- |
| `addDependentFile` | `qAddDependentFile` prepends the path to `tcg_dependent_files`. | Forwarded to cross GHC in the prototype. | The worker response includes `dependentFiles :: [FilePath]`; the cross-side plugin appends them to `tcg_dependent_files`. |
| `addTempFile` | `qAddTempFile` allocates a GHC-session temp file through `newTempName`. | Host-only effect, covered by smoke test. | Do not replay temp file allocation directly. If the file is later passed to `addForeignFilePath` or `addDependentFile`, propagate that higher-level effect. |
| `addTopDecls` | Converts TH `Dec`s to `GhcPs` declarations and prepends them to `tcg_th_topdecls`; also tracks exact top names. | Partially forwarded through Strategy A. | The worker response includes textual `addedTopDecls`; the cross-side plugin parses and appends them to `tcg_th_topdecls`. `AnnD` is covered by same-GHC-version annotation-wrapper forwarding. Value-binding visibility and `tcg_th_topnames` semantics need more investigation. |
| `addForeignFile` | Deprecated wrapper around foreign source emission. | Must be forwarded through `addForeignFilePath` or unsupported. | Treat via `addForeignSource`/`addForeignFilePath`. Direct string source emission is still unsupported in MVP. |
| `addForeignFilePath` | `qAddForeignFilePath` prepends `(ForeignSrcLang, FilePath)` to `tcg_th_foreign_files`. | Forwarded to cross GHC in the prototype. | The worker response includes `foreignFiles`; the cross-side plugin appends them to `tcg_th_foreign_files`, so the target-side build owns compilation/linking. |
| `addCorePlugin` | Validates the plugin is not from the current home unit and prepends the module name to `tcg_th_coreplugins`. | Must be forwarded to cross GHC. | Unsupported in MVP. Later replay on the cross-side compilation session; plugin availability must be checked in the cross compiler environment. |
| `addModFinalizer` | Stores a finalizer reference for later module-finalizer execution with the local environment. | Must be modeled explicitly or unsupported. | Unsupported in MVP. Host execution may run finalizers, but their resulting diagnostics/dependencies/state changes are not automatically visible to cross GHC. |
| `reportWarning` | `qReport False` adds a diagnostic and continues. GHC 9.8.4 represents it as `TcRnTHError (ReportCustomQuasiError False message)`. | Forwarded to cross GHC in the prototype. | The worker response includes this TH diagnostic; the cross-side plugin replays it with `addDiagnostic`. |
| `reportError` | `qReport True` adds an error; the splice may continue unless it fails. GHC 9.8.4 represents it as `TcRnTHError (ReportCustomQuasiError True message)`. | Partially forwarded. | The protocol can carry this TH diagnostic and the cross-side plugin replays it with `addErr`. If host GHC fails before a splice result is captured, the worker still returns a worker error string. |
| `recover` | `qRecover` uses `tryTcDiscardingErrs`; recovered errors are discarded if the recovery branch is used. | Safe automatically inside host evaluation, covered by integration test. | No replay needed for `recover` itself. Effects produced by the branch that actually runs still need their own classification. |
| `getQ` | Reads module-local TH state from `tcg_th_state`. | Host-local, safe for host-evaluated splices in one module load, covered by integration test. | No cross replay needed while all splices in the module are evaluated by the host worker. Document as unsupported for mixed host/cross TH execution. |
| `putQ` | Writes module-local TH state into `tcg_th_state`. | Host-local, safe for host-evaluated splices in one module load, covered by integration test. | Same as `getQ`. Whole-module host expansion preserves ordering-dependent `Q` state for captured results. |
| `runIO` | Runs arbitrary `IO` in the host process. | Host-only effect, covered by integration test. | The generated fragment reflects the returned value, but external side effects are not replayed. Users must call `addDependentFile` for file dependencies. Target-only IO assumptions are unsupported. |

## MVP Policy

The current MVP should support:

```text
primary generated Haskell fragment
reportError as replayed diagnostic when the host worker captures a splice result
recover behavior inside host execution
getQ/putQ inside one whole-module host load
runIO execution on the host
addTempFile allocation and use on the host
addForeignFilePath propagation to the cross GHC session
addTopDecls smoke propagation to the cross GHC session
```

The current MVP should explicitly not support:

```text
addForeignFile direct source emission
addCorePlugin
addModFinalizer
complete diagnostic replay
arbitrary Q effect replay
```

Implemented in the prototype:

```text
addDependentFile propagation
addForeignFilePath propagation
addTopDecls smoke propagation
reportWarning/reportError diagnostics propagation
runIO host execution
addTempFile host execution
recover host semantics
getQ/putQ host module state
```

`addDependentFile` and `addForeignFilePath` directly affect build correctness and
have simple replay shapes.

## Suggested Response Extensions

For `addDependentFile`:

```json
{
  "requestId": "123",
  "status": "ok",
  "generatedHaskell": "42",
  "annotationWrapper": null,
  "dependentFiles": [
    "/absolute/path/schema.json"
  ],
  "foreignFiles": [
    {
      "language": "c",
      "path": "/absolute/path/generated.c"
    }
  ],
  "addedTopDecls": "foreign import ccall \"probe\" probe :: IO Int\n"
}
```

Later response fields:

```json
{
  "warnings": [
    {
      "message": "...",
      "sourceSpan": null
    }
  ],
  "corePlugins": [
    "My.Plugin"
  ],
  "addedTopDecls": "..."
}
```

## `addTopDecls` Investigation

GHC 9.8.4 public API:

```haskell
addTopDecls :: [Dec] -> Q ()
```

Source:

- `libraries/template-haskell/Language/Haskell/TH/Syntax.hs`, around line 805
- `compiler/GHC/Tc/Gen/Splice.hs`, `instance TH.Quasi TcM`, `qAddTopDecls`
- `compiler/GHC/Tc/Module.hs`, `tc_rn_src_decls`
- `compiler/GHC/Rename/Env.hs`, `lookupLocalExactGRE`
- `compiler/GHC/Tc/Types.hs`, `TcGblEnv` fields `tcg_th_topdecls` and
  `tcg_th_topnames`

GHC 9.8.4 implementation shape:

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

GHC 9.8.4 consumer path:

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
- Textual transport is still possible, but replay must preserve declaration
  ordering and staging. Simply appending declarations to a side list may be too
  late if later declarations in the same group depend on them.
- `tcg_th_topnames` matters for exact-name tracking. Replaying only text through
  `tcg_th_topdecls` does not reproduce host exact names. The successful
  exact-name declaration-splice test therefore uses Strategy B grafting.

The prototype now uses a hybrid implementation: Strategy A for non-declaration
splices, and Strategy B for declaration splices.

### Strategy A: replay through `tcg_th_topdecls`

Conceptual flow:

```text
host splice executes
  -> host qAddTopDecls converts [Dec] to [LHsDecl GhcPs]
  -> worker captures newly added declarations
  -> worker pretty-prints them as Haskell text
  -> cross plugin parses them with cross GHC
  -> cross plugin appends them to cross tcg_th_topdecls
```

Why it is attractive:

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
  additions. The prototype does this by temporarily clearing `tcg_th_topdecls`
  around one host splice evaluation, reading the declarations produced by that
  splice, and then restoring `addedTopDecls <> previousTopDecls`.
- Preserve GHC's prepend order. GHC uses `ds ++ topds`, so the captured wire
  order must match the order GHC would later consume.
- For non-declaration splices, parse declaration fragments on the cross side and
  update `tcg_th_topdecls :: TcRef [LHsDecl GhcPs]`. The prototype does this
  through the same declaration-fragment parser used for declaration splice
  results.
- For declaration splices, graft the added declarations into the `MetaD` result
  instead. This avoids losing the useful same-group relationship between the
  declaration-splice result and declarations added by `addTopDecls`.
- Decide what to do with `tcg_th_topnames :: TcRef NameSet`. The current text
  replay path does not transport exact `Name`s. This is acceptable for the
  tested subset, but it is not full `addTopDecls` semantics.

Prototype validation:

The prototype implements Strategy A far enough to pass native-GHC-valid tests
where expression splices call `addTopDecls`. The host worker captures the added
declarations, sends them as `addedTopDecls`, and the cross-side plugin logs
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
  Strategy B grafting for `MetaD`;
- expected failure: invalid declaration passed to `addTopDecls`;
- expected failure: declaration added through `addTopDecls` contains a normal
  typechecking error.
- expected failure: unsupported `foreign import prim` shape adapted from
  upstream `T10638`.
- native GHC control cases for the same success/failure fixtures.

Annotation-wrapper caveat:

- Replayed `AnnD` declarations trigger a later `MetaAW` request. The prototype
  handles that request by returning a binary-encoded GHC `Serialized` payload
  captured by the host worker.
- This is intentionally same-GHC-version support. It is not a stable textual
  cross-version wire format like `generatedHaskell` or `addedTopDecls`.

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
  so it is not a stable acceptance test for this prototype yet.

### Strategy B: graft into declaration splice expansion

Conceptual flow:

```text
host declaration splice executes
  -> host captures primary declaration-splice result
  -> host also captures addTopDecls declarations produced during that splice
  -> worker returns the primary declaration fragment and addedTopDecls fragment
  -> cross plugin parses both fragments
  -> runMetaHook returns combined [LHsDecl GhcPs] from MetaD
```

Why it is attractive:

- It avoids relying on direct mutation of `tcg_th_topdecls` on the cross side.
- Returned declarations go through the normal `MetaD` result path, so GHC sees
  them as part of the declaration splice expansion.
- It is easier to reason about for top-level declaration splices, because the
  hook already returns `[LHsDecl GhcPs]` at the splice point.

Required implementation details:

- Restrict the first prototype to `MetaD`. Expression/type/pattern splices that
  call `addTopDecls` would remain unsupported under this strategy.
- Capture the delta of `tcg_th_topdecls` produced while evaluating the
  declaration splice.
- Decide ordering between the primary declaration-splice result and declarations
  added through `addTopDecls`. The safest first approximation is to preserve
  GHC's observed order by comparing with native `-ddump-splices` output for
  examples.
- Pretty-print and reparse the combined declaration fragment on the cross side.

Main limitation:

This does not implement the full `addTopDecls` API. It only handles the subset
where `addTopDecls` is called during a declaration splice and the added
declarations can be safely represented as part of that splice's returned
declaration list.

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
name introduced by `addTopDecls`. Plain textual replay through
`tcg_th_topdecls` loses that exact-name relationship; grafting both fragments
into one `MetaD` result preserves enough source-level structure for this case.

### Strategy Status

| Criterion | Strategy A: `tcg_th_topdecls` replay | Strategy B: `MetaD` grafting |
| --- | --- | --- |
| Current role | Primary path for non-declaration splices | Primary path for declaration splices |
| Scope | Potentially full `addTopDecls` semantics | Declaration splices only |
| Cross-side mechanism | Mutate GHC TH state refs | Return larger `MetaD` result |
| Ordering risk | Reduced for native-GHC-valid expression-splice cases now covered by tests | Lower for declaration splices, but narrower semantics |
| `tcg_th_topnames` risk | Confirmed limitation for text replay; exact names are not transported | May be avoided if normal declaration splice path handles names |
| Expression-splice support | Possible | Not supported initially |
| Prototype status | Implemented for a tested subset | Implemented for a tested subset |
| Semantic completeness | Better target | Partial but more controlled |

Recommendation:

Use a hybrid implementation:

- Strategy A remains necessary for expression splices, including typed
  expression splices routed through `MetaE`, because they cannot return a larger
  declaration-splice result.
- Strategy B is preferable for declaration splices because it avoids a confirmed
  exact-name loss when the declaration-splice result references names introduced
  by `addTopDecls`.

The current implementation is still subset support, not full semantic support.
Before declaring full support, add native-GHC-valid tests for type/pattern
splice contexts and decide whether any remaining cases require explicit
`tcg_th_topnames` protocol support.

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

`addModFinalizer` is hard to support with a textual wire format because the
effect is a delayed `Q ()` action, not a generated Haskell fragment. Supporting
it requires host-side execution plus explicit forwarding of any finalizer
effects that should be visible to the cross compilation.
