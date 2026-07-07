-- | Local parsing helpers for Haskell fragments returned by a TH worker.
--
-- The cross-side compiler must return AST nodes owned by its own GHC session.
-- For the prototype wire format we therefore exchange textual Haskell and
-- parse it locally into @GhcPs@ nodes instead of transferring GHC AST values.
module THCross.ParseFragment
  ( parseExpressionFragment
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
import GHC.Hs (GhcPs, LHsExpr)
import GHC.Parser (parseExpression)
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
import GHC.Types.SrcLoc (mkRealSrcLoc)
import GHC.Utils.Outputable (ppr, showSDocUnsafe)

-- | Parse a Haskell expression fragment into the parser-stage AST expected by
-- 'MetaE' in 'runMetaHook'.
--
-- The parser options are derived from the active compiler session so language
-- extensions enabled for the module are also available to generated fragments.
parseExpressionFragment :: String -> TcM (LHsExpr GhcPs)
parseExpressionFragment source = do
  dflags <- getDynFlags
  runParserFragment dflags "<th-cross-expression-fragment>" source $ do
    ecp <- parseExpression
    runPV (unECP ecp :: PV (LHsExpr GhcPs))

runParserFragment :: DynFlags -> FilePath -> String -> P a -> TcM a
runParserFragment dflags fileName source parser =
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
        (mkRealSrcLoc (mkFastString fileName) 1 1)

    parserOpts =
      mkParserOpts
        (extensionFlags dflags)
        (initDiagOpts dflags)
        (supportedLanguagesAndExtensions (platformArchOS (targetPlatform dflags)))
        (safeImportsOn dflags)
        False
        False
        True

formatParseErrors :: PState -> String
formatParseErrors pst =
  "failed to parse Haskell expression fragment: "
    <> showSDocUnsafe (ppr (getPsErrorMessages pst))
