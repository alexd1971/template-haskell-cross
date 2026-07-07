# Host Worker Evaluation MVP

This document records the selected Task 7 approach for the first native
host-side Template Haskell evaluation prototype.

## Goal

The worker should evaluate a simple expression splice on the build host and
return textual Haskell to the cross-side GHC plugin.

Supported MVP input:

```haskell
foo = $([| 42 |])
```

The worker returns:

```haskell
42
```

## Selected Approach

For each expression splice request, the worker creates a temporary Haskell
splice evaluation module and executes it with `runghc`.

The generated splice evaluation module conceptually looks like:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Main where

import Control.Monad (join)
import Language.Haskell.TH
import Language.Haskell.TH.Ppr (pprint)
import Language.Haskell.TH.Syntax (runQ)

main :: IO ()
main = do
  generated <- runQ ((SPLICE_EXPRESSION) :: Q Exp)
  putStrLn (pprint generated)
```

The worker captures stdout and returns it as `generatedHaskell`.

The worker also tries a fallback form:

```haskell
runQ (join (SPLICE_EXPRESSION) :: Q Exp)
```

This is only a compatibility experiment for expressions that produce
`Q (Q Exp)`. It is not a substitute for normal GHC splice typechecking.

## Why This Approach

This is the smallest end-to-end implementation that proves the desired data
flow:

```text
plugin sends splice text
  -> native worker executes TH
  -> worker pretty-prints TH Exp
  -> plugin parses generated Haskell locally
```

It avoids using GHC internals in the worker before the basic protocol and
process boundary are proven.

## Limitations

This is not module-aware evaluation.

Unsupported in this MVP:

- `reify`
- local declaration-group context
- imports from the module containing the splice
- target-specific package/module environments
- declaration, type, and pattern splices
- `Q` side-effect replay
- persistent GHC sessions

The temporary splice evaluation module only sees its own imports plus the implicit Prelude. This
means splices that depend on names from the original module are expected to
fail until Task 9.

## Next Step

Task 9 should replace this isolated runner with module-aware host evaluation in
a native GHC session. That is required for `reify` and normal Template Haskell
staging semantics.
