# hls-splice-plugin Reuse Investigation

Task 8 investigates whether `hls-splice-plugin` can be reused for this
prototype.

The inspected source is a shallow clone of:

```text
https://github.com/haskell/haskell-language-server.git
commit 048cb169ce269e46015afcb9631e9378400bb272
branch master
```

The checked `haskell-language-server.cabal` says:

```text
tested-with: GHC == {9.14.1, 9.12.2, 9.10.3, 9.8.4, 9.6.7}
```

So the inspected implementation is intended to support GHC 9.8.4.

## Package Layout

`hls-splice-plugin` is an internal library of the HLS monorepo, not a standalone
package directory with its own cabal file.

Source paths:

```text
haskell-language-server.cabal
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs
plugins/hls-splice-plugin/src/Ide/Plugin/Splice/Types.hs
plugins/hls-refactor-plugin/src/Development/IDE/GHC/ExactPrint.hs
ghcide/src/Development/IDE/Core/RuleTypes.hs
ghcide/src/Development/IDE/Core/Compile.hs
```

Cabal section:

```text
haskell-language-server.cabal:908
library hls-splice-plugin
```

Exposed modules:

```text
Ide.Plugin.Splice
Ide.Plugin.Splice.Types
```

Dependencies of `hls-splice-plugin`:

```text
aeson
extra
foldl
ghc
ghcide == 2.14.0.0
hls-plugin-api == 2.14.0.0
haskell-language-server:hls-refactor-plugin
lens
lsp
mtl
syb
text
transformers
unliftio-core
```

This is a heavy dependency footprint for direct reuse in `th-cross`.

## How HLS Captures Splice Expansions

HLS records splice expansions during normal typechecking by installing its own
`runMetaHook`.

Source:

```text
ghcide/src/Development/IDE/Core/Compile.hs:393
```

Important functions:

```haskell
addSpliceHook :: IORef Splices -> Hooks -> Hooks
splice_hook :: Maybe (MetaHook TcM) -> IORef Splices -> MetaHook TcM
```

The hook delegates to the previous hook or `defaultRunMeta`, then stores the
expanded result:

```haskell
MetaE  -> metaRequestE  hook e -> exprSplices
MetaP  -> metaRequestP  hook e -> patSplices
MetaT  -> metaRequestT  hook e -> typeSplices
MetaD  -> metaRequestD  hook e -> declSplices
MetaAW -> metaRequestAW hook e -> awSplices
```

The captured type is:

```text
ghcide/src/Development/IDE/Core/RuleTypes.hs:131
```

```haskell
data Splices = Splices
  { exprSplices :: [(LHsExpr GhcTc, LHsExpr GhcPs)]
  , patSplices  :: [(LHsExpr GhcTc, LPat GhcPs)]
  , typeSplices :: [(LHsExpr GhcTc, LHsType GhcPs)]
  , declSplices :: [(LHsExpr GhcTc, [LHsDecl GhcPs])]
  , awSplices   :: [(LHsExpr GhcTc, Serialized)]
  }
```

This mechanism is directly relevant to our host worker. It demonstrates that a
native GHC session can wrap `defaultRunMeta`, execute normal TH, and collect the
`GhcPs` expansion result for each splice.

For `th-cross`, we cannot send these `GhcPs` values over the wire, but the host
worker can convert them to text before responding.

## Finding Splices

HLS detects the splice selected by an editor range using SYB traversal over the
parsed source.

Source:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:459
```

Function:

```haskell
codeAction :: PluginMethodHandler IdeState Method_TextDocumentCodeAction
```

Nested function:

```haskell
detectSplice :: RealSrcSpan -> GenericQ (SearchResult (RealSrcSpan, SpliceContext))
```

It detects:

```haskell
LHsExpr GhcPs:
  HsTypedSplice
  HsUntypedSplice

LPat GhcPs:
  SplicePat

LHsType GhcPs:
  HsSpliceTy

LHsDecl GhcPs:
  SpliceD
```

Related helper:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:284
findSubSpansDesc :: SrcSpan -> [(LHsExpr GhcTc, a)] -> [(SrcSpan, a)]
```

`findSubSpansDesc` sorts candidate expansions by descending subspan size and
uses `isSubspanOf` to choose the expansion whose original typed splice span
contains the requested range.

Reuse assessment:

```text
Useful idea:
  match by typed splice expression span and splice context.

Not directly reusable:
  LSP range plumbing, HIE/TypeCheck cache integration, HLS action system.
```

## Executing Expression Splices

Source:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:307
```

Typeclass:

```haskell
class (Outputable (ast GhcRn), ASTElement l (ast GhcPs)) => HasSplice l ast where
  type SpliceOf ast :: Type -> Type
  matchSplice :: Proxy# ast -> ast GhcPs -> Maybe (SpliceOf ast GhcPs)
  expandSplice :: Proxy# ast -> SpliceOf ast GhcPs -> RnM (Either (ast GhcPs) (ast GhcRn), FreeVars)
```

Expression instance:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:307
```

```haskell
instance HasSplice AnnListItem HsExpr where
  type SpliceOf HsExpr = HsSpliceCompat
  matchSplice _ (HsUntypedSplice _ spl) = Just (UntypedSplice spl)
  matchSplice _ (HsTypedSplice _ spl)   = Just (TypedSplice spl)
  expandSplice _ (UntypedSplice e) = fmap (first Right) $ rnUntypedSpliceExpr e
  expandSplice _ (TypedSplice e)   = fmap (first Right) $ rnTypedSplice e
```

For newer GHCs there is CPP around `HsTypedSpliceExpr`; for GHC 9.8.4 the
non-`MIN_VERSION_ghc(9,13,0)` branch applies.

Reuse assessment:

```text
Useful:
  classification of typed/untyped expression splices;
  exact GHC functions rnUntypedSpliceExpr and rnTypedSplice.

Not directly needed in our cross-side plugin:
  runMetaHook already receives MetaRequest after GHC has classified the splice.

Potentially useful in host worker Task 9:
  if worker evaluates selected source module manually rather than only wrapping runMetaHook.
```

## Executing Pattern Splices

Source:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:323
```

Implementation:

```haskell
instance HasSplice AnnListItem Pat where
  type SpliceOf Pat = HsUntypedSplice
  matchSplice _ (SplicePat _ spl) = Just spl
  expandSplice _ =
    fmap (first (Left . unLoc . utsplice_result . snd)) .
    rnSplicePat
```

Reuse assessment:

```text
Useful later for Task 18.
Not needed for expression-only MVP.
```

## Executing Type Splices

Source:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:332
```

Implementation:

```haskell
instance HasSplice AnnListItem HsType where
  type SpliceOf HsType = HsUntypedSplice
  matchSplice _ (HsSpliceTy _ spl) = Just spl
  expandSplice _ = fmap (first Right) . rnSpliceType
```

Reuse assessment:

```text
Useful later for Task 18.
Not needed for expression-only MVP.
```

## Executing Declaration Splices

Source:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:363
```

Manual expansion path:

```haskell
rnTopSpliceDecls spl
```

The call appears inside:

```haskell
graftDeclsWithM (RealSrcSpan srcSpan Nothing) $ \case
  (L _ (SpliceD _ (SpliceDecl _ (L _ spl) _))) -> ...
```

Reuse assessment:

```text
Useful later for Task 18 and Task 10.
Declaration splices need separate handling because the expansion is [LHsDecl GhcPs].
```

## Converting `GhcRn` Back To `GhcPs`

Source:

```text
plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs:433
```

Function:

```haskell
unRenamedE ::
  forall ast m l.
  (MonadFail m, HasSplice l ast) =>
  DynFlags ->
  ast GhcRn ->
  TransformT m (LocatedAn l (ast GhcPs))
```

Implementation strategy:

```haskell
parseAST dflags uniq $
  showSDoc dflags $ ppr expr
```

This is conceptually the same as our textual transport strategy:

```text
pretty-print generated AST
parse text back into GhcPs
```

Reuse assessment:

```text
Useful:
  validates text as a practical AST boundary inside GHC tooling.

Direct reuse:
  not ideal, because it depends on HLS TransformT, HasSplice, ASTElement,
  ExactPrint, and ghcide compatibility modules.

th-cross equivalent:
  our ParseFragment module already implements the cross-side parse step.
```

## Parsing and Grafting Helpers

Source:

```text
plugins/hls-refactor-plugin/src/Development/IDE/GHC/ExactPrint.hs
```

Important functions:

```text
graft'                   line 286
graftExpr                line 313
graftExprWithM           line 350
graftWithM               line 376
graftDecls               line 427
graftSmallestDeclsWithM  line 620
graftDeclsWithM          line 638
ASTElement               line 660
parseAST                 line 670
annotate                 line 717
annotateDecl             line 731
render                   line 746
```

`ASTElement` maps AST categories to exactprint parsers:

```haskell
HsExpr  -> parseExpr
Pat     -> parsePattern
HsType  -> parseType
HsDecl  -> parseDecl
```

Reuse assessment:

```text
Very useful for HLS editor rewriting.
Mostly unnecessary for runMetaHook MVP.
```

Our cross-side `runMetaHook` returns the replacement AST directly to GHC, so we
do not need to graft into a parsed source tree. GHC itself continues normal
renaming/typechecking/code generation after receiving the `GhcPs` result.

Grafting becomes relevant only if we later implement an HLS-like source rewrite
tool or if the host worker expands a whole source module and stores textual
source edits. That is not the current architecture.

## Reusable Pieces

Independent or lightly coupled ideas:

```text
1. Capturing splice expansions by wrapping runMetaHook.
2. Storing expansions as:
   original typed splice expression -> generated GhcPs result.
3. Distinguishing expression, pattern, type, declaration, and annotation-wrapper splices from MetaRequest.
4. Pretty-printing generated AST and reparsing as a version/process boundary.
5. Matching requested splice by span/context, then later by a stronger splice key.
```

Candidate code to extract or reimplement:

```text
Splices data type shape
splice_hook pattern from ghcide Compile.hs
minimal span matching helper similar to findSubSpansDesc
minimal pretty-print-to-text helpers per splice kind
```

## HLS-Coupled Pieces

These should not be copied into the MVP:

```text
IdeState
runAction/use/useE/useWithStale
TypeCheck/GetParsedModule/GhcSessionDeps HLS rules
LSP command/code action machinery
WorkspaceEdit generation
ExactPrint grafting for editor edits
Development.IDE.GHC.Compat compatibility layer
hls-plugin-api
lens-heavy LSP plumbing
```

Directly depending on `hls-splice-plugin` would pull in most of HLS:

```text
ghcide
hls-plugin-api
hls-refactor-plugin
lsp
syb/lens/foldl/extra
```

That is too heavy for this prototype.

## Proposed Extraction Plan

Recommended approach for `th-cross`:

```text
Do not depend on hls-splice-plugin directly.
Reimplement the small subset needed for a host worker.
Use HLS as a reference for GHC API calls and edge cases.
```

Step 1, Task 9 host worker:

```text
Create a native GHC session for the requested module.
Install a host-side runMetaHook that wraps defaultRunMeta.
For each MetaRequest:
  run defaultRunMeta
  pretty-print the generated GhcPs result
  store it by splice key/span/kind
Return the requested expansion as text.
```

This is closer to `ghcide/src/Development/IDE/Core/Compile.hs:393` than to
`plugins/hls-splice-plugin/src/Ide/Plugin/Splice.hs`.

Step 2, all splice kinds:

```text
Expression:   LHsExpr GhcPs -> text
Pattern:      LPat GhcPs -> text
Type:         LHsType GhcPs -> text
Declaration: [LHsDecl GhcPs] -> text
```

Use `showSDoc dflags . ppr` initially, then improve formatting only if needed.

Step 3, matching:

```text
Use current request fields:
  module
  spliceKind
  sourceSpan
  pretty-printed splice expression

Later replace raw span matching with Task 11 splice keys.
```

Step 4, avoid grafting:

```text
Do not use HLS ExactPrint grafting in the compiler plugin.
runMetaHook already returns the AST directly.
```

## Conclusion

`hls-splice-plugin` is valuable as a source archaeology reference, but not as a
direct dependency.

The most relevant reusable pattern is from `ghcide` rather than the visible HLS
plugin:

```text
wrap runMetaHook
delegate to defaultRunMeta
capture generated GhcPs expansion
associate it with the original typed splice expression
```

For `th-cross`, this should be implemented inside the native host worker. The
worker should then convert captured expansions to textual Haskell and return
them over the existing binary-framed protocol.
