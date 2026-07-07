{-# LANGUAGE OverloadedStrings #-}

-- | JSON-lines protocol shared by the cross-side plugin and host TH worker.
--
-- The protocol deliberately transports generated Haskell text rather than GHC
-- AST values. The receiving compiler parses that text locally into its own
-- @GhcPs@ AST.
module THCross.Protocol
  ( SourceSpan (..)
  , SpliceKind (..)
  , SpliceRequest (..)
  , SpliceResponse (..)
  , decodeRequestLine
  , decodeResponseLine
  , encodeRequestLine
  , encodeResponseLine
  , spliceKindText
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import qualified Data.ByteString.Lazy as BL

-- | 1-based source span for the splice as seen by the cross GHC process.
data SourceSpan = SourceSpan
  { sourceSpanStartLine :: !Int
  , sourceSpanStartColumn :: !Int
  , sourceSpanEndLine :: !Int
  , sourceSpanEndColumn :: !Int
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

-- | Template Haskell splice category.
data SpliceKind
  = ExpressionSplice
  | TypeSplice
  | PatternSplice
  | DeclarationSplice
  | AnnotationWrapperSplice
  deriving (Eq, Show)

instance ToJSON SpliceKind where
  toJSON = toJSON . spliceKindText

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
spliceKindText :: SpliceKind -> String
spliceKindText ExpressionSplice = "expression"
spliceKindText TypeSplice = "type"
spliceKindText PatternSplice = "pattern"
spliceKindText DeclarationSplice = "declaration"
spliceKindText AnnotationWrapperSplice = "annotation-wrapper"

-- | Request sent by the cross-side plugin to the native host worker.
data SpliceRequest = SpliceRequest
  { requestId :: !String
  , requestModuleName :: !String
  , requestSourceFile :: !FilePath
  , requestSpliceKind :: !SpliceKind
  , requestSourceSpan :: !SourceSpan
  , requestSpliceExpression :: !String
  , requestCrossGhcVersion :: !String
  }
  deriving (Eq, Show)

instance ToJSON SpliceRequest where
  toJSON request =
    object
      [ "requestId" .= requestId request
      , "module" .= requestModuleName request
      , "sourceFile" .= requestSourceFile request
      , "spliceKind" .= requestSpliceKind request
      , "sourceSpan" .= requestSourceSpan request
      , "spliceExpression" .= requestSpliceExpression request
      , "crossGhcVersion" .= requestCrossGhcVersion request
      ]

instance FromJSON SpliceRequest where
  parseJSON =
    withObject "SpliceRequest" $ \obj ->
      SpliceRequest
        <$> obj .: "requestId"
        <*> obj .: "module"
        <*> obj .: "sourceFile"
        <*> obj .: "spliceKind"
        <*> obj .: "sourceSpan"
        <*> obj .: "spliceExpression"
        <*> obj .: "crossGhcVersion"

-- | Response returned by the native host worker.
data SpliceResponse
  = SpliceOk
      { responseRequestId :: !String
      , responseGeneratedHaskell :: !String
      }
  | SpliceError
      { responseRequestId :: !String
      , responseMessage :: !String
      }
  deriving (Eq, Show)

instance ToJSON SpliceResponse where
  toJSON response =
    case response of
      SpliceOk reqId generated ->
        object
          [ "requestId" .= reqId
          , "status" .= ("ok" :: String)
          , "generatedHaskell" .= generated
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
        "ok" -> SpliceOk reqId <$> obj .: "generatedHaskell"
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

encodeJsonLine :: ToJSON a => a -> BL.ByteString
encodeJsonLine value = encode value <> "\n"
