{-# LANGUAGE LambdaCase #-}

-- | Low-level Template Haskell helpers used by the host worker capture hook.
module Worker.TH
  ( convertDeclarationsOrFail
  , convertExpressionOrFail
  , convertPatternOrFail
  , convertTypeOrFail
  , encodeAnnotationWrapper
  , evaluateSplice
  , getDependentFiles
  , getForeignFiles
  , mkCapturedSpliceKey
  , mkSpliceResult
  , runMetaDeclsTH
  , runMetaExpTH
  , runMetaPatTH
  , runMetaTypeTH
  ) where

import Data.Binary (encode)
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (mapMaybe)
import Data.Word (Word8)
import qualified Language.Haskell.TH as TH
import GHC.Data.Bag (bagToList)
import GHC.Hs (GhcPs, GhcTc, LHsDecl, LHsExpr, LHsType, LPat)
import GHC.Parser.Annotation (getLocA)
import GHC.Serialized (Serialized)
import GHC.Tc.Errors.Types (THError (ReportCustomQuasiError), TcRnMessage (TcRnTHError))
import GHC.Tc.Gen.Splice (runMeta', runTHDec, runTHExp, runTHPat, runTHType)
import GHC.Tc.Types (TcGblEnv (..), TcM)
import GHC.Tc.Utils.Monad (getErrsVar, getGblEnv, readTcRef, writeTcRef)
import GHC.ThToHs (convertToHsDecls, convertToHsExpr, convertToHsType, convertToPat)
import GHC.Types.Basic (Origin (FromSource))
import GHC.Types.Error
  ( Messages
  , MsgEnvelope (errMsgDiagnostic)
  , emptyMessages
  , getMessages
  , unionMessages
  )
import GHC.Types.SrcLoc
  ( SrcSpan (..)
  , srcSpanEndCol
  , srcSpanEndLine
  , srcSpanStartCol
  , srcSpanStartLine
  )
import GHC.Unit.Module (moduleName, moduleNameString)
import GHC.Utils.Outputable (text)
import GHCi.TH.Binary ()
import THCross.Protocol
  ( SpliceDiagnostic (..)
  , SpliceForeignFile (..)
  , SpliceKind
  , SpliceResult (..)
  , SourceSpan (..)
  , sourceSpanKeyText
  , spliceKindToStr
  )
import THCross.SpliceKey
  ( SpliceKey
  , mkSpliceKey
  )

-- | Construct a captured splice result before module-level effects are attached.
mkSpliceResult ::
  Maybe TH.Exp ->
  Maybe TH.Pat ->
  Maybe TH.Type ->
  Maybe [TH.Dec] ->
  Maybe [Word8] ->
  [TH.Dec] ->
  [SpliceDiagnostic] ->
  SpliceResult
mkSpliceResult expression pattern type_ declarations annotationWrapper addedTopDecls diagnostics =
  SpliceResult
    { spliceResultExpression = expression
    , spliceResultPattern = pattern
    , spliceResultType = type_
    , spliceResultDeclarations = declarations
    , spliceResultAnnotationWrapper = annotationWrapper
    , spliceResultDependentFiles = []
    , spliceResultForeignFiles = []
    , spliceResultAddedTopDecls = addedTopDecls
    , spliceResultDiagnostics = diagnostics
    }

-- | Encode a same-version annotation wrapper payload for the cross-side plugin.
encodeAnnotationWrapper :: Serialized -> [Word8]
encodeAnnotationWrapper =
  LBS.unpack . encode

-- | Evaluate an expression splice to raw Template Haskell syntax without
-- converting it to GHC parsed syntax inside 'runMeta''.
runMetaExpTH :: LHsExpr GhcTc -> TcM TH.Exp
runMetaExpTH =
  runMeta'
    True
    (text . TH.pprint)
    (\_srcSpan hval -> Right <$> runTHExp hval)

runMetaPatTH :: LHsExpr GhcTc -> TcM TH.Pat
runMetaPatTH =
  runMeta'
    True
    (text . TH.pprint)
    (\_srcSpan hval -> Right <$> runTHPat hval)

runMetaTypeTH :: LHsExpr GhcTc -> TcM TH.Type
runMetaTypeTH =
  runMeta'
    True
    (text . TH.pprint)
    (\_srcSpan hval -> Right <$> runTHType hval)

runMetaDeclsTH :: LHsExpr GhcTc -> TcM [TH.Dec]
runMetaDeclsTH =
  runMeta'
    True
    (text . TH.pprint)
    (\_srcSpan hval -> Right <$> runTHDec hval)

-- | Convert Template Haskell syntax back to parsed GHC syntax so the host GHC
-- load keeps normal splice semantics while the TH payload is captured.
convertExpressionOrFail :: LHsExpr GhcTc -> TH.Exp -> TcM (LHsExpr GhcPs)
convertExpressionOrFail spliceExpr thExp =
  case convertToHsExpr generatedOrigin (getLocA spliceExpr) thExp of
    Left _err ->
      fail "TH expression conversion failed"
    Right hsExp ->
      pure hsExp

convertPatternOrFail :: LHsExpr GhcTc -> TH.Pat -> TcM (LPat GhcPs)
convertPatternOrFail spliceExpr thPat =
  case convertToPat generatedOrigin (getLocA spliceExpr) thPat of
    Left _err ->
      fail "TH pattern conversion failed"
    Right hsPat ->
      pure hsPat

convertTypeOrFail :: LHsExpr GhcTc -> TH.Type -> TcM (LHsType GhcPs)
convertTypeOrFail spliceExpr thType =
  case convertToHsType generatedOrigin (getLocA spliceExpr) thType of
    Left _err ->
      fail "TH type conversion failed"
    Right hsType ->
      pure hsType

convertDeclarationsOrFail :: LHsExpr GhcTc -> [TH.Dec] -> TcM [LHsDecl GhcPs]
convertDeclarationsOrFail spliceExpr thDecls =
  case convertToHsDecls generatedOrigin (getLocA spliceExpr) thDecls of
    Left _err ->
      fail "TH declaration conversion failed"
    Right hsDecls ->
      pure hsDecls

generatedOrigin :: Origin
generatedOrigin =
  FromSource

-- | Evaluate one splice while separately recording replayable TH state.
--
-- Host GHC stores @reportWarning@ and @reportError@ in the current 'TcM'
-- message bag. Temporarily clearing that bag gives us the messages produced by
-- this splice alone; restoring the union afterwards keeps normal host
-- compilation semantics intact.
--
-- @addTopDecls@ similarly writes to cumulative 'TcGblEnv' refs. Isolating them
-- lets the worker capture raw declarations added by this splice without
-- duplicating declarations added by earlier splices.
evaluateSplice :: TcM a -> TcM (a, [SpliceDiagnostic], [TH.Dec])
evaluateSplice action = do
  errsVar <- getErrsVar
  previousMessages <- readTcRef errsVar
  tcGblEnv <- getGblEnv
  let topDeclsVar = tcg_th_topdecls tcGblEnv
      topDeclsTHVar = tcg_th_topdecls_th tcGblEnv
  previousTopDecls <- readTcRef topDeclsVar
  previousTopDeclsTH <- readTcRef topDeclsTHVar
  writeTcRef errsVar emptyMessages
  writeTcRef topDeclsVar []
  writeTcRef topDeclsTHVar []
  result <- action
  spliceMessages <- readTcRef errsVar
  addedTopDecls <- readTcRef topDeclsVar
  addedTopDeclsTH <- readTcRef topDeclsTHVar
  writeTcRef errsVar (spliceMessages `unionMessages` previousMessages)
  writeTcRef topDeclsVar (addedTopDecls <> previousTopDecls)
  writeTcRef topDeclsTHVar (addedTopDeclsTH <> previousTopDeclsTH)
  pure (result, extractTHDiagnostics spliceMessages, addedTopDeclsTH)

-- | Keep only diagnostics explicitly emitted by Template Haskell @report*@.
extractTHDiagnostics :: Messages TcRnMessage -> [SpliceDiagnostic]
extractTHDiagnostics messages =
  mapMaybe extractTHDiagnostic (bagToList (getMessages messages))
  where
    extractTHDiagnostic message =
      case errMsgDiagnostic message of
        TcRnTHError (ReportCustomQuasiError isError messageText) ->
          Just (SpliceDiagnostic isError messageText)
        _ ->
          Nothing

-- | Read files registered through @addDependentFile@ in the host GHC session.
getDependentFiles :: TcM [FilePath]
getDependentFiles = do
  tcGblEnv <- getGblEnv
  readTcRef (tcg_dependent_files tcGblEnv)

-- | Read foreign files registered through @addForeignFilePath@ in the host GHC
-- session.
getForeignFiles :: TcM [SpliceForeignFile]
getForeignFiles = do
  tcGblEnv <- getGblEnv
  map toSpliceForeignFile <$> readTcRef (tcg_th_foreign_files tcGblEnv)
  where
    toSpliceForeignFile (lang, path) =
      SpliceForeignFile
        { spliceForeignFileLang = lang
        , spliceForeignFilePath = path
        }

-- | Attach the source-occurrence splice key to a captured expansion.
--
-- This runs in 'TcM' inside the host compiler, so it can read the current
-- 'TcGblEnv' to discover which module is being compiled when the splice fires.
mkCapturedSpliceKey ::
  SpliceKind ->
  LHsExpr GhcTc ->
  TcM SpliceKey
mkCapturedSpliceKey spliceKind spliceExpr = do
  tcGblEnv <- getGblEnv
  let spliceModuleName = moduleNameString (moduleName (tcg_mod tcGblEnv))
      sourceSpan = protocolSourceSpan (getLocA spliceExpr)
      spliceKindName = spliceKindToStr spliceKind
  pure (mkSpliceKey spliceModuleName spliceKindName (sourceSpanKeyText sourceSpan))

-- | Convert a GHC source span into the protocol span used for matching.
protocolSourceSpan :: SrcSpan -> SourceSpan
protocolSourceSpan = \case
  RealSrcSpan realSpan _ ->
    SourceSpan
      { sourceSpanStartLine = srcSpanStartLine realSpan
      , sourceSpanStartColumn = srcSpanStartCol realSpan
      , sourceSpanEndLine = srcSpanEndLine realSpan
      , sourceSpanEndColumn = srcSpanEndCol realSpan
      }
  UnhelpfulSpan _ ->
    SourceSpan 1 1 1 1
