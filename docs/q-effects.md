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
| `addTopDecls` | Converts TH `Dec`s to `GhcPs` declarations and prepends them to `tcg_th_topdecls`; also tracks exact top names. | Must be forwarded or unsupported. | Unsupported in MVP. Later, capture the added declarations as textual Haskell and replay/graft them into the cross-side declaration group. |
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
```

The current MVP should explicitly not support:

```text
addTopDecls
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
  "dependentFiles": [
    "/absolute/path/schema.json"
  ],
  "foreignFiles": [
    {
      "language": "c",
      "path": "/absolute/path/generated.c"
    }
  ]
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
