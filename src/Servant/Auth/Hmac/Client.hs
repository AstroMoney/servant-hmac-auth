{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}

-- | Servant client authentication.
module Servant.Auth.Hmac.Client (
    -- * HMAC client settings
    HmacSettings (..),
    defaultHmacSettings,

    -- * HMAC servant client
    HmacClientM (..),
    runHmacClient,
    hmacClient,
) where

import Control.Monad ((>=>))
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Reader (MonadReader (..), ReaderT, asks, runReaderT)
import Control.Monad.Trans.Class (lift)
import Data.ByteString (ByteString)
import Data.CaseInsensitive (mk)
import Data.Foldable (toList)
import Data.List (sort)
import Data.Proxy (Proxy (..))
import Data.Sequence (fromList, (<|))
import Data.String (fromString)
import Servant.Client (
    BaseUrl,
    Client,
    ClientEnv (baseUrl),
    ClientError,
    ClientM,
    HasClient,
    runClientM,
 )
import Servant.Client.Core (RunClient (..), clientIn)
import Servant.Client.Internal.HttpClient (defaultMakeClientRequest)

import Servant.Auth.Hmac.Crypto (
    RequestPayload (..),
    SecretKey,
    Signature (..),
    requestSignature,
    signSHA256,
    defaultAuthHeaderName, keepWhitelistedHeaders'
 )

import qualified Network.HTTP.Client as Client
import qualified Servant.Client.Core as Servant
import Network.HTTP.Types

-- | Environment for 'HmacClientM'. Contains all required settings for hmac client.
data HmacSettings = HmacSettings
    { hmacSigner :: SecretKey -> ByteString -> Signature
    -- ^ Singing function that will sign all outgoing requests.
    , hmacSecretKey :: SecretKey
    -- ^ Secret key for signing function.
    , hmacRequestHook :: Maybe (Servant.Request -> ClientM ())
    -- ^ Function to call for every request after this request is signed.
    -- Useful for debugging.
    , hmacAuthHeaderName :: HeaderName
    -- ^ Header name to use to get request signature
    }

{- | Default 'HmacSettings' with the following configuration:

1. Signing function is 'signSHA256'.
2. Secret key is provided.
3. 'hmacRequestHook' is 'Nothing'.
4. 'hmacAuthHeaderName' is 'Authentication'.
-}
defaultHmacSettings :: SecretKey -> HmacSettings
defaultHmacSettings sk =
    HmacSettings
        { hmacSigner = signSHA256
        , hmacSecretKey = sk
        , hmacRequestHook = Nothing
        , hmacAuthHeaderName = defaultAuthHeaderName
        }

{- | @newtype@ wrapper over 'ClientM' that signs all outgoing requests
automatically.
-}
newtype HmacClientM a = HmacClientM
    { runHmacClientM :: ReaderT HmacSettings ClientM a
    }
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader HmacSettings)

hmacifyClient :: ClientM a -> HmacClientM a
hmacifyClient = HmacClientM . lift

hmacClientSign :: Servant.Request -> HmacClientM Servant.Request
hmacClientSign req = HmacClientM $ do
    HmacSettings{..} <- ask
    url <- lift $ asks baseUrl
    let signedRequest = signRequestHmac hmacAuthHeaderName hmacSigner hmacSecretKey url req
    case hmacRequestHook of
        Nothing -> pure ()
        Just hook -> lift $ hook signedRequest
    pure signedRequest

instance RunClient HmacClientM where
    runRequestAcceptStatus s = hmacClientSign >=> hmacifyClient . runRequestAcceptStatus s

    throwClientError :: ClientError -> HmacClientM a
    throwClientError = hmacifyClient . throwClientError

runHmacClient ::
    HmacSettings ->
    ClientEnv ->
    HmacClientM a ->
    IO (Either ClientError a)
runHmacClient settings env client =
    runClientM (runReaderT (runHmacClientM client) settings) env

-- | Generates a set of client functions for an API.
hmacClient :: forall api. HasClient HmacClientM api => Client HmacClientM api
hmacClient = Proxy @api `clientIn` Proxy @HmacClientM

----------------------------------------------------------------------------
-- Internals
----------------------------------------------------------------------------

servantRequestToPayload :: HeaderName -> BaseUrl -> Servant.Request -> RequestPayload
servantRequestToPayload authHeaderName url sreq =
    RequestPayload
        { rpMethod = Client.method req
        , rpContent = "" -- toBsBody $ Client.requestBody req
        , rpHeaders =
            keepWhitelistedHeaders' authHeaderName $
                ("Host", hostAndPort) :
                ("Accept-Encoding", "gzip") :
                Client.requestHeaders req
        , rpRawUrl = hostAndPort <> Client.path req <> Client.queryString req
        }
  where
    req :: Client.Request
    req =
        defaultMakeClientRequest
            url
            sreq
                { Servant.requestQueryString =
                    fromList $ sort $ toList $ Servant.requestQueryString sreq
                }

    hostAndPort :: ByteString
    hostAndPort = case lookup (mk "Host") (Client.requestHeaders req) of
        Just hp -> hp
        Nothing ->
            case (Client.secure req, Client.port req) of
                (True, 443) -> Client.host req
                (False, 80) -> Client.host req
                (_, p) -> Client.host req <> ":" <> fromString (show p)

--    toBsBody :: RequestBody -> ByteString
--    toBsBody (RequestBodyBS bs)       = bs
--    toBsBody (RequestBodyLBS bs)      = LBS.toStrict bs
--    toBsBody (RequestBodyBuilder _ b) = LBS.toStrict $ toLazyByteString b
--    toBsBody _                        = ""  -- heh

{- | Adds signed header to the request.

@
Authentication: HMAC <signature>

-}

signRequestHmac ::
    -- | Authentication header name
    HeaderName ->
    -- | Signing function
    (SecretKey -> ByteString -> Signature) ->
    -- | Secret key that was used for signing 'Request'
    SecretKey ->
    -- | Base url for servant request
    BaseUrl ->
    -- | Original request
    Servant.Request ->
    -- | Signed request
    Servant.Request
signRequestHmac authHeaderName signer sk url req = do
    let payload = servantRequestToPayload authHeaderName url req
    let signature = requestSignature signer sk payload
    let authHead = (authHeaderName, "HMAC " <> unSignature signature)
    req{Servant.requestHeaders = authHead <| Servant.requestHeaders req}
