# Target-Only Modules and Imports

Historical source references: GHC 9.8.4. The current implementation targets
GHC 9.10.3, so line-number references in this document are investigative notes,
not version-independent API documentation.

This document investigates the case where the module containing a Template
Haskell splice cannot be compiled by the native host worker.

## Current Worker Load Path

The worker evaluates a requested splice by loading the source module in a native
GHC session:

```haskell
target <- guessTarget sourceFile Nothing Nothing
setTargets [target]
load LoadAllTargets
```

If native GHC cannot load the module, the worker returns:

```haskell
Left ("host GHC failed to load " <> requestSourceFile request)
```

The detailed GHC diagnostic is currently printed to worker stderr, not encoded
as structured protocol data.

## Failure Shape

Example target-only source:

```haskell
module Example where

import Android.NDK

foreign import ccall "ANativeWindow_lock"
  lockWindow :: ...

foo = $(genFoo)
```

The native host worker can fail before reaching `foo`:

1. Import resolution:
   ```text
   Could not find module `Android.NDK`
   ```
2. Package availability:
   ```text
   cannot satisfy -package ...
   ```
3. CPP/include configuration:
   ```text
   fatal error: android/native_window.h: No such file or directory
   ```
4. FFI/header/toolchain assumptions:
   the module may require target headers, target C compiler flags, or target
   libraries that are not meaningful in the native worker environment.

In all of these cases, the current worker never reaches normal splice capture.
No `SpliceResult` is available for the requested splice.

## Why This Is Different From Remote Iserv

The goal of this implementation is not to run target code. The host worker
executes Template Haskell generator code on the build host and returns raw
Template Haskell AST payloads.

However, the current module-aware approach still asks native GHC to load the
whole source module. That means declarations/imports before and around the
splice must be acceptable to native GHC.

So the MVP requirement is stricter than normal cross compilation:

```text
the target module must also be host-loadable enough for native GHC to reach and
evaluate the requested splice
```

## Possible Approaches

### 1. Require Host-Buildable Splice Modules

Move TH generator use into modules that can be loaded by native GHC:

```haskell
module Example.TH where
genFoo :: Q Exp

module Example where
import Example.TH
foo = $(genFoo)
```

Then keep target-only imports out of the declaration groups the worker must load.

Pros:

- simplest MVP rule;
- aligns with common TH best practice;
- no stubs or partial compiler pipeline.

Cons:

- does not support arbitrary existing modules;
- users may need to refactor code.

### 2. Shadow Modules

Provide host-only replacements for target-only modules:

```text
host-shims/Android/NDK.hs
```

and put `host-shims` earlier in the worker import path.

Pros:

- can unblock simple imports;
- preserves source module shape if the imported API is small.

Cons:

- easy to diverge from target semantics;
- shims must be maintained;
- reify/typechecking may observe fake declarations.

### 3. Split Generator Code Into Separate Modules

Keep TH generator modules host-buildable and avoid reifying target-only
declarations.

Pros:

- robust for common code generation;
- clear boundary between host TH code and target runtime code.

Cons:

- does not support splices that intentionally inspect target-only declarations.

### 4. Stub Target-Only Imports

Generate or provide stubs for target-only imports and FFI declarations.

Pros:

- could allow more modules to load.

Cons:

- hard to make sound;
- FFI types, classes, instances, and pattern synonyms may matter to `reify`;
- wrong stubs can generate wrong code.

### 5. Compile Only Declaration Groups Required Before The Splice

Try to stop before target-only declarations that appear after the splice.

Pros:

- closer to GHC staging semantics;
- may avoid unrelated target-only code later in the module.

Cons:

- current worker uses `load LoadAllTargets`, not a partial declaration-group
  pipeline;
- implementing this means taking over more of GHC's renamer/typechecker
  pipeline;
- target-only imports at the top of the module still fail before any splice.

## MVP Recommendation

For the MVP, require host-loadable modules.

Supported:

```text
modules whose imports, CPP, declarations before the splice, and TH generator
dependencies can be loaded by native host GHC
```

Unsupported:

```text
modules that require target-only packages/imports/headers/toolchain state just
to load in native GHC
```

Recommended user-facing guidance:

1. Put TH generators and their dependencies in host-buildable modules.
2. Keep target-only imports behind module boundaries that do not need to be
   loaded by the host worker.
3. Avoid `reify` over target-only declarations in the MVP.
4. If unavoidable, provide explicit host shims and accept that they define the
   host-side TH semantics.

## Implementation Recommendations

Short term:

- improve worker error reporting so host load failures are returned as structured
  diagnostics, not only stderr;
- include the source file and requested splice key in the error;
- document the host-loadable-module requirement in user-facing setup docs.

Medium term:

- add worker options for extra import paths and package flags;
- support explicit host shim directories;
- include a context fingerprint in the cache key so shim/package changes
  invalidate captured expansions.

Long term:

- investigate a partial module pipeline only if host-loadable modules and shims
  are insufficient for real projects;
- compare against HLS splice-plugin machinery before taking over GHC
  declaration-group processing manually.

## Relation To `docs/target-context.md`

`docs/target-context.md` covers mismatched source shape caused by target CPP and
package flags.

This document covers the harder failure mode: native host GHC cannot load the
module at all.
