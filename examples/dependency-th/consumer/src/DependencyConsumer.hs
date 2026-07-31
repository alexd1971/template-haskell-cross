module DependencyConsumer
  ( consumerValue
  ) where

import DependencyTH (dependencyGeneratedValue)

consumerValue :: String
consumerValue = dependencyGeneratedValue
