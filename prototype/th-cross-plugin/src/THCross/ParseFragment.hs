-- | Local parsing helpers for Haskell fragments returned by a TH worker.
--
-- The cross-side compiler must return AST nodes owned by its own GHC session.
-- For the prototype wire format we therefore exchange textual Haskell and
-- parse it locally into @GhcPs@ nodes instead of transferring GHC AST values.
module THCross.ParseFragment
  ( parseDeclarationFragments
  , parseExpressionFragment
  ) where

import GHC.Data.FastString (mkFastString)
import GHC.Data.StringBuffer (stringToStringBuffer)
import GHC.Driver.Config.Diagnostic (initDiagOpts)
import GHC.Driver.DynFlags
  ( DynFlags
  , extensionFlags
  , getDynFlags
  , targetPlatform
  )
import GHC.Driver.Session (safeImportsOn, supportedLanguagesAndExtensions)
import GHC.Hs (GhcPs, HsModule (..), LHsDecl, LHsExpr)
import GHC.Parser (parseExpression, parseModule)
import GHC.Parser.Lexer
  ( P
  , PState
  , ParseResult (..)
  , getPsErrorMessages
  , initParserState
  , mkParserOpts
  , unP
  )
import GHC.Parser.PostProcess (PV, runPV, unECP)
import GHC.Platform (platformArchOS)
import GHC.Tc.Types (TcM)
import GHC.Types.Error (isEmptyMessages)
import GHC.Types.SrcLoc (mkRealSrcLoc, unLoc)
import GHC.Utils.Outputable (ppr, showSDocUnsafe)

-- | Parse a Haskell expression fragment into the parser-stage AST expected by
-- 'MetaE' in 'runMetaHook'.
--
-- The parser options are derived from the active compiler session so language
-- extensions enabled for the module are also available to generated fragments.
parseExpressionFragment :: String -> TcM (LHsExpr GhcPs)
parseExpressionFragment source = do
  dflags <- getDynFlags
  runParserFragment dflags "<expression-fragment>" source $ do
    ecp <- parseExpression
    runPV (unECP ecp :: PV (LHsExpr GhcPs))

-- | Parse zero or more top-level declaration fragments into parser-stage AST.
--
-- TH declaration splices return declarations, not a complete module. GHC's
-- parser entrypoint for multiple top-level declarations is 'parseModule', so we
-- wrap the fragment in a synthetic module and then extract 'hsmodDecls'.
parseDeclarationFragments :: String -> TcM [LHsDecl GhcPs]
parseDeclarationFragments source = do
  dflags <- getDynFlags
  parsedModule <-
    runParserFragment dflags "<declaration-fragment>" syntheticModule parseModule
  pure (hsmodDecls (unLoc parsedModule))
  where
    syntheticModule =
      "module DeclarationFragment where\n" <> source

-- | Run a GHC parser entrypoint against an in-memory source fragment.
--
-- The synthetic source name is used only in parser diagnostics and source
-- locations inside the returned parsed tree. The parser options come from the
-- active 'DynFlags' so generated fragments see the same language extensions as
-- the module currently being compiled.
runParserFragment :: DynFlags -> String -> String -> P a -> TcM a
runParserFragment dflags sourceName source parser =
  case unP parser parserState of
    PFailed pst ->
      fail (formatParseErrors pst)
    POk pst result
      | isEmptyMessages (getPsErrorMessages pst) ->
          pure result
      | otherwise ->
          fail (formatParseErrors pst)
  where
    parserState =
      initParserState
        parserOpts
        (stringToStringBuffer source)
        (mkRealSrcLoc (mkFastString sourceName) 1 1)

    parserOpts =
      mkParserOpts
        (extensionFlags dflags)
        (initDiagOpts dflags)
        (supportedLanguagesAndExtensions (platformArchOS (targetPlatform dflags)))
        (safeImportsOn dflags)
        False
        False
        True

-- | Render parser diagnostics as a plain 'fail' message in 'TcM'.
--
-- This keeps parse failures on the normal GHC diagnostic path for the splice
-- currently being expanded.
formatParseErrors :: PState -> String
formatParseErrors pst =
  "failed to parse Haskell expression fragment: "
    <> showSDocUnsafe (ppr (getPsErrorMessages pst))
