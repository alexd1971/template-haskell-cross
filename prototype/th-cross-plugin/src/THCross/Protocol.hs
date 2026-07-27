{-# LANGUAGE LambdaCase #-}

-- | Binary protocol shared by the cross-side plugin and host TH worker.
--
-- Messages are encoded with "Data.Binary" and framed with a 4-byte big-endian
-- payload length. Splice results carry raw Template Haskell AST values and are
-- therefore intentionally tied to one GHC/template-haskell version.
module THCross.Protocol
  ( SpliceDiagnostic (..)
  , SpliceForeignFile (..)
  , SpliceResult (..)
  , SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , foreignSrcLangToStr
  , readRequest
  , readResponse
  , sourceSpanKeyText
  , spliceKindToStr
  , writeRequest
  , writeResponse
  ) where

import Control.Exception (IOException, try)
import Data.Binary
  ( Binary (..)
  , decodeOrFail
  , encode
  )
import Data.Binary.Get (Get, getWord32be, runGetOrFail)
import Data.Binary.Put (Put, putWord32be, runPut)
import qualified Data.ByteString.Lazy as BL
import GHC.Tc.Types (ForeignSrcLang (..))
import GHCi.TH.Binary ()
import qualified Language.Haskell.TH.Syntax as TH
import Data.Word (Word32, Word8)
import System.IO (Handle, hFlush)
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

instance Binary SpliceDiagnostic where
  put diagnostic = do
    put (spliceDiagnosticIsError diagnostic)
    put (spliceDiagnosticMessage diagnostic)
  get =
    SpliceDiagnostic <$> get <*> get

-- | Foreign source file registered by host-side TH through
-- @addForeignFilePath@.
data SpliceForeignFile = SpliceForeignFile
  { -- | Foreign source language expected by GHC.
    spliceForeignFileLang :: !ForeignSrcLang
  , -- | Source path as registered by TH.
    spliceForeignFilePath :: !FilePath
  }
  deriving (Eq, Show)

instance Binary SpliceForeignFile where
  put foreignFile = do
    putForeignSrcLang (spliceForeignFileLang foreignFile)
    put (spliceForeignFilePath foreignFile)
  get =
    SpliceForeignFile <$> getForeignSrcLang <*> get

-- | Stable textual representation of GHC's foreign source language.
foreignSrcLangToStr :: ForeignSrcLang -> String
foreignSrcLangToStr = \case
  LangC -> "c"
  LangCxx -> "cxx"
  LangObjc -> "objc"
  LangObjcxx -> "objcxx"
  LangAsm -> "asm"
  LangJs -> "js"
  RawObject -> "raw-object"

-- | Parse the protocol representation back to GHC's foreign source language.
putForeignSrcLang :: ForeignSrcLang -> Put
putForeignSrcLang = \case
  LangC -> put (0 :: Word8)
  LangCxx -> put (1 :: Word8)
  LangObjc -> put (2 :: Word8)
  LangObjcxx -> put (3 :: Word8)
  LangAsm -> put (4 :: Word8)
  LangJs -> put (5 :: Word8)
  RawObject -> put (6 :: Word8)

getForeignSrcLang :: Get ForeignSrcLang
getForeignSrcLang =
  get >>= \case
    0 -> pure LangC
    1 -> pure LangCxx
    2 -> pure LangObjc
    3 -> pure LangObjcxx
    4 -> pure LangAsm
    5 -> pure LangJs
    6 -> pure RawObject
    tag -> fail ("unknown foreign source language tag: " <> show (tag :: Word8))

-- | Result of host-side splice evaluation plus effects to replay in cross GHC.
data SpliceResult = SpliceResult
  { -- | Template Haskell expression payload.
    spliceResultExpression :: !(Maybe TH.Exp)
  , -- | Template Haskell pattern payload.
    spliceResultPattern :: !(Maybe TH.Pat)
  , -- | Template Haskell type payload.
    spliceResultType :: !(Maybe TH.Type)
  , -- | Template Haskell declaration payload.
    spliceResultDeclarations :: !(Maybe [TH.Dec])
  , -- | Binary-encoded 'GHC.Serialized.Serialized' for annotation wrappers.
    spliceResultAnnotationWrapper :: !(Maybe [Word8])
  , -- | Files registered through @addDependentFile@ while evaluating the splice.
    spliceResultDependentFiles :: ![FilePath]
  , -- | Foreign files registered through @addForeignFilePath@.
    spliceResultForeignFiles :: ![SpliceForeignFile]
  , -- | Top-level declarations registered through @addTopDecls@.
    spliceResultAddedTopDecls :: ![TH.Dec]
  , -- | Diagnostics reported by host-side TH and replayed in cross GHC.
    spliceResultDiagnostics :: ![SpliceDiagnostic]
  }
  deriving (Eq, Show)

instance Binary SpliceResult where
  put result = do
    put (spliceResultExpression result)
    put (spliceResultPattern result)
    put (spliceResultType result)
    put (spliceResultDeclarations result)
    put (spliceResultAnnotationWrapper result)
    put (spliceResultDependentFiles result)
    put (spliceResultForeignFiles result)
    put (spliceResultAddedTopDecls result)
    put (spliceResultDiagnostics result)
  get =
    SpliceResult
      <$> get
      <*> get
      <*> get
      <*> get
      <*> get
      <*> get
      <*> get
      <*> get
      <*> get

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

instance Binary SourceSpan where
  put spanInfo = do
    put (sourceSpanStartLine spanInfo)
    put (sourceSpanStartColumn spanInfo)
    put (sourceSpanEndLine spanInfo)
    put (sourceSpanEndColumn spanInfo)
  get =
    SourceSpan <$> get <*> get <*> get <*> get

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

instance Binary SpliceKind where
  put = \case
    ExpressionSplice -> put (0 :: Word8)
    TypeSplice -> put (1 :: Word8)
    PatternSplice -> put (2 :: Word8)
    DeclarationSplice -> put (3 :: Word8)
    AnnotationWrapperSplice -> put (4 :: Word8)
  get =
    get >>= \case
      0 -> pure ExpressionSplice
      1 -> pure TypeSplice
      2 -> pure PatternSplice
      3 -> pure DeclarationSplice
      4 -> pure AnnotationWrapperSplice
      tag -> fail ("unknown splice kind tag: " <> show (tag :: Word8))

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

instance Binary SpliceRequest where
  put request = do
    put (requestId request)
    put (requestModuleName request)
    put (requestComponentUnitId request)
    put (requestSourceFile request)
    put (requestSpliceKind request)
    put (requestSourceSpan request)
    put (requestSpliceKey request)
    put (requestSpliceExpression request)
    put (requestCrossGhcVersion request)
    put (requestHostPackageIds request)
    put (requestHostSourceDirs request)
    put (requestHostGhcOptions request)
  get =
    SpliceRequest <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get

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

instance Binary SpliceResponse where
  put = \case
    SpliceOk reqId spliceResult -> do
      put (0 :: Word8)
      put reqId
      put spliceResult
    SpliceError reqId message -> do
      put (1 :: Word8)
      put reqId
      put message
  get =
    get >>= \case
      0 -> SpliceOk <$> get <*> get
      1 -> SpliceError <$> get <*> get
      tag -> fail ("unknown splice response tag: " <> show (tag :: Word8))

-- | Write one length-prefixed binary request frame.
writeRequest :: Handle -> SpliceRequest -> IO ()
writeRequest = writeMessage

-- | Read one length-prefixed binary request frame.
readRequest :: Handle -> IO (Either String SpliceRequest)
readRequest = readMessage

-- | Write one length-prefixed binary response frame.
writeResponse :: Handle -> SpliceResponse -> IO ()
writeResponse = writeMessage

-- | Read one length-prefixed binary response frame.
readResponse :: Handle -> IO (Either String SpliceResponse)
readResponse = readMessage

writeMessage :: Binary a => Handle -> a -> IO ()
writeMessage handle message = do
  let payload = encode message
      frame = runPut (putWord32be (fromIntegral (BL.length payload))) <> payload
  BL.hPut handle frame
  hFlush handle

readMessage :: Binary a => Handle -> IO (Either String a)
readMessage handle = do
  frameOrError <- try $ do
    lengthBytes <- BL.hGet handle 4
    if BL.length lengthBytes /= 4
      then
        fail
          ( "incomplete protocol frame length: expected 4 bytes, got "
              <> show (BL.length lengthBytes)
          )
      else do
        payloadLength <- decodeFrameLength lengthBytes
        payload <- BL.hGet handle (fromIntegral payloadLength)
        if BL.length payload /= fromIntegral payloadLength
          then
            fail
              ( "incomplete protocol payload: expected "
                  <> show payloadLength
                  <> " bytes, got "
                  <> show (BL.length payload)
              )
          else
            pure payload
  pure $
    case frameOrError of
      Left err ->
        Left ("protocol frame read failed: " <> show (err :: IOException))
      Right payload ->
        decodeMessage payload

decodeFrameLength :: BL.ByteString -> IO Word32
decodeFrameLength bytes =
  case runGetOrFail getWord32be bytes of
    Left (_, _, err) ->
      fail ("invalid protocol frame length: " <> err)
    Right (_, _, payloadLength) ->
      pure payloadLength

decodeMessage :: Binary a => BL.ByteString -> Either String a
decodeMessage payload =
  case decodeOrFail payload of
    Left (_, _, err) ->
      Left ("protocol payload decode failed: " <> err)
    Right (remaining, _, message)
      | BL.null remaining -> Right message
      | otherwise -> Left ("protocol payload had trailing bytes: " <> show (BL.length remaining))
