{-# LANGUAGE OverloadedStrings #-}
import Control.Applicative
import Control.Concurrent (threadDelay, forkIO)
import Control.Exception
import Control.Monad
import Data.List (sort)
import Data.Maybe (catMaybes, fromJust)
import Network.AMQP
import Test.Hspec
import Text.JSON
import Web.Scotty
import Data.Text
import qualified Data.ByteString.Lazy.Char8 as BL

resultToMaybe :: Result a -> Maybe a
resultToMaybe (Ok x) = Just x
resultToMaybe (Error _) = Nothing

decodeFromMsg :: JSON a => Message -> Maybe a
decodeFromMsg = resultToMaybe . decode . BL.unpack . msgBody

decodeFromChan :: JSON a => Channel -> Text -> IO (Maybe a)
decodeFromChan chan queue = fmap (>>= (decodeFromMsg . fst)) (getMsg chan NoAck queue)

data LogPart = LogPart
  { lp_jobID :: Int
  , lp_logContent :: String
  , lp_final :: Bool
  , lp_uuid :: String
  , lp_number :: Int
  } deriving (Show, Eq)

(!) :: (JSON a) => JSObject JSValue -> String -> Result a
(!) = flip valFromObj

instance JSON LogPart where
  showJSON = undefined
  readJSON (JSObject obj) =
    LogPart <$>
    obj ! "id" <*>
    obj ! "log" <*>
    obj ! "final" <*>
    obj ! "uuid" <*>
    obj ! "number"
  readJSON _ = mzero

instance Ord LogPart where
  compare a b = compare (lp_number a) (lp_number b)

data StateUpdate = StateUpdate
  { su_jobID :: Integer
  , su_state :: String
  } deriving (Show, Eq)

instance JSON StateUpdate where
  showJSON = undefined
  readJSON (JSObject obj) =
    StateUpdate <$>
    obj ! "id" <*>
    obj ! "state"
  readJSON _ = mzero

setup :: Connection -> IO ()
setup conn = do
  chan <- openChannel conn

  declareQueue chan newQueue {queueName = "builds.test"}
  declareQueue chan newQueue {queueName = "reporting.jobs.logs"}
  declareQueue chan newQueue {queueName = "reporting.jobs.builds"}

  purgeQueue chan "builds.test"
  purgeQueue chan "reporting.jobs.logs"
  purgeQueue chan "reporting.jobs.builds"
  
  closeChannel chan

publishJob :: Connection -> IO ()
publishJob conn = do
  chan <- openChannel conn

  publishMsg chan "" "builds.test" newMsg {msgBody = BL.pack "{\"type\":\"test\",\"job\":{\"id\":3,\"number\":\"1.1\",\"commit\":\"abcdef\",\"commit_range\":\"abcde...abcdef\",\"commit_message\":\"Hello world\",\"branch\":\"master\",\"ref\":null,\"state\":\"queued\",\"secure_env_enabled\":true,\"pull_request\":false},\"source\":{\"id\":2,\"number\":\"1\"},\"repository\":{\"id\":1,\"slug\":\"hello/world\",\"github_id\":1234,\"source_url\":\"git://github.com/hello/world.git\",\"api_url\":\"https://api.github.com\",\"last_build_id\":2,\"last_build_number\":\"1\",\"last_build_started_at\":null,\"last_build_finished_at\":null,\"last_build_duration\":null,\"last_build_state\":\"created\",\"description\":\"Hello world\"},\"config\":{},\"queue\":\"builds.test\",\"uuid\":\"fake-uuid\",\"ssh_key\":null,\"env_vars\":[],\"timeouts\":{\"hard_limit\":null,\"log_silence\":null}}", msgDeliveryMode = Just Persistent}

  -- Wait a second before we do anything else, to allow the worker to process the job and publish every result back
  threadDelay 1000000

  closeChannel chan

buildScriptServer :: IO ()
buildScriptServer = scotty 3000 $ post "/script" $ text "Hello, world"

withChannel :: Connection -> (Channel -> IO ()) -> IO ()
withChannel conn = bracket (openChannel conn) closeChannel

main :: IO ()
main = do
  scriptServerThread <- forkIO buildScriptServer

  conn <- openConnection "127.0.0.1" "/" "guest" "guest"
  setup conn
  publishJob conn

  hspec $ do
    it "sends log messages" $ withChannel conn $ \chan -> do
      mlogs <- replicateM 2 $ decodeFromChan chan "reporting.jobs.logs"

      let [logWithContent, logFinal] = sort $ catMaybes mlogs

      lp_jobID logWithContent `shouldBe` 3
      lp_logContent logWithContent `shouldBe` "Hello to the logs"
      lp_final logWithContent `shouldBe` False
      lp_uuid logWithContent `shouldBe` "fake-uuid"

      lp_jobID logFinal `shouldBe` 3
      lp_logContent logFinal `shouldBe` ""
      lp_final logFinal `shouldBe` True
      lp_uuid logFinal `shouldBe` "fake-uuid"

      compare (lp_number logWithContent) (lp_number logFinal) `shouldBe` LT

    it "sends state updates" $ withChannel conn $ \chan -> do
      mstateUpdateStarted <- decodeFromChan chan "reporting.jobs.builds"
      let stateUpdateStarted = fromJust mstateUpdateStarted

      su_jobID stateUpdateStarted `shouldBe` 3
      su_state stateUpdateStarted `shouldBe` "started"

      mstateUpdateFinished <- decodeFromChan chan "reporting.jobs.builds"
      let stateUpdateFinished = fromJust mstateUpdateFinished

      su_jobID stateUpdateFinished `shouldBe` 3
      su_state stateUpdateFinished `shouldBe` "passed"

  closeConnection conn