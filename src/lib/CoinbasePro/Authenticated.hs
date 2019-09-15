{-# LANGUAGE DataKinds     #-}
{-# LANGUAGE TypeFamilies  #-}
{-# LANGUAGE TypeOperators #-}

module CoinbasePro.Authenticated
  ( accounts
  , account
  , listOrders
  , fills
  , placeOrder
  , cancelOrder
  , cancelAll
  ) where


import           Control.Monad                      (void)
import           Data.Aeson                         (encode)
import qualified Data.ByteString.Char8              as C8
import qualified Data.ByteString.Lazy.Char8         as LC8
import           Data.Maybe                         (fromMaybe)
import           Data.Proxy                         (Proxy (..))
import qualified Data.Set                           as S
import           Data.Text                          (Text, pack, toLower,
                                                     unpack)
import           Network.HTTP.Types                 (SimpleQuery,
                                                     SimpleQueryItem,
                                                     methodDelete, methodGet,
                                                     methodPost, renderQuery,
                                                     simpleQueryToQuery)
import           Servant.API
import           Servant.Client
import           Servant.Client.Core                (AuthenticatedRequest)

import           CoinbasePro.Authenticated.Accounts (Account, AccountId (..))
import           CoinbasePro.Authenticated.Fills    (Fill)
import           CoinbasePro.Authenticated.Orders   (Order, PlaceOrderBody (..),
                                                     STP, Status (..),
                                                     Statuses (..), TimeInForce,
                                                     statuses)
import           CoinbasePro.Request                (AuthDelete, AuthGet,
                                                     AuthPost, CBAuthT (..),
                                                     RequestPath, authRequest)
import           CoinbasePro.Types                  (OrderId (..), OrderType,
                                                     Price, ProductId (..),
                                                     Side, Size)


type API =    "accounts" :> AuthGet [Account]
         :<|> "accounts" :> Capture "account-id" AccountId :> AuthGet Account
         :<|> "orders" :> QueryParams "status" Status :> QueryParam "product_id" ProductId :> AuthGet [Order]
         :<|> "orders" :> ReqBody '[JSON] PlaceOrderBody :> AuthPost Order
         :<|> "orders" :> Capture "order_id" OrderId :> AuthDelete NoContent
         :<|> "orders" :> QueryParam "product_id" ProductId :> AuthDelete [OrderId]
         :<|> "fills" :> QueryParam "product_id" ProductId :> QueryParam "order_id" OrderId :> AuthGet [Fill]


api :: Proxy API
api = Proxy


accountsAPI :: AuthenticatedRequest (AuthProtect "CBAuth") -> ClientM [Account]
singleAccountAPI :: AccountId -> AuthenticatedRequest (AuthProtect "CBAuth") -> ClientM Account
listOrdersAPI :: [Status] -> Maybe ProductId -> AuthenticatedRequest (AuthProtect "CBAuth") -> ClientM [Order]
placeOrderAPI :: PlaceOrderBody -> AuthenticatedRequest (AuthProtect "CBAuth") -> ClientM Order
cancelOrderAPI :: OrderId -> AuthenticatedRequest (AuthProtect "CBAuth") -> ClientM NoContent
cancelAllAPI :: Maybe ProductId -> AuthenticatedRequest (AuthProtect "CBAuth") -> ClientM [OrderId]
fillsAPI :: Maybe ProductId -> Maybe OrderId -> AuthenticatedRequest (AuthProtect "CBAuth") -> ClientM [Fill]
accountsAPI :<|> singleAccountAPI :<|> listOrdersAPI :<|> placeOrderAPI :<|> cancelOrderAPI :<|> cancelAllAPI :<|> fillsAPI = client api


-- | https://docs.pro.coinbase.com/?javascript#accounts
accounts :: CBAuthT ClientM [Account]
accounts = authRequest methodGet "/accounts" "" accountsAPI


-- | https://docs.pro.coinbase.com/?javascript#get-an-account
account :: AccountId -> CBAuthT ClientM Account
account aid@(AccountId t) = authRequest methodGet requestPath "" $ singleAccountAPI aid
  where
    requestPath = "/accounts/" ++ unpack t


-- | https://docs.pro.coinbase.com/?javascript#list-orders
listOrders :: Maybe [Status] -> Maybe ProductId -> CBAuthT ClientM [Order]
listOrders st prid = authRequest methodGet (mkRequestPath "/orders") "" $ listOrdersAPI (defaultStatus st) prid
  where
    mkRequestPath :: RequestPath -> RequestPath
    mkRequestPath rp = rp ++ (C8.unpack . renderQuery True . simpleQueryToQuery $ mkOrderQuery st prid)

    mkOrderQuery :: Maybe [Status] -> Maybe ProductId -> SimpleQuery
    mkOrderQuery ss p = mkStatusQuery ss <> mkProductQuery p

    mkStatusQuery :: Maybe [Status] -> [SimpleQueryItem]
    mkStatusQuery ss = mkSimpleQueryItem "status" . toLower . pack . show <$> S.toList (unStatuses . statuses $ defaultStatus ss)

    defaultStatus :: Maybe [Status] -> [Status]
    defaultStatus = fromMaybe [All]


-- | https://docs.pro.coinbase.com/?javascript#place-a-new-order
placeOrder :: ProductId -> Side -> Size -> Price -> Bool -> Maybe OrderType -> Maybe STP -> Maybe TimeInForce -> CBAuthT ClientM Order
placeOrder prid sd sz price po ot stp tif =
    authRequest methodPost "/orders" (LC8.unpack $ encode body) $ placeOrderAPI body
  where
    body = PlaceOrderBody prid sd sz price po ot stp tif


-- | https://docs.pro.coinbase.com/?javascript#cancel-an-order
cancelOrder :: OrderId -> CBAuthT ClientM ()
cancelOrder oid = void . authRequest methodDelete (mkRequestPath "/orders") "" $ cancelOrderAPI oid
  where
    mkRequestPath :: RequestPath -> RequestPath
    mkRequestPath rp = rp ++ "/" ++ unpack (unOrderId oid)


-- | https://docs.pro.coinbase.com/?javascript#cancel-all
cancelAll :: Maybe ProductId -> CBAuthT ClientM [OrderId]
cancelAll prid = authRequest methodDelete (mkRequestPath "/orders") "" (cancelAllAPI prid)
  where
    mkRequestPath :: RequestPath -> RequestPath
    mkRequestPath rp = rp ++ (C8.unpack . renderQuery True . simpleQueryToQuery $ mkProductQuery prid)


-- | https://docs.pro.coinbase.com/?javascript#fills
fills :: Maybe ProductId -> Maybe OrderId -> CBAuthT ClientM [Fill]
fills prid oid = authRequest methodGet mkRequestPath "" (fillsAPI prid oid)
  where
    brp = "/fills"

    mkRequestPath :: RequestPath
    mkRequestPath = brp ++ (C8.unpack . renderQuery True . simpleQueryToQuery $ mkSimpleQuery prid oid)

    mkSimpleQuery :: Maybe ProductId -> Maybe OrderId -> SimpleQuery
    mkSimpleQuery p o = mkProductQuery p <> mkOrderIdQuery o


mkSimpleQueryItem :: String -> Text -> SimpleQueryItem
mkSimpleQueryItem s t = (C8.pack s, C8.pack $ unpack t)


mkProductQuery :: Maybe ProductId -> [SimpleQueryItem]
mkProductQuery = maybe [] (return . mkSimpleQueryItem "product_id" . unProductId)


mkOrderIdQuery :: Maybe OrderId -> SimpleQuery
mkOrderIdQuery = maybe [] (return . mkSimpleQueryItem "order_id" . unOrderId)