{-# LANGUAGE ScopedTypeVariables #-}
module Network.SSH.Client.LibSSH2
  (-- * Types
   Session, Channel, KnownHosts, Sftp, SftpHandle,

   -- * Functions
   withSSH2,
   withSSH2User,
   withSession,
   withChannel,
   withChannelBy,
   checkHost,
   readAllChannel,
   writeAllChannel,
   scpSendFile,
   scpReceiveFile,
   runShellCommands,
   execCommands,

   -- * Sftp Functions
   withSFTP,
   withSFTPUser,
   sftpListDir,
   sftpRenameFile,
   sftpSendFile,
   sftpReceiveFile,

   -- * Utilities
   socketConnect,
   sessionInit,
   sessionClose,
  ) where

import Control.Monad
import Control.Exception as E
import Network  hiding (sClose)
import Network.BSD
import Network.Socket
import System.IO
import qualified Data.ByteString as BSS
import qualified Data.ByteString.Char8 as BSSC
import qualified Data.ByteString.Lazy as BSL

import Network.SSH.Client.LibSSH2.Types
import Network.SSH.Client.LibSSH2.Foreign

-- | Similar to Network.connectTo, but does not socketToHandle.
socketConnect :: String -> Int -> IO Socket
socketConnect hostname port = do
    proto <- getProtocolNumber "tcp"
    bracketOnError (socket AF_INET Stream proto) (sClose)
            (\sock -> do
              he <- getHostByName hostname
              connect sock (SockAddrInet (fromIntegral port) (hostAddress he))
              return sock)

-- | Execute some actions within SSH2 connection.
-- Uses public key authentication.
withSSH2 :: FilePath          -- ^ Path to known_hosts file
         -> FilePath          -- ^ Path to public key file
         -> FilePath          -- ^ Path to private key file
         -> String            -- ^ Passphrase
         -> String            -- ^ Remote user name
         -> String            -- ^ Remote host name
         -> Int               -- ^ Remote port number (usually 22)
         -> (Session -> IO a) -- ^ Actions to perform on session
         -> IO a
withSSH2 known_hosts public private passphrase login hostname port fn =
  withSession hostname port $ \s -> do
    r <- checkHost s hostname port known_hosts
    when (r == MISMATCH) $
      error $ "Host key mismatch for host " ++ hostname
    publicKeyAuthFile s login public private passphrase
    fn s

-- | Execute some actions within SSH2 connection.
-- Uses username/password authentication.
withSSH2User :: FilePath          -- ^ Path to known_hosts file
         -> String            -- ^ Remote user name
         -> String            -- ^ Remote password
         -> String            -- ^ Remote host name
         -> Int               -- ^ Remote port number (usually 22)
         -> (Session -> IO a) -- ^ Actions to perform on session
         -> IO a
withSSH2User known_hosts login password hostname port fn =
  withSession hostname port $ \s -> do
    r <- checkHost s hostname port known_hosts
    when (r == MISMATCH) $
      error $ "Host key mismatch for host " ++ hostname
    usernamePasswordAuth s login password
    fn s

-- | Execute some actions within SSH2 session
withSession :: String            -- ^ Remote host name
            -> Int               -- ^ Remote port number (usually 22)
            -> (Session -> IO a) -- ^ Actions to perform on handle and session
            -> IO a
withSession hostname port = E.bracket (sessionInit hostname port) sessionClose

--  | Initialize session to the gived host
sessionInit :: String -> Int -> IO Session
sessionInit hostname port = do
      sock <- socketConnect hostname port
      session <- initSession
      setBlocking session False
      handshake session sock
      return session

--  | Close active session
sessionClose :: Session -> IO ()
sessionClose session = do
      disconnectSession session "Done."
      freeSession session



--  | Check remote host against known hosts list
checkHost :: Session
          -> String             -- ^ Remote host name
          -> Int                -- ^ Remote port number (usually 22)
          -> FilePath           -- ^ Path to known_hosts file
          -> IO KnownHostResult
checkHost s host port path = do
  kh <- initKnownHosts s
  _numKnownHosts <- knownHostsReadFile kh path
  (hostkey, _keylen, _keytype) <- getHostKey s
  result <- checkKnownHost kh host port hostkey [TYPE_PLAIN, KEYENC_RAW]
  freeKnownHosts kh
  return result

-- | Execute some actions withing SSH2 channel
withChannel :: Session -> (Channel -> IO a) -> IO (Int, a)
withChannel s = withChannelBy (openChannelSession s) id

-- | Read all data from the channel
--
-- Although this function returns a lazy bytestring, the data is /not/ read
-- lazily.
readAllChannel :: Channel -> IO BSL.ByteString
readAllChannel ch = go []
  where
    go :: [BSS.ByteString] -> IO BSL.ByteString
    go acc = do
      bs <- readChannel ch 0x400
      if BSS.length bs > 0
        then go (bs : acc)
        else return (BSL.fromChunks $ reverse acc)

readAllChannelNonBlocking :: Channel -> IO BSL.ByteString
readAllChannelNonBlocking ch = go []
  where
    go :: [BSS.ByteString] -> IO BSL.ByteString
    go acc = do
      bs <- do pollChannelRead ch
               readChannel ch 0x400
      if BSS.length bs > 0
        then go (bs : acc)
        else return (BSL.fromChunks $ reverse acc)

-- | Write a lazy bytestring to the channel
writeAllChannel :: Channel -> BSL.ByteString -> IO ()
writeAllChannel ch = mapM_ (writeChannel ch) . BSL.toChunks

runShellCommands :: Session -> [String] -> IO (Int, [BSL.ByteString])
runShellCommands s commands = withChannel s $ \ch -> do
  requestPTY ch "linux"
  channelShell ch
  _hello <- readAllChannelNonBlocking ch
  out <- forM commands $ \cmd -> do
             writeChannel ch (BSSC.pack $ cmd ++ "\n")
             r <- readAllChannelNonBlocking ch
             return r
  channelSendEOF ch
  return out

execCommands :: Session -> [String] -> IO (Int, [BSL.ByteString])
execCommands s commands = withChannel s $ \ch ->
  forM commands $ \cmd -> do
      channelExecute ch cmd
      readAllChannel ch

-- | Send a file to remote host via SCP.
-- Returns size of sent data.
scpSendFile :: Session
            -> Int       -- ^ File creation mode (0o777, for example)
            -> FilePath  -- ^ Path to local file
            -> FilePath  -- ^ Remote file path
            -> IO Integer
scpSendFile s mode local remote = do
  h <- openFile local ReadMode
  size <- hFileSize h
  (_, result) <- withChannelBy (scpSendChannel s remote mode (fromIntegral size) 0 0) id $ \ch -> do
    written <- writeChannelFromHandle ch h
    channelSendEOF ch
    channelWaitEOF ch
    return written
  hClose h
  return result

-- | Receive file from remote host via SCP.
-- Returns size of received data.
scpReceiveFile :: Session   --
               -> FilePath  -- ^ Remote file path
               -> FilePath  -- ^ Path to local file
               -> IO Integer
scpReceiveFile s remote local = do
  h <- openFile local WriteMode
  (_, result) <- withChannelBy (scpReceiveChannel s remote) fst $ \(ch, fileSize) -> do
    readChannelToHandle ch h fileSize
  hClose h
  return result

-- | Generalization of 'withChannel'
withChannelBy :: IO a            -- ^ Create a channel (and possibly other stuff)
              -> (a -> Channel)  -- ^ Extract the channel from "other stuff"
              -> (a -> IO b)     -- ^ Actions to execute on the channel
              -> IO (Int, b)     -- ^ Channel exit status and return value
withChannelBy createChannel extractChannel actions = do
  stuff <- createChannel
  let ch = extractChannel stuff
  result <- actions stuff
  closeChannel ch
  exitStatus <- channelExitStatus ch
  freeChannel ch
  return (exitStatus, result)

-- | Execute some actions within SFTP connection.
-- Uses public key authentication.
withSFTP :: FilePath          -- ^ Path to known_hosts file
         -> FilePath          -- ^ Path to public key file
         -> FilePath          -- ^ Path to private key file
         -> String            -- ^ Passphrase
         -> String            -- ^ Remote user name
         -> String            -- ^ Remote host name
         -> Int               -- ^ Remote port number (usually 22)
         -> (Sftp -> IO a)    -- ^ Actions to perform on session
         -> IO a
withSFTP known_hosts public private passphrase login hostname port fn =
  withSession hostname port $ \s -> do
    r <- checkHost s hostname port known_hosts
    when (r == MISMATCH) $
      error $ "Host key mismatch for host " ++ hostname
    publicKeyAuthFile s login public private passphrase
    withSftpSession s fn

-- | Execute some actions within SSH2 connection.
-- Uses username/password authentication.
withSFTPUser :: FilePath      -- ^ Path to known_hosts file
         -> String            -- ^ Remote user name
         -> String            -- ^ Remote password
         -> String            -- ^ Remote host name
         -> Int               -- ^ Remote port number (usually 22)
         -> (Sftp -> IO a)     -- ^ Actions to perform on session
         -> IO a
withSFTPUser known_hosts login password hostname port fn =
  withSession hostname port $ \s -> do
    r <- checkHost s hostname port known_hosts
    when (r == MISMATCH) $
      error $ "Host key mismatch for host " ++ hostname
    usernamePasswordAuth s login password
    withSftpSession s fn

-- | Execute some actions within SSH2 session
withSftpSession :: Session           -- ^ Remote host name
                -> (Sftp -> IO a)    -- ^ Actions to perform on sftp session
                -> IO a
withSftpSession session =
  E.bracket (sftpInit session) sftpShutdown

sftpListDir :: Sftp -> String -> IO [(BSS.ByteString, Integer)]
sftpListDir sftp path = do
  withDirList sftp path $ \h -> do
    collectFiles h []

withDirList :: Sftp
            -> String
            -> (SftpHandle -> IO a)
            -> IO a
withDirList sftp path = E.bracket (sftpOpenDir sftp path) sftpCloseHandle

collectFiles :: SftpHandle -> [(BSS.ByteString, Integer)] ->
  IO [ (BSS.ByteString, Integer) ]
collectFiles h acc = do
  v <- sftpReadDir h
  case v of
    Nothing -> return acc
    Just r  -> collectFiles h (r : acc)


-- | Send a file to remote host via SFTP
-- Returns size of sent data.
sftpSendFile :: Sftp
             -> Int       -- ^ File creation mode (0o777, for example)
             -> FilePath  -- ^ Path to local file
             -> FilePath  -- ^ Remote file path
             -> IO Integer
sftpSendFile sftp mode local remote = do
  fh <- openFile local ReadMode
  _size <- hFileSize fh
  result <- withOpenSftpFile sftp remote mode [FXF_WRITE, FXF_CREAT, FXF_TRUNC, FXF_EXCL] $ \sftph ->
    sftpWriteFileFromHandler sftph fh
  hClose fh
  return result

-- | Send a file to remote host via SFTP
-- Returns size of sent data.
sftpReceiveFile :: Sftp
                -> Int
                -> FilePath  -- ^ Path to local file
                -> FilePath  -- ^ Remote file path
                -> IO Integer
sftpReceiveFile sftp _mode local remote = do
  fh <- openFile local WriteMode
  result <- withOpenSftpFile sftp remote 0 [FXF_READ] $ \sftph -> do
    filesize <- sftpFstatGet sftph
    sftpReadFileToHandler sftph fh (fromIntegral filesize)
  hClose fh
  return $ fromIntegral result

withOpenSftpFile :: Sftp
                 -> String
                 -> Int
                 -> [SftpFileTransferFlags]
                 -> (SftpHandle -> IO a)
                 -> IO a
withOpenSftpFile sftp path mode flags =
  E.bracket (sftpOpenFile sftp path mode flags) sftpCloseHandle
