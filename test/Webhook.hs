{-# LANGUAGE OverloadedStrings #-}

module Webhook where

import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as B
import qualified Data.HashMap.Strict as HM
import Data.Time.Clock.POSIX
import Network.Pusher
       (AppKey, AppSecret, AuthSignature, WebhookEv(..),
        WebhookPayload(..), Webhooks(..), parseChannel,
        parseWebhookPayloadWith)
import Network.Pusher.Protocol (User(..))
import Test.Hspec (Spec, describe, it)
import Test.QuickCheck (property)

data TestWebhookPayload = TestWebhookPayload
  { _webhookRequest :: ([(B.ByteString, B.ByteString)], B.ByteString) -- ^ A Request recieved from Pusher
  , _hasKey :: AppKey -- ^ Must have this key
  , _hasSecret :: AppSecret -- ^ Which must correspond to this secret
  , _payload :: Maybe WebhookPayload -- ^ And which must parse to this Payload
  }

-- | Attempt to parse the contained req.
-- - It must use our appKey which must correspond to our secret.
-- - The body must be correctly signed by our secret.
-- - The parsed payload must then further be identical to the one we expect.
testWebhookPayloadParses :: TestWebhookPayload -> Bool
testWebhookPayloadParses (TestWebhookPayload (headers, body) hasKey correspondingSecret expectedPayload) =
  let parseResult =
        parseWebhookPayloadWith
          (\k ->
             if k == hasKey
               then Just correspondingSecret
               else Nothing)
          headers
          body
  in parseResult == expectedPayload

-- Build a _simple_ TestWebhookPayload which contains:
-- - A HTTP POST request with key and signature headers and a bytestring body
-- - A mapping from the same key to the secret used to sign the body to produce the signature.
-- - A list of webhook events we expect to have in the body.
--
-- The caller can deliberately pass incorrect timestamps, bodys, secrets,
-- signatures and event combinations to test whether parsing fails as expected.
--
-- Parsing of values generated by this function should only succeed when:
-- - The timestamp is the same as the one in the message body
-- - The message body contains exactly the same list of events
-- - The body is encrypted by the given key to produce the given signature
--
-- The word _simple_ excludes cases where:
-- - The HTTP request doesnt have the required headers
-- - The HTTP headers are different to the expected payload
-- - The HTTP requests key is unknown or doesnt match our secret
mkSimpleTestWebhookPayload ::
     AppKey
  -> AppSecret
  -> POSIXTime
  -> B.ByteString
  -> AuthSignature
  -> [WebhookEv]
  -> TestWebhookPayload
mkSimpleTestWebhookPayload key secret unixTime body signature whs =
  TestWebhookPayload
  { _webhookRequest =
      ([("X-Pusher-Key", key), ("X-Pusher-Signature", signature)], body)
  , _hasKey = key
  , _hasSecret = secret
  , _payload =
      Just
        WebhookPayload
        { xPusherKey = key
        , xPusherSignature = signature
        , webhooks =
            Webhooks {timeMs = posixSecondsToUTCTime unixTime, webhookEvs = whs}
        }
  }

channelOccupiedPayload :: TestWebhookPayload
channelOccupiedPayload =
  mkSimpleTestWebhookPayload
    "ebc2cca5d18f3cf01d99"
    "6f87cba29d7b8f6f4a36"
    1502790365001
    "{\"time_ms\":1502790365001,\"events\":[{\"channel\":\"foo\",\"name\":\"channel_occupied\"}]}"
    "4b3d29966e4930d875ec01012e37c18070f4b779b09f71af99d1f0baaffabc98"
    [ChannelOccupiedEv {onChannel = parseChannel "foo"}]

channelVacatedPayload :: TestWebhookPayload
channelVacatedPayload =
  mkSimpleTestWebhookPayload
    "ebc2cca5d18f3cf01d99"
    "6f87cba29d7b8f6f4a36"
    1502790363928
    "{\"time_ms\":1502790363928,\"events\":[{\"channel\":\"foo\",\"name\":\"channel_vacated\"}]}"
    "c9c70dcf19e011912ecdabe8997b451a95667157d00e37c7476491e7f233c416"
    [ChannelVacatedEv {onChannel = parseChannel "foo"}]

memberAddedPayload :: TestWebhookPayload
memberAddedPayload =
  mkSimpleTestWebhookPayload
    "ebc2cca5d18f3cf01d99"
    "6f87cba29d7b8f6f4a36"
    1503394956847
    "{\"time_ms\":1503394956847,\"events\":[{\"channel\":\"presence-foo\",\"user_id\":\"42\",\"name\":\"member_added\"}]}"
    "392bd546e8a33a826d7870bd6432f6c7dcf11ca31565575d8c72f9b02f5b0736"
    [ MemberAddedEv
      {onChannel = parseChannel "presence-foo", withUser = User "42"}
    ]

memberRemovedPayload :: TestWebhookPayload
memberRemovedPayload =
  mkSimpleTestWebhookPayload
    "ebc2cca5d18f3cf01d99"
    "6f87cba29d7b8f6f4a36"
    1503394971554
    "{\"time_ms\":1503394971554,\"events\":[{\"channel\":\"presence-foo\",\"user_id\":\"42\",\"name\":\"member_removed\"}]}"
    "9a344e8aeb2c6339999e84bacb4d50b3674599e297d01655eb2cec3f9c655763"
    [ MemberRemovedEv
      {onChannel = parseChannel "presence-foo", withUser = User "42"}
    ]

clientEventPayload :: TestWebhookPayload
clientEventPayload =
  mkSimpleTestWebhookPayload
    "ebc2cca5d18f3cf01d99"
    "6f87cba29d7b8f6f4a36"
    1503397271011
    "{\"time_ms\":1503397271011,\"events\":[{\"name\":\"client_event\",\"channel\":\"presence-foo\",\"event\":\"client-event\",\"data\":\"{\\\"name\\\":\\\"John\\\",\\\"message\\\":\\\"Hello\\\"}\",\"socket_id\":\"219049.596715\",\"user_id\":\"sturdy-window-821\"}]}"
    "e5ef8964e8c87c91dde0555e46fa921163aff262395c9e36c1755ffe206be547"
    [ ClientEv
      { onChannel = parseChannel "presence-foo"
      , clientEvName = "client-event"
      , clientEvBody =
          Just $
          A.Object $
          HM.fromList [("name", A.String "John"), ("message", A.String "Hello")]
      , withSocketId = "219049.596715"
      , withPossibleUser = Just . User $ "sturdy-window-821"
      }
    ]

batchEventPayload :: TestWebhookPayload
batchEventPayload =
  mkSimpleTestWebhookPayload
    "ebc2cca5d18f3cf01d99"
    "6f87cba29d7b8f6f4a36"
    1503397088953
    "{\"time_ms\":1503397088953,\"events\":[{\"channel\":\"private-foo\",\"name\":\"channel_occupied\"},{\"channel\":\"presence-foo\",\"name\":\"channel_occupied\"}]}"
    "7a9803e1ca598dac4750a60fbb017d4f34fc44eaf0aea26c694ca0d7060e6477"
    [ ChannelOccupiedEv {onChannel = parseChannel "private-foo"}
    , ChannelOccupiedEv {onChannel = parseChannel "presence-foo"}
    ]

test :: Spec
test =
  describe "Webhook.parseWebhookPayloadWith" $ do
    it "parses and validates a channel_occupied event" $
      property $ testWebhookPayloadParses channelOccupiedPayload
    it "parses and validates a Channel_vacated event" $
      property $ testWebhookPayloadParses channelVacatedPayload
    it "parses and validates a member_added event" $
      property $ testWebhookPayloadParses memberAddedPayload
    it "parses and validates a member_removed event" $
      property $ testWebhookPayloadParses memberRemovedPayload
    it "parses and validates a client event" $
      property $ testWebhookPayloadParses clientEventPayload
    it "parses and validates multiple batched events" $
      property $ testWebhookPayloadParses batchEventPayload
