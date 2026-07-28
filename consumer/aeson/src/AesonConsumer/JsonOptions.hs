module AesonConsumer.JsonOptions
  ( dropSuffix
  ) where

dropSuffix :: String -> String -> String
dropSuffix suffix value =
  let suffixLength = length suffix
      valueLength = length value
   in if suffixLength <= valueLength
        && drop (valueLength - suffixLength) value == suffix
        then take (valueLength - suffixLength) value
        else value
