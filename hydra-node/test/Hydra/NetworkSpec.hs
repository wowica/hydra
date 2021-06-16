{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Test the real networking layer
module Hydra.NetworkSpec where

import Cardano.Prelude hiding (atomically, onException, threadDelay)

import Cardano.Binary (FromCBOR, ToCBOR, fromCBOR, toCBOR)
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Write (toLazyByteString)
import Control.Monad.Class.MonadAsync (concurrently_)
import Control.Monad.Class.MonadSTM (
  MonadSTM (..),
  newTVarIO,
  readTVar,
 )
import Control.Monad.Class.MonadThrow (MonadCatch, onException)
import Hydra.HeadLogic (HydraMessage (..), Snapshot (..))
import Hydra.Ledger.Mock (MockTx (..))
import Hydra.Logging (Tracer, traceInTVar)
import Hydra.Network (Network)
import Hydra.Network.Ouroboros (broadcast, withOuroborosNetwork)
import Hydra.Network.ZeroMQ (withZeroMQNetwork)
import Say (say)
import Test.HUnit.Lang (HUnitFailure)
import Test.Hspec (Spec, describe, it, shouldReturn)
import Test.QuickCheck (
  Arbitrary (..),
  arbitrary,
  frequency,
  oneof,
  property,
 )
import Test.Util (arbitraryNatural, failAfter)

spec :: Spec
spec = describe "Networking layer" $ do
  let requestTx :: HydraMessage MockTx
      requestTx = ReqTx (ValidTx 1)

      lo = "127.0.0.1"

  describe "Ouroboros Network" $ do
    it "broadcasts messages to single connected peer" $ do
      received <- newEmptyMVar
      showLogsOnFailure $ \tracer -> failAfter 10 $ do
        withOuroborosNetwork tracer (lo, 45678) [(lo, 45679)] (const @_ @(HydraMessage MockTx) $ pure ()) $ \hn1 ->
          withOuroborosNetwork @(HydraMessage MockTx) tracer (lo, 45679) [(lo, 45678)] (putMVar received) $ \_ -> do
            broadcast hn1 requestTx
            takeMVar received `shouldReturn` requestTx

    it "broadcasts messages between 3 connected peers" $ do
      node1received <- newEmptyMVar
      node2received <- newEmptyMVar
      node3received <- newEmptyMVar
      showLogsOnFailure $ \tracer -> failAfter 10 $ do
        withOuroborosNetwork @(HydraMessage MockTx) tracer (lo, 45678) [(lo, 45679), (lo, 45680)] (putMVar node1received) $ \hn1 ->
          withOuroborosNetwork tracer (lo, 45679) [(lo, 45678), (lo, 45680)] (putMVar node2received) $ \hn2 -> do
            withOuroborosNetwork tracer (lo, 45680) [(lo, 45678), (lo, 45679)] (putMVar node3received) $ \hn3 -> do
              concurrently_ (assertBroadcastFrom requestTx hn1 [node2received, node3received]) $
                concurrently_
                  (assertBroadcastFrom requestTx hn2 [node1received, node3received])
                  (assertBroadcastFrom requestTx hn3 [node2received, node1received])

  describe "0MQ Network" $
    it "broadcasts messages between 3 connected peers" $ do
      node1received <- newEmptyMVar
      node2received <- newEmptyMVar
      node3received <- newEmptyMVar
      showLogsOnFailure $ \tracer -> failAfter 10 $ do
        withZeroMQNetwork tracer (lo, 55677) [(lo, 55678), (lo, 55679)] (putMVar node1received) $ \hn1 ->
          withZeroMQNetwork tracer (lo, 55678) [(lo, 55677), (lo, 55679)] (putMVar node2received) $ \hn2 ->
            withZeroMQNetwork tracer (lo, 55679) [(lo, 55677), (lo, 55678)] (putMVar node3received) $ \hn3 -> do
              concurrently_ (assertBroadcastFrom requestTx hn1 [node2received, node3received]) $
                concurrently_
                  (assertBroadcastFrom requestTx hn2 [node1received, node3received])
                  (assertBroadcastFrom requestTx hn3 [node2received, node1received])

  describe "Serialisation" $ do
    it "can roundtrip CBOR encoding/decoding of HydraMessage" $ property $ prop_canRoundtripCBOREncoding @(HydraMessage MockTx)

assertBroadcastFrom :: (Eq a, Show a) => a -> Network IO a -> [MVar a] -> IO ()
assertBroadcastFrom requestTx network receivers =
  tryBroadcast `catch` \(_ :: HUnitFailure) -> tryBroadcast
 where
  tryBroadcast = do
    broadcast network requestTx
    forM_ receivers $ \var -> failAfter 1 $ takeMVar var `shouldReturn` requestTx

-- TODO(MB): Possibly relocate this function for re-use?
showLogsOnFailure ::
  (MonadSTM m, MonadCatch m, MonadIO m, Show msg) =>
  (Tracer m msg -> m a) ->
  m a
showLogsOnFailure action = do
  tvar <- newTVarIO []
  action (traceInTVar tvar)
    `onException` (atomically (readTVar tvar) >>= mapM_ (say . show))

instance Arbitrary (HydraMessage MockTx) where
  arbitrary =
    oneof
      [ ReqTx <$> arbitrary
      , AckTx <$> arbitraryNatural <*> arbitrary
      , pure ConfTx
      , ReqSn <$> arbitraryNatural <*> arbitrary
      , AckSn <$> arbitrary
      , pure ConfSn
      , Ping <$> arbitraryNatural
      ]

instance Arbitrary (Snapshot MockTx) where
  arbitrary = Snapshot <$> arbitraryNatural <*> arbitrary <*> arbitrary

instance Arbitrary MockTx where
  arbitrary =
    frequency
      [ (10, ValidTx <$> arbitrary)
      , (1, pure InvalidTx)
      ]

prop_canRoundtripCBOREncoding ::
  (ToCBOR a, FromCBOR a, Eq a) => a -> Bool
prop_canRoundtripCBOREncoding a =
  let encoded = toLazyByteString $ toCBOR a
   in (snd <$> deserialiseFromBytes fromCBOR encoded) == Right a
