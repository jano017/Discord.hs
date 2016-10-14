{-# LANGUAGE OverloadedStrings #-}
module Network.Discord where
  import Control.Concurrent
  import Control.Concurrent.STM
  import Control.Monad (forever, void)

  import Wuss as WS
  import qualified Network.WebSockets as WS

  import Network.Discord.Gateway
  import Network.Discord.Client

  heartbeatLoop :: Int -> TBQueue Payload -> TMVar Integer -> IO ()
  heartbeatLoop interval queue seqId = void . forkIO . forever $ do
    atomically $ do
      seq_id <- readTMVar seqId
      writeTBQueue queue $ Heartbeat seq_id
    threadDelay $ 1000 * interval

  startClient :: (Client a) => a -> IO ()
  startClient client = clientSM Create client undefined undefined undefined

  data StateEnum = Create | Start | Ready | Invalid String
  clientSM :: (Client a0) => StateEnum -> a0 -> TMVar Integer -> TBQueue Payload -> WS.Connection -> IO()
  clientSM Create client _ _ _ = do
    input <- atomically $ newTBQueue 100
    seq_num <- atomically newEmptyTMVar
    runSecureClient "gateway.discord.gg" 443 "/?v=5" (clientSM Start client seq_num input)
  clientSM Start client seqId input conn = do
    void . forkIO . forever $ do
      message <- atomically $ readTBQueue input
      WS.sendTextData conn message
    WS.sendTextData conn (Identify (getAuth client) False 50 (0, 1))
    hello <- WS.receiveData conn
    case hello of
      (Hello interval) -> do
        heartbeatLoop interval input seqId
        clientSM Ready client seqId input conn
      _ -> clientSM (Invalid "Failed to recieve server Hello") client seqId input conn
  clientSM Ready client seqId input conn = do
    payload <- WS.receiveData conn
    case payload of
      Dispatch o new_seq event -> do
        atomically $ do
          _ <- tryTakeTMVar seqId
          putTMVar seqId new_seq
        putStrLn $ "Event: " ++ event
        case lookup event [
            ("READY", onReady)
          , ("RESUMED", onResume)
          , ("CHANNEL_CREATE", onChannelCreate)
          , ("CHANNEL_UPDATE", onChannelUpdate)
          , ("CHANNEL_DELETE", onChannelDelete)
          , ("GUILD_CREATE", onGuildCreate)
          , ("GUILD_UPDATE", onGuildUpdate)
          , ("GUILD_DELETE", onGuildDelete)
          , ("GUILD_BAN_ADD", onGuildBanAdd)
          , ("GUILD_BAN_REMOVE", onGuildBanRemove)
          , ("GUILD_EMOJI_UPDATE", onGuildEmojiUpdate)
          , ("GUILD_INTEGRATIONS_UPDATE", onGuildIntegrationsUpdate)
          , ("GUILD_MEMBER_ADD", onGuildMemberAdd)
          , ("GUILD_MEMBER_REMOVE", onGuildMemberRemove)
          , ("GUILD_MEMBER_UPDATE", onGuildMemberUpdate)
          , ("GUILD_MEMBERS_CHUNK", onGuildMembersChunk)
          , ("GUILD_ROLE_CREATE", onGuildRoleCreate)
          , ("GUILD_ROLE_UPDATE", onGuildRoleUpdate)
          , ("GUILD_ROLE_DELETE", onGuildRoleDelete)
          , ("MESSAGE_CREATE", onMessageCreate)
          , ("MESSAGE_UPDATE", onMessageUpdate)
          , ("MESSAGE_DELETE", onMessageDelete)
          , ("MESSAGE_DELETE_BULK", onMessageDeleteBulk)
          , ("PRESENCE_UPDATE", onPresenceUpdate)
          , ("TYPING_START", onTypingStart)
          , ("USER_SETTINGS_UPDATE", onUserSettingsUpdate)
          , ("VOICE_STATE_UPDATE", onVoiceStateUpdate)
          , ("VOICE_SERVER_UPDATE", onVoiceServerUpdate)
          ] of
            Just callback -> do
              newClient <- callback client input o
              clientSM Ready newClient seqId input conn
            Nothing -> clientSM (Invalid "Unrecognized event") client seqId input conn
      Heartbeat new_seq -> do
        atomically $ do
          _ <- tryTakeTMVar seqId
          putTMVar seqId new_seq
        clientSM Ready client seqId input conn
      HeartbeatAck -> clientSM Ready client seqId input conn
      ParseError err -> clientSM (Invalid err) client seqId input conn
      a -> clientSM (Invalid $ show a) client seqId input conn
  clientSM (Invalid reason) _ _ _ _ = putStrLn $ "Client error: " ++ reason