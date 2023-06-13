{-# LANGUAGE TypeApplications #-}

module Hydra.API.RestServerSpec where

import Hydra.Prelude
import Test.Hydra.Prelude

import Data.Aeson.Lens (key)
import Hydra.API.RestServer (DraftCommitTxRequest, DraftCommitTxResponse)
import Hydra.Chain.Direct.State ()
import Hydra.JSONSchema (SpecificationSelector, prop_specIsComplete, prop_validateJSONSchema)
import Hydra.Ledger.Cardano (Tx)
import Test.Aeson.GenericSpecs (roundtripAndGoldenSpecs)
import Test.QuickCheck.Property (conjoin, property, withMaxSuccess)

spec :: Spec
spec = parallel $ do
  roundtripAndGoldenSpecs
    (Proxy @(ReasonablySized (DraftCommitTxResponse Tx)))

  roundtripAndGoldenSpecs
    (Proxy @(ReasonablySized (DraftCommitTxRequest Tx)))

  prop "Validate /commit publish api schema" $
    property $
      withMaxSuccess 1 $ do
        conjoin
          [ prop_validateJSONSchema @(DraftCommitTxRequest Tx) "api" (key "channels" . key "/commit" . key "publish" . key "message" . key "payload")
          , prop_specIsComplete @(ReasonablySized (DraftCommitTxRequest Tx)) "api" apiSpecificationSelector
          ]

  prop "Validate /commit subscribe api schema" $
    property $
      withMaxSuccess 1 $ do
        conjoin
          [ prop_validateJSONSchema @(DraftCommitTxResponse Tx) "api" (key "channels" . key "/commit" . key "subscribe" . key "message" . key "payload")
          , prop_specIsComplete @(ReasonablySized (DraftCommitTxResponse Tx)) "api" apiSpecificationSelector
          ]

apiSpecificationSelector :: SpecificationSelector
apiSpecificationSelector = key "components" . key "messages"
