{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | JSON-lines protocol shared by the cross-side plugin and host TH worker.
--
-- The protocol deliberately transports generated Haskell text rather than GHC
-- AST values. The receiving compiler parses that text locally into its own
-- @GhcPs@ AST.
module THCross.Protocol
  ( SpliceDiagnostic (..)
  , SpliceForeignFile (..)
  , SpliceResult (..)
  , SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , decodeRequestLine
  , decodeResponseLine
  , encodeRequestLine
  , encodeResponseLine
  , foreignSrcLangToStr
  , sourceSpanKeyText
  , spliceKindToStr
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.!=)
  , (.=)
  )
import qualified Data.ByteString.Lazy as BL
import GHC.Tc.Types (ForeignSrcLang (..))
import Data.Word (Word8)
import THCross.SpliceKey (SpliceKey)

-- | Diagnostic produced by host-side TH through @reportWarning@ or
-- @reportError@.
data SpliceDiagnostic = SpliceDiagnostic
  { -- | True for @reportError@, false for @reportWarning@.
    spliceDiagnosticIsError :: !Bool
  , -- | User-supplied diagnostic message.
    spliceDiagnosticMessage :: !String
  }
  deriving (Eq, Show)

instance ToJSON SpliceDiagnostic where
  toJSON diagnostic =
    object
      [ "severity" .= diagnosticSeverity diagnostic
      , "message" .= spliceDiagnosticMessage diagnostic
      ]
    where
      diagnosticSeverity value
        | spliceDiagnosticIsError value = "error" :: String
        | otherwise = "warning"

instance FromJSON SpliceDiagnostic where
  parseJSON =
    withObject "SpliceDiagnostic" $ \obj -> do
      severity <- obj .: "severity"
      isError <-
        case severity :: String of
          "error" -> pure True
          "warning" -> pure False
          raw -> fail ("unknown diagnostic severity: " <> raw)
      SpliceDiagnostic isError <$> obj .: "message"

-- | Foreign source file registered by host-side TH through
-- @addForeignFilePath@.
data SpliceForeignFile = SpliceForeignFile
  { -- | Foreign source language expected by GHC.
    spliceForeignFileLang :: !ForeignSrcLang
  , -- | Source path as registered by TH.
    spliceForeignFilePath :: !FilePath
  }
  deriving (Eq, Show)

instance ToJSON SpliceForeignFile where
  toJSON foreignFile =
    object
      [ "language" .= foreignSrcLangToStr (spliceForeignFileLang foreignFile)
      , "path" .= spliceForeignFilePath foreignFile
      ]

instance FromJSON SpliceForeignFile where
  parseJSON =
    withObject "SpliceForeignFile" $ \obj -> do
      rawLang <- obj .: "language"
      foreignLang <-
        case parseForeignSrcLang rawLang of
          Right value -> pure value
          Left err -> fail err
      SpliceForeignFile foreignLang <$> obj .: "path"

-- | Stable textual representation of GHC's foreign source language.
foreignSrcLangToStr :: ForeignSrcLang -> String
foreignSrcLangToStr = \case
  LangC -> "c"
  LangCxx -> "cxx"
  LangObjc -> "objc"
  LangObjcxx -> "objcxx"
  LangAsm -> "asm"
#if MIN_VERSION_ghc(9,8,0)
  LangJs -> "js"
#endif
  RawObject -> "raw-object"

-- | Parse the protocol representation back to GHC's foreign source language.
parseForeignSrcLang :: String -> Either String ForeignSrcLang
parseForeignSrcLang = \case
  "c" -> Right LangC
  "cxx" -> Right LangCxx
  "objc" -> Right LangObjc
  "objcxx" -> Right LangObjcxx
  "asm" -> Right LangAsm
#if MIN_VERSION_ghc(9,8,0)
  "js" -> Right LangJs
#endif
  "raw-object" -> Right RawObject
  raw -> Left ("unknown foreign source language: " <> raw)

-- | Result of host-side splice evaluation plus effects to replay in cross GHC.
data SpliceResult = SpliceResult
  { -- | Generated Haskell fragment parsed by the cross-side compiler.
    spliceResultHaskell :: !String
  , -- | Binary-encoded 'GHC.Serialized.Serialized' for annotation wrappers.
    spliceResultAnnotationWrapper :: !(Maybe [Word8])
  , -- | Files registered through @addDependentFile@ while evaluating the splice.
    spliceResultDependentFiles :: ![FilePath]
  , -- | Foreign files registered through @addForeignFilePath@.
    spliceResultForeignFiles :: ![SpliceForeignFile]
  , -- | Top-level declarations registered through @addTopDecls@.
    spliceResultAddedTopDecls :: !String
  , -- | Diagnostics reported by host-side TH and replayed in cross GHC.
    spliceResultDiagnostics :: ![SpliceDiagnostic]
  }
  deriving (Eq, Show)

instance ToJSON SpliceResult where
  toJSON result =
    object
      [ "generatedHaskell" .= spliceResultHaskell result
      , "annotationWrapper" .= spliceResultAnnotationWrapper result
      , "dependentFiles" .= spliceResultDependentFiles result
      , "foreignFiles" .= spliceResultForeignFiles result
      , "addedTopDecls" .= spliceResultAddedTopDecls result
      , "diagnostics" .= spliceResultDiagnostics result
      ]

instance FromJSON SpliceResult where
  parseJSON =
    withObject "SpliceResult" $ \obj ->
      SpliceResult
        <$> obj .: "generatedHaskell"
        <*> obj .:? "annotationWrapper"
        <*> obj .: "dependentFiles"
        <*> obj .:? "foreignFiles" .!= []
        <*> obj .:? "addedTopDecls" .!= ""
        <*> obj .:? "diagnostics" .!= []

-- | 1-based source span for the splice as seen by the cross GHC process.
data SourceSpan = SourceSpan
  { -- | 1-based line where the splice starts.
    sourceSpanStartLine :: !Int
  , -- | 1-based column where the splice starts.
    sourceSpanStartColumn :: !Int
  , -- | 1-based line where the splice ends.
    sourceSpanEndLine :: !Int
  , -- | 1-based column where the splice ends.
    sourceSpanEndColumn :: !Int
  }
  deriving (Eq, Show)

instance ToJSON SourceSpan where
  toJSON spanInfo =
    object
      [ "startLine" .= sourceSpanStartLine spanInfo
      , "startColumn" .= sourceSpanStartColumn spanInfo
      , "endLine" .= sourceSpanEndLine spanInfo
      , "endColumn" .= sourceSpanEndColumn spanInfo
      ]

instance FromJSON SourceSpan where
  parseJSON =
    withObject "SourceSpan" $ \obj ->
      SourceSpan
        <$> obj .: "startLine"
        <*> obj .: "startColumn"
        <*> obj .: "endLine"
        <*> obj .: "endColumn"

-- | Stable textual representation used as part of 'SpliceKey' payload.
sourceSpanKeyText :: SourceSpan -> String
sourceSpanKeyText spanInfo =
  show (sourceSpanStartLine spanInfo)
    <> ":"
    <> show (sourceSpanStartColumn spanInfo)
    <> "-"
    <> show (sourceSpanEndLine spanInfo)
    <> ":"
    <> show (sourceSpanEndColumn spanInfo)

-- | Template Haskell splice category.
data SpliceKind
  = ExpressionSplice
  | TypeSplice
  | PatternSplice
  | DeclarationSplice
  | AnnotationWrapperSplice
  deriving (Eq, Show)

instance ToJSON SpliceKind where
  toJSON = toJSON . spliceKindToStr

instance FromJSON SpliceKind where
  parseJSON value = do
    raw <- parseJSON value
    case raw :: String of
      "expression" -> pure ExpressionSplice
      "type" -> pure TypeSplice
      "pattern" -> pure PatternSplice
      "declaration" -> pure DeclarationSplice
      "annotation-wrapper" -> pure AnnotationWrapperSplice
      _ -> fail ("unknown splice kind: " <> raw)

-- | Stable textual representation used on the wire.
spliceKindToStr :: SpliceKind -> String
spliceKindToStr ExpressionSplice = "expression"
spliceKindToStr TypeSplice = "type"
spliceKindToStr PatternSplice = "pattern"
spliceKindToStr DeclarationSplice = "declaration"
spliceKindToStr AnnotationWrapperSplice = "annotation-wrapper"

-- | Request sent by the cross-side plugin to the native host worker.
data SpliceRequest = SpliceRequest
  { -- | Correlation id echoed by the worker response.
    requestId :: !String
  , -- | Module currently being compiled by the cross-side GHC.
    requestModuleName :: !String
  , -- | GHC unit id of the component currently compiling this module.
    requestComponentUnitId :: !String
  , -- | Source file path that the host worker should load in native GHC.
    requestSourceFile :: !FilePath
  , -- | Splice result shape expected by the cross-side 'runMetaHook'.
    requestSpliceKind :: !SpliceKind
  , -- | Source span used for diagnostics and as part of the splice key payload.
    requestSourceSpan :: !SourceSpan
  , -- | Opaque source occurrence identity used for worker-side matching.
    requestSpliceKey :: !SpliceKey
  , -- | Pretty-printed original splice expression for diagnostics.
    requestSpliceExpression :: !String
  , -- | Version of the cross-side compiler that produced this request.
    requestCrossGhcVersion :: !String
  , -- | Host-side unit ids that must be exposed while loading this module.
    requestHostPackageIds :: ![String]
  , -- | Extra source directories visible to host GHC while loading this module.
    requestHostSourceDirs :: ![FilePath]
  , -- | Extra GHC options applied to the host-side module load.
    requestHostGhcOptions :: ![String]
  }
  deriving (Eq, Show)

instance ToJSON SpliceRequest where
  toJSON request =
    object
      [ "requestId" .= requestId request
      , "module" .= requestModuleName request
      , "componentUnitId" .= requestComponentUnitId request
      , "sourceFile" .= requestSourceFile request
      , "spliceKind" .= requestSpliceKind request
      , "sourceSpan" .= requestSourceSpan request
      , "spliceKey" .= requestSpliceKey request
      , "spliceExpression" .= requestSpliceExpression request
      , "crossGhcVersion" .= requestCrossGhcVersion request
      , "hostPackageIds" .= requestHostPackageIds request
      , "hostSourceDirs" .= requestHostSourceDirs request
      , "hostGhcOptions" .= requestHostGhcOptions request
      ]

instance FromJSON SpliceRequest where
  parseJSON =
    withObject "SpliceRequest" $ \obj ->
      SpliceRequest
        <$> obj .: "requestId"
        <*> obj .: "module"
        <*> obj .:? "componentUnitId" .!= ""
        <*> obj .: "sourceFile"
        <*> obj .: "spliceKind"
        <*> obj .: "sourceSpan"
        <*> obj .: "spliceKey"
        <*> obj .: "spliceExpression"
        <*> obj .: "crossGhcVersion"
        <*> obj .:? "hostPackageIds" .!= []
        <*> obj .:? "hostSourceDirs" .!= []
        <*> obj .:? "hostGhcOptions" .!= []

-- | Response returned by the native host worker.
data SpliceResponse
  = SpliceOk
      { -- | Correlation id copied from the request.
        responseRequestId :: !String
      , -- | Splice result and replayable side effects.
        responseSpliceResult :: !SpliceResult
      }
  | SpliceError
      { -- | Correlation id copied from the request when available.
        responseRequestId :: !String
      , -- | Human-readable worker/protocol error.
        responseMessage :: !String
      }
  deriving (Eq, Show)

instance ToJSON SpliceResponse where
  toJSON response =
    case response of
      SpliceOk reqId spliceResult ->
        object
          [ "requestId" .= reqId
          , "status" .= ("ok" :: String)
          , "generatedHaskell" .= spliceResultHaskell spliceResult
          , "annotationWrapper" .= spliceResultAnnotationWrapper spliceResult
          , "dependentFiles" .= spliceResultDependentFiles spliceResult
          , "foreignFiles" .= spliceResultForeignFiles spliceResult
          , "addedTopDecls" .= spliceResultAddedTopDecls spliceResult
          , "diagnostics" .= spliceResultDiagnostics spliceResult
          ]
      SpliceError reqId message ->
        object
          [ "requestId" .= reqId
          , "status" .= ("error" :: String)
          , "message" .= message
          ]

instance FromJSON SpliceResponse where
  parseJSON =
    withObject "SpliceResponse" $ \obj -> do
      reqId <- obj .: "requestId"
      status <- obj .: "status"
      case status :: String of
        "ok" ->
          SpliceOk reqId
            <$> ( SpliceResult
                    <$> obj .: "generatedHaskell"
                    <*> obj .:? "annotationWrapper"
                    <*> obj .: "dependentFiles"
                    <*> obj .:? "foreignFiles" .!= []
                    <*> obj .:? "addedTopDecls" .!= ""
                    <*> obj .:? "diagnostics" .!= []
                )
        "error" -> SpliceError reqId <$> obj .: "message"
        _ -> fail ("unknown response status: " <> status)

-- | Encode a request as one JSON-lines frame.
encodeRequestLine :: SpliceRequest -> BL.ByteString
encodeRequestLine = encodeJsonLine

-- | Decode a request from one JSON-lines frame.
decodeRequestLine :: BL.ByteString -> Either String SpliceRequest
decodeRequestLine = eitherDecode

-- | Encode a response as one JSON-lines frame.
encodeResponseLine :: SpliceResponse -> BL.ByteString
encodeResponseLine = encodeJsonLine

-- | Decode a response from one JSON-lines frame.
decodeResponseLine :: BL.ByteString -> Either String SpliceResponse
decodeResponseLine = eitherDecode

-- | Encode a JSON value and append the newline frame delimiter.
encodeJsonLine :: ToJSON a => a -> BL.ByteString
encodeJsonLine value = encode value <> "\n"
