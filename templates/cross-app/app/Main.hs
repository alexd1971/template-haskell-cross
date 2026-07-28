module Main (main) where

import App.Payload (payloadJson)

main :: IO ()
main =
  putStrLn payloadJson
