# Splice Identification

This document records the Task 11 splice identity design.

## Source View Invariant

The host worker must evaluate the same source view that the cross-side GHC is
compiling.

That is a required invariant, not a best-effort heuristic. If the worker loads a
different source view, it may expand a different splice and the result is not
valid for the cross compilation.

Examples of source-view differences that must be handled by configuration or
rejected:

- different CPP flags;
- different package flags that affect preprocessing;
- generated or copied source paths that do not correspond to the cross source;
- source file changes between the cross request and worker load.

## Key Shape

For source splices, the occurrence identity is:

```text
module name
splice kind
source span
```

Task 11 represents that identity as an opaque `SpliceKey`:

```haskell
newtype SpliceKey = SpliceKey
  { unSpliceKey :: String
  }
```

The current key is a GHC fingerprint of:

```text
module + ":" + splice kind + ":" + source span
```

The wire protocol treats the key as opaque:

```json
{
  "spliceKey": "..."
}
```

The current digest is not a cryptographic hash. If this key becomes persistent
cache metadata, the digest format should be replaced with an explicit format such
as `sha256:<digest>` without changing the JSON field shape.

## Why Not Pretty-Printed Expressions

The key intentionally does not include `ppr spliceExpr`.

Pretty-printed GHC AST is not a stable source identity:

- formatting can differ between GHC versions;
- inserted parentheses or qualification can change;
- generated/internal names can affect output;
- whitespace normalization is not syntax normalization.

Since the source view must match, `module + kind + span` is the stronger
invariant for source splice occurrences.

## Matching

The worker matches captured splices by exact `SpliceKey`:

```text
capturedSpliceKey == requestSpliceKey
```

There is no secondary validation based on expression text. A key mismatch means
the worker did not capture the source occurrence requested by the cross-side
plugin.

`sourceSpan` remains in the protocol for diagnostics and to make the key payload
auditable, but matching uses the opaque `SpliceKey`.

## Known Limitations

Generated splices:

Generated splices may have synthetic or unhelpful spans. They are not covered by
this source-splice identity yet.

Nested splices:

Nested splice behavior still needs explicit tests. The same source-view invariant
applies, but span attribution must be verified.

Source changes during compilation:

The prototype reads the source file again in the worker. A later version should
detect source changes, for example by including a module source hash in the
request or using a build-system-provided immutable source path.

CPP/target context:

The worker must be configured to see the same effective source after
preprocessing. Target-specific CPP differences are tracked separately in
`docs/target-context.md`.
