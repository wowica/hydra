{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Hydra.Cluster.Scenarios where

import Hydra.Prelude

import qualified Cardano.Api.UTxO as UTxO
import CardanoClient (
  QueryPoint (QueryTip),
  awaitTransaction,
  buildTransaction,
  queryProtocolParameters,
  queryTip,
  submitTransaction,
  submitTx,
 )
import CardanoNode (RunningNode (..))
import Control.Lens ((^?))
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Lens (key, _JSON)
import Data.Aeson.Types (parseMaybe)
import qualified Data.Set as Set
import Hydra.API.RestServer (DraftCommitTxRequest (..), DraftCommitTxResponse (..), ScriptInfo (..))
import Hydra.Cardano.Api (
  AddressInEra,
  Key (SigningKey, getVerificationKey),
  Lovelace (..),
  PaymentKey,
  PlutusScriptV2,
  ProtocolParameters,
  ShelleyWitnessSigningKey (WitnessPaymentKey),
  ToScriptData,
  Tx,
  TxId,
  UTxO,
  fromPlutusScript,
  makeShelleyKeyWitness,
  makeSignedTransaction,
  mkScriptAddress,
  mkTxOutAutoBalance,
  mkTxOutDatumHash,
  mkVkAddress,
  selectLovelace,
  throwErrorAsException,
  toScriptData,
  txOutAddress,
  txOutValue,
  pattern ReferenceScriptNone,
 )
import Hydra.Cardano.Api.Pretty (renderTxWithUTxO)
import Hydra.Chain (HeadId)
import Hydra.Chain.CardanoClient (
  QueryPoint (QueryTip),
  awaitTransaction,
  buildTransaction,
  queryProtocolParameters,
  queryTip,
  submitTransaction,
 )
import Hydra.Chain.Direct.Wallet (signWith)
import Hydra.Cluster.Faucet (Marked (Fuel, Normal), queryMarkedUTxO, seedFromFaucet, seedFromFaucet_)
import qualified Hydra.Cluster.Faucet as Faucet
import Hydra.Cluster.Fixture (Actor (..), actorName, alice, aliceSk, aliceVk, bob, bobSk, bobVk)
import Hydra.Cluster.Util (chainConfigFor, keysFor)
import Hydra.ContestationPeriod (ContestationPeriod (UnsafeContestationPeriod))
import Hydra.Ledger (IsTx (balance))
import Hydra.Ledger.Cardano (genKeyPair)
import Hydra.Logging (Tracer, traceWith)
import Hydra.Options (ChainConfig, networkId, startChainFrom)
import Hydra.Party (Party)
import HydraNode (EndToEndLog (..), externalCommit, input, output, send, waitFor, waitForAllMatch, waitMatch, withHydraNode)
import Network.HTTP.Req (
  JsonResponse,
  POST (POST),
  ReqBodyJson (ReqBodyJson),
  defaultHttpConfig,
  http,
  port,
  req,
  responseBody,
  responseStatusCode,
  runReq,
  (/:),
 )
import qualified PlutusLedgerApi.Test.Examples as Plutus
import Test.Hspec.Expectations (shouldBe)
import Test.QuickCheck (generate)

restartedNodeCanObserveCommitTx :: Tracer IO EndToEndLog -> FilePath -> RunningNode -> TxId -> IO ()
restartedNodeCanObserveCommitTx tracer workDir cardanoNode hydraScriptsTxId = do
  let clients = [Alice, Bob]
  [(aliceCardanoVk, _), (bobCardanoVk, _)] <- forM clients keysFor
  seedFromFaucet_ cardanoNode aliceCardanoVk 100_000_000 Fuel (contramap FromFaucet tracer)
  seedFromFaucet_ cardanoNode bobCardanoVk 100_000_000 Fuel (contramap FromFaucet tracer)

  let contestationPeriod = UnsafeContestationPeriod 1
  aliceChainConfig <-
    chainConfigFor Alice workDir nodeSocket [Bob] contestationPeriod
      <&> \config -> (config :: ChainConfig){networkId}

  bobChainConfig <-
    chainConfigFor Bob workDir nodeSocket [Alice] contestationPeriod
      <&> \config -> (config :: ChainConfig){networkId}

  withHydraNode tracer bobChainConfig workDir 1 bobSk [aliceVk] [1, 2] hydraScriptsTxId $ \n1 -> do
    headId <- withHydraNode tracer aliceChainConfig workDir 2 aliceSk [bobVk] [1, 2] hydraScriptsTxId $ \n2 -> do
      send n1 $ input "Init" []
      -- XXX: might need to tweak the wait time
      waitForAllMatch 10 [n1, n2] $ headIsInitializingWith (Set.fromList [alice, bob])

    -- n1 does a commit while n2 is down
    externalCommit n1 mempty >>= submitTx cardanoNode
    waitFor tracer 10 [n1] $
      output "Committed" ["party" .= bob, "utxo" .= object mempty, "headId" .= headId]

    -- n2 is back and does observe the commit
    withHydraNode tracer aliceChainConfig workDir 2 aliceSk [bobVk] [1, 2] hydraScriptsTxId $ \n2 -> do
      waitFor tracer 10 [n2] $
        output "Committed" ["party" .= bob, "utxo" .= object mempty, "headId" .= headId]
 where
  RunningNode{nodeSocket, networkId} = cardanoNode

restartedNodeCanAbort :: Tracer IO EndToEndLog -> FilePath -> RunningNode -> TxId -> IO ()
restartedNodeCanAbort tracer workDir cardanoNode hydraScriptsTxId = do
  refuelIfNeeded tracer cardanoNode Alice 100_000_000
  let contestationPeriod = UnsafeContestationPeriod 2
  aliceChainConfig <-
    chainConfigFor Alice workDir nodeSocket [] contestationPeriod
      -- we delibelately do not start from a chain point here to highlight the
      -- need for persistence
      <&> \config -> config{networkId, startChainFrom = Nothing}

  headId1 <- withHydraNode tracer aliceChainConfig workDir 1 aliceSk [] [1] hydraScriptsTxId $ \n1 -> do
    send n1 $ input "Init" []
    -- XXX: might need to tweak the wait time
    waitMatch 10 n1 $ headIsInitializingWith (Set.fromList [alice])

  withHydraNode tracer aliceChainConfig workDir 1 aliceSk [] [1] hydraScriptsTxId $ \n1 -> do
    -- Also expect to see past server outputs replayed
    headId2 <- waitMatch 10 n1 $ headIsInitializingWith (Set.fromList [alice])
    headId1 `shouldBe` headId2
    send n1 $ input "Abort" []
    waitFor tracer 10 [n1] $
      output "HeadIsAborted" ["utxo" .= object mempty, "headId" .= headId2]
 where
  RunningNode{nodeSocket, networkId} = cardanoNode

-- | Step through the full life cycle of a Hydra Head with only a single
-- participant. This scenario is also used by the smoke test run via the
-- `hydra-cluster` executable.
singlePartyHeadFullLifeCycle ::
  Tracer IO EndToEndLog ->
  FilePath ->
  RunningNode ->
  TxId ->
  IO ()
singlePartyHeadFullLifeCycle tracer workDir node@RunningNode{networkId} hydraScriptsTxId =
  (`finally` returnFundsToFaucet tracer node Alice) $ do
    refuelIfNeeded tracer node Alice 25_000_000
    -- Start hydra-node on chain tip
    tip <- queryTip networkId nodeSocket
    let contestationPeriod = UnsafeContestationPeriod 100
    aliceChainConfig <-
      chainConfigFor Alice workDir nodeSocket [] contestationPeriod
        <&> \config -> config{networkId, startChainFrom = Just tip}
    withHydraNode tracer aliceChainConfig workDir 1 aliceSk [] [1] hydraScriptsTxId $ \n1 -> do
      -- Initialize & open head
      send n1 $ input "Init" []
      headId <- waitMatch 600 n1 $ headIsInitializingWith (Set.fromList [alice])
      -- Commit nothing for now
      externalCommit n1 mempty >>= submitTx node
      waitFor tracer 600 [n1] $
        output "HeadIsOpen" ["utxo" .= object mempty, "headId" .= headId]
      -- Close head
      send n1 $ input "Close" []
      deadline <- waitMatch 600 n1 $ \v -> do
        guard $ v ^? key "tag" == Just "HeadIsClosed"
        guard $ v ^? key "headId" == Just (toJSON headId)
        v ^? key "contestationDeadline" . _JSON
      -- Expect to see ReadyToFanout within 600 seconds after deadline.
      -- XXX: We still would like to have a network-specific time here
      remainingTime <- diffUTCTime deadline <$> getCurrentTime
      waitFor tracer (remainingTime + 60) [n1] $
        output "ReadyToFanout" ["headId" .= headId]
      send n1 $ input "Fanout" []
      waitFor tracer 600 [n1] $
        output "HeadIsFinalized" ["utxo" .= object mempty, "headId" .= headId]
    traceRemainingFunds Alice
 where
  RunningNode{nodeSocket} = node

  traceRemainingFunds actor = do
    (actorVk, _) <- keysFor actor
    (fuelUTxO, otherUTxO) <- queryMarkedUTxO node actorVk
    traceWith tracer RemainingFunds{actor = actorName actor, fuelUTxO, otherUTxO}

-- | Ensures the _old_ way of committing (using Fuel) still works.
singlePartyCommitsUsingFuel ::
  Tracer IO EndToEndLog ->
  FilePath ->
  RunningNode ->
  TxId ->
  IO ()
singlePartyCommitsUsingFuel tracer workDir node hydraScriptsTxId =
  (`finally` returnFundsToFaucet tracer node Alice) $ do
    refuelIfNeeded tracer node Alice 25_000_000

    (alicesVk, _) <- keysFor Alice

    let contestationPeriod = UnsafeContestationPeriod 100
    aliceChainConfig <- chainConfigFor Alice workDir nodeSocket [] contestationPeriod

    -- submit the tx using alice's public key to get a utxo to commit
    utxoToCommit <- seedFromFaucet node alicesVk 2_000_000 Fuel (contramap FromFaucet tracer)

    let hydraNodeId = 1

    withHydraNode tracer aliceChainConfig workDir hydraNodeId aliceSk [] [1] hydraScriptsTxId $ \n1 -> do
      send n1 $ input "Init" []
      headId <- waitMatch 60 n1 $ headIsInitializingWith (Set.fromList [alice])

      send n1 $ input "Commit" ["utxo" .= utxoToCommit]

      waitFor tracer 60 [n1] $
        output "HeadIsOpen" ["utxo" .= utxoToCommit, "headId" .= headId]
 where
  RunningNode{nodeSocket} = node

-- | Single hydra-node where the commit is done from an external UTxO owned by a
-- verification key.
singlePartyCommitsFromExternal ::
  Tracer IO EndToEndLog ->
  FilePath ->
  RunningNode ->
  TxId ->
  IO ()
singlePartyCommitsFromExternal tracer workDir node hydraScriptsTxId =
  (`finally` returnFundsToFaucet tracer node Alice) $ do
    refuelIfNeeded tracer node Alice 25_000_000
    aliceChainConfig <- chainConfigFor Alice workDir nodeSocket [] $ UnsafeContestationPeriod 100
    let hydraNodeId = 1
    withHydraNode tracer aliceChainConfig workDir hydraNodeId aliceSk [] [1] hydraScriptsTxId $ \n1 -> do
      send n1 $ input "Init" []
      headId <- waitMatch 60 n1 $ headIsInitializingWith (Set.fromList [alice])

      -- these keys should mimic external wallet keys needed to sign the commit tx
      (externalVk, externalSk) <- generate genKeyPair
      -- submit the tx using our external user key to get a utxo to commit
      utxoToCommit <- seedFromFaucet node externalVk 2_000_000 Normal (contramap FromFaucet tracer)

      -- Request to build a draft commit tx from hydra-node
      let clientPayload = DraftCommitTxRequest @Tx utxoToCommit []

      response <-
        runReq defaultHttpConfig $
          req
            POST
            (http "127.0.0.1" /: "commit")
            (ReqBodyJson clientPayload)
            (Proxy :: Proxy (JsonResponse (DraftCommitTxResponse Tx)))
            (port $ 4000 + hydraNodeId)

      responseStatusCode response `shouldBe` 200

      let DraftCommitTxResponse commitTx = responseBody response

      -- sign and submit the tx with our external user key
      let signedCommitTx = signWith externalSk commitTx
      submitTransaction networkId nodeSocket signedCommitTx

      waitFor tracer 60 [n1] $
        output "HeadIsOpen" ["utxo" .= utxoToCommit, "headId" .= headId]
 where
  RunningNode{networkId, nodeSocket} = node

-- | Single hydra-node where the commit is done from an external UTxO owned by a
-- script which requires providing script, datum and redeemer instead of
-- signing the transaction.
singlePartyCommitsFromExternalScript ::
  Tracer IO EndToEndLog ->
  FilePath ->
  RunningNode ->
  TxId ->
  IO ()
singlePartyCommitsFromExternalScript tracer workDir node hydraScriptsTxId =
  (`finally` returnFundsToFaucet tracer node Alice) $ do
    refuelIfNeeded tracer node Alice 25_000_000
    aliceChainConfig <- chainConfigFor Alice workDir nodeSocket [] $ UnsafeContestationPeriod 100
    let hydraNodeId = 1
    withHydraNode tracer aliceChainConfig workDir hydraNodeId aliceSk [] [1] hydraScriptsTxId $ \n1 -> do
      send n1 $ input "Init" []
      headId <- waitMatch 600 n1 $ headIsInitializingWith (Set.fromList [alice])

      let script = fromPlutusScript @PlutusScriptV2 $ Plutus.alwaysSucceedingNAryFunction 2
          scriptAddress = mkScriptAddress @PlutusScriptV2 networkId script
          reedemer = ()
          datum = ()
          scriptInfo = ScriptInfo (toScriptData reedemer) (toScriptData datum) script

      (someVk, someSk) <- generate genKeyPair
      pparams <- queryProtocolParameters networkId nodeSocket QueryTip

      -- TODO: createScriptOutput spends from faucet directly
      normalUTxO <- seedFromFaucet node someVk 10_000_000 Normal (contramap FromFaucet tracer)
      scriptUtxo1 <- createScriptOutput pparams scriptAddress someSk normalUTxO datum
      someUtxo2 <- seedFromFaucet node someVk 10_000_000 Normal (contramap FromFaucet tracer)
      scriptUtxo2 <- createScriptOutput pparams scriptAddress someSk someUtxo2 datum
      let scriptUtxos = scriptUtxo1 <> scriptUtxo2
          scriptInfos = (\(txIn, txOut) -> (txIn, txOut, scriptInfo)) <$> UTxO.pairs scriptUtxos

      -- Request to build a draft commit tx from hydra-node
      let clientPayload = DraftCommitTxRequest @Tx scriptUtxos scriptInfos
      response <-
        runReq defaultHttpConfig $
          req
            POST
            (http "127.0.0.1" /: "commit")
            (ReqBodyJson clientPayload)
            (Proxy :: Proxy (JsonResponse (DraftCommitTxResponse Tx)))
            (port $ 4000 + hydraNodeId)
      responseStatusCode response `shouldBe` 200
      let DraftCommitTxResponse commitTx = responseBody response

      traceWith tracer $ SubmitCommitTx commitTx
      -- TODO: remove render tx
      putTextLn . toText $ renderTxWithUTxO scriptUtxos commitTx
      submitTransaction networkId nodeSocket commitTx

      waitFor tracer 600 [n1] $
        output "HeadIsOpen" ["utxo" .= scriptUtxos, "headId" .= headId]
 where
  RunningNode{networkId, nodeSocket} = node

  -- TODO: refactor into simpler
  createScriptOutput ::
    ToScriptData a =>
    ProtocolParameters ->
    AddressInEra ->
    SigningKey PaymentKey ->
    UTxO ->
    a ->
    IO UTxO
  createScriptOutput pparams scriptAddress sk utxo datum = do
    let outputs = [scriptTxOut]
        totalDeposit = sum (selectLovelace . txOutValue <$> outputs)
        someUTxO =
          maybe mempty UTxO.singleton $
            UTxO.find (\o -> selectLovelace (txOutValue o) > totalDeposit) utxo
    buildTransaction
      networkId
      nodeSocket
      changeAddress
      someUTxO
      collateralTxIns
      outputs
      >>= \case
        Left e ->
          throwErrorAsException e
        Right body -> do
          let tx = makeSignedTransaction [makeShelleyKeyWitness body (WitnessPaymentKey sk)] body
          submitTransaction networkId nodeSocket tx
          newUtxo <- awaitTransaction networkId nodeSocket tx
          let scriptUtxo = UTxO.filter (\out -> txOutAddress out == scriptAddress) newUtxo
          pure scriptUtxo
   where
    collateralTxIns = mempty

    vk = getVerificationKey sk

    changeAddress = mkVkAddress networkId vk

    scriptTxOut =
      mkTxOutAutoBalance
        pparams
        scriptAddress
        mempty
        (mkTxOutDatumHash datum)
        ReferenceScriptNone

-- | Initialize open and close a head on a real network and ensure contestation
-- period longer than the time horizon is possible. For this it is enough that
-- we can close a head and not wait for the deadline.
canCloseWithLongContestationPeriod ::
  Tracer IO EndToEndLog ->
  FilePath ->
  RunningNode ->
  TxId ->
  IO ()
canCloseWithLongContestationPeriod tracer workDir node@RunningNode{networkId} hydraScriptsTxId = do
  refuelIfNeeded tracer node Alice 100_000_000
  -- Start hydra-node on chain tip
  tip <- queryTip networkId nodeSocket
  let oneWeek = UnsafeContestationPeriod (60 * 60 * 24 * 7)
  aliceChainConfig <-
    chainConfigFor Alice workDir nodeSocket [] oneWeek
      <&> \config -> config{networkId, startChainFrom = Just tip}
  withHydraNode tracer aliceChainConfig workDir 1 aliceSk [] [1] hydraScriptsTxId $ \n1 -> do
    -- Initialize & open head
    send n1 $ input "Init" []
    headId <- waitMatch 60 n1 $ headIsInitializingWith (Set.fromList [alice])
    -- Commit nothing for now
    externalCommit n1 mempty >>= submitTx node
    waitFor tracer 60 [n1] $
      output "HeadIsOpen" ["utxo" .= object mempty, "headId" .= headId]
    -- Close head
    send n1 $ input "Close" []
    void $
      waitMatch 60 n1 $ \v -> do
        guard $ v ^? key "tag" == Just "HeadIsClosed"
  traceRemainingFunds Alice
 where
  RunningNode{nodeSocket} = node

  traceRemainingFunds actor = do
    (actorVk, _) <- keysFor actor
    (fuelUTxO, otherUTxO) <- queryMarkedUTxO node actorVk
    traceWith tracer RemainingFunds{actor = actorName actor, fuelUTxO, otherUTxO}

-- | Refuel given 'Actor' with given 'Lovelace' if current marked UTxO is below that amount.
refuelIfNeeded ::
  Tracer IO EndToEndLog ->
  RunningNode ->
  Actor ->
  Lovelace ->
  IO ()
refuelIfNeeded tracer node actor amount = do
  (actorVk, _) <- keysFor actor
  (fuelUTxO, otherUTxO) <- queryMarkedUTxO node actorVk
  traceWith tracer $ StartingFunds{actor = actorName actor, fuelUTxO, otherUTxO}
  let fuelBalance = selectLovelace $ balance @Tx fuelUTxO
  when (fuelBalance < amount) $ do
    utxo <- seedFromFaucet node actorVk amount Fuel (contramap FromFaucet tracer)
    traceWith tracer $ RefueledFunds{actor = actorName actor, refuelingAmount = amount, fuelUTxO = utxo}

-- | Return the remaining funds to the faucet
returnFundsToFaucet ::
  Tracer IO EndToEndLog ->
  RunningNode ->
  Actor ->
  IO ()
returnFundsToFaucet tracer =
  Faucet.returnFundsToFaucet (contramap FromFaucet tracer)

headIsInitializingWith :: Set Party -> Value -> Maybe HeadId
headIsInitializingWith expectedParties v = do
  guard $ v ^? key "tag" == Just "HeadIsInitializing"
  parties <- v ^? key "parties"
  guard $ parties == toJSON expectedParties
  headId <- v ^? key "headId"
  parseMaybe parseJSON headId
