{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module NodeState
  ( NodeAccType(..)
  , NodeConfig(..)
  , NodeState(..)
  , NodeEnv(..)

  , NodeT
  , runNodeT

  , initNodeState
  , resetNodeState

  -- ** Node Peers
  , Peers
  , Peer(..)
  , peersToPids
  , peersToNodeIds
  , peersToAddresses
  , nodeIdToHostname

  -- ** Getters & Setters
  , askConfig
  , askStorageBackend

  , askAccount
  , askPrivateKey
  , askKeyPair
  , askAccountType
  , askSelfAddress
  , askGenesisBlock
  , askNodeDataDir

  -- ** World State
  , getLedger
  , setLedger

  -- ** Node Peers
  , getPeers
  , getPeerNodeIds
  , setPeers
  , withPeers
  , modifyPeers
  , modifyPeers_

  -- ** Memory Pool
  , appendTxMemPool
  , getTxMemPool
  , resetTxMemPool
  , pruneTxMemPool
  , removeTxsFromMemPool
  , elemTxMemPool
  , elemInvalidTxPool
  , isTestNode
  , getTxStatus

  -- ** Invalid tx pool
  , appendInvalidTxPool
  , getInvalidTxPool

  -- ** Query Ledger State
  , lookupAccount
  , withAccount
  , withLedgerState

  -- ** World State
  , applyBlock
  , syncNodeStateWithDBs

  -- ** Consensus
  , getPoAState
  , setPoAState
  , modifyPoAState_
  , getLastBlock
  , setLastBlock
  , isValidatingNode
  , getValidatorPeers

  -- ** Peer persistence
  , loadPeers
  , savePeers

  -- ** Preallocated Accounts
  , loadPreallocatedAccs
  , loadPreallocatedAccs'

  , withApplyCtx

  ) where

import Protolude hiding (try)

import qualified Control.Concurrent.MVar as MVar

import Control.Arrow ((&&&))

import Control.Monad.Base
import Control.Monad.Trans.Class
import Control.Monad.Trans.Control

import Control.Distributed.Process.Lifted
import Control.Distributed.Process.Lifted.Class
import qualified Control.Distributed.Process as DP
import qualified Control.Distributed.Process.Node as DPN

import Data.Aeson (ToJSON(..), object, (.=))
import Data.List ((\\))
import qualified Data.Binary as Binary
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import qualified Data.DList as DL
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Serialize as Serialize

import Network.Transport

import System.Directory (doesFileExist, doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)

import DB
import DB.PostgreSQL

import Address (Address)
import Block (Block)
import qualified Account
import qualified Address
import qualified Block
import qualified Config
import qualified Key
import qualified Logging as Log
import qualified DB
import qualified Ledger
import qualified Transaction as Tx
import qualified TxLog
import qualified MemPool
import qualified Hash
import qualified Validate
import qualified Consensus.Authority.Params as CAP
import qualified Consensus.Authority.State as CAS

-------------------------------------------------------------------------------
-- Network Peers
-------------------------------------------------------------------------------

data Peer = Peer
  { peerPid     :: ProcessId  -- ProcessId of Peer Controller Process
  , peerAccAddr :: Address    -- Address of Peer node account
  } deriving (Eq, Ord, Show, Generic)

instance Binary.Binary Peer where
  put (Peer pid addr) = do
    Binary.put pid
    Binary.put addr
  get = Peer <$> Binary.get <*> Binary.get

instance ToJSON Peer where
  toJSON (Peer pid addr) = object
    [ "tag" .= ("Peer" :: Text)
    , "contents" .= object
        [ "peerPid" .= decodeUtf8 (pidToNodeIdBS pid)
        , "peerAccAddr" .= addr
        ]
    ]

type Peers = Set.Set Peer

peersToPids :: Peers -> [ProcessId]
peersToPids = map peerPid . Set.toList

peersToNodeIds :: Peers -> [NodeId]
peersToNodeIds = map (processNodeId . peerPid) . Set.toList

peersToAddresses :: Peers -> [Address]
peersToAddresses = map peerAccAddr . Set.toList

pidToNodeIdBS :: ProcessId -> ByteString
pidToNodeIdBS = endPointAddressToByteString . nodeAddress . processNodeId

nodeIdToHostname :: NodeId -> ByteString
nodeIdToHostname = toS . takeWhile (/= ':') . toS . endPointAddressToByteString . nodeAddress

-------------------------------------------------------------------------------
-- NodeEnv (NodeState & NodeConfig)
-------------------------------------------------------------------------------

data NodeState = NodeState
  { ledger        :: MVar Ledger.World          -- ^ In-memory world-state
  , p2pPeers      :: MVar Peers                 -- ^ Known peers in p2p network
  , txPool        :: MVar MemPool.MemPool       -- ^ Transactions memory pool
  , invalidTxPool :: MVar MemPool.InvalidTxPool -- ^ Invalid transactions that cannot be applied
  , poaState      :: MVar CAS.PoAState          -- ^ Stateful values related to consensus
  , lastBlock     :: MVar Block.Block           -- ^ Last block in the chain
  }

data NodeAccType = New | Existing

data NodeConfig = NodeConfig
  { account      :: Account.Account    -- ^ Active account
  , nodePrivKey  :: Key.PrivateKey     -- ^ Active account's private key
  , accountType  :: NodeAccType        -- ^ Is account new or existing
  , config       :: Config.Config      -- ^ Node configuration
  , genesisBlock :: Block.Block        -- ^ Network genesis block
  }

initNodeState
  :: MonadBase IO m
  => Ledger.World          -- ^ Initial World State
  -> Peers                 -- ^ Node Peers
  -> MemPool.MemPool       -- ^ Initial MemPool
  -> MemPool.InvalidTxPool -- ^ Initial MemPool
  -> CAS.PoAState          -- ^ Initial PoA State
  -> Block.Block           -- ^ Last Block in Chain
  -> m NodeState
initNodeState w ps mp itxp poa blk = do
  ledger <- liftBase (newMVar w)
  p2pPeers <- liftBase (newMVar ps)
  txPool <- liftBase (newMVar mp)
  invalidTxPool <- liftBase (newMVar itxp)
  poaState <- liftBase (newMVar poa)
  lastBlock <- liftBase (newMVar blk)
  return NodeState{..}

-- | Resets all of NodeState except for peers
resetNodeState
  :: MonadReadDB m
  => NodeT m ()
resetNodeState = do
  resetLedger
  resetTxMemPool
  resetInvalidTxPool
  resetPoAState
  resetLastBlock

data NodeEnv = NodeEnv
  { nodeConfig :: NodeConfig
  , nodeState  :: NodeState
  }

--------------------------------------------------------------------------------
-- NodeT Monad Transformer
--------------------------------------------------------------------------------

newtype NodeT m a = NodeT { unNodeT :: ReaderT NodeEnv m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadTrans, MonadReader NodeEnv)

-- | Run a computation with access to NodeConfig environment and NodeState
-- state, with any base monad as long as MonadBase IO is implemented
runNodeT :: NodeEnv -> NodeT m a -> m a
runNodeT nodeEnv = flip runReaderT nodeEnv . unNodeT

--------------------------------------------------------------------------------
-- MonadBase/Control/TransControl Boilerplate
--------------------------------------------------------------------------------

instance MonadBase IO m => MonadBase IO (NodeT m) where
  liftBase = liftBaseDefault

instance MonadTransControl NodeT where
  type StT NodeT a = StT (ReaderT NodeEnv) a
  liftWith = defaultLiftWith NodeT unNodeT
  restoreT = defaultRestoreT NodeT

instance MonadBaseControl IO m => MonadBaseControl IO (NodeT m) where
  type StM (NodeT m) a = ComposeSt NodeT m a
  liftBaseWith = defaultLiftBaseWith
  restoreM     = defaultRestoreM

instance MonadProcess m => MonadProcess (NodeT m) where
  liftP = NodeT . liftP

instance MonadProcessBase m => MonadProcessBase (NodeT m) where
  type StMP (NodeT m) a = ComposeStP (ReaderT NodeEnv) m a
  liftBaseWithP = defaultLiftBaseWithP
  restoreMP = defaultRestoreMP

-------------------------------------------------------------------------------
-- Getters & Setters
-------------------------------------------------------------------------------

readMVar' :: MonadBase IO m => (a -> b) -> MVar a -> m b
readMVar' f = liftBase . fmap f . readMVar

modifyNodeState_
  :: MonadBase IO m
  => (NodeState -> MVar a)
  -> (a -> IO a)
  -> NodeT m ()
modifyNodeState_ g f = do
  mvar <- getNodeState g
  liftBase $ modifyMVar_ mvar f

modifyNodeState
  :: MonadBase IO m
  => (NodeState -> MVar a)
  -> (a -> IO (a,b))
  -> NodeT m b
modifyNodeState g f = do
  mvar <- getNodeState g
  liftBase $ modifyMVar mvar f

-------------------------------------------------------------------------------
-- Getters & Setters
-------------------------------------------------------------------------------

askNodeConfig :: Monad m => NodeT m NodeConfig
askNodeConfig = asks nodeConfig

getNodeState :: Monad m => (NodeState -> MVar a) -> NodeT m (MVar a)
getNodeState f = f <$> asks nodeState

askConfig :: Monad m => NodeT m Config.Config
askConfig = config <$> askNodeConfig

askStorageBackend :: Monad m => NodeT m Config.StorageBackend
askStorageBackend = Config.storageBackend <$> askConfig

askAccount :: Monad m => NodeT m Account.Account
askAccount = account <$> askNodeConfig

askPrivateKey :: Monad m => NodeT m Key.PrivateKey
askPrivateKey = nodePrivKey <$> askNodeConfig

askKeyPair :: Monad m => NodeT m Key.ECDSAKeyPair
askKeyPair = (Key.toPublic &&& identity) <$> NodeState.askPrivateKey

askAccountType :: Monad m => NodeT m NodeAccType
askAccountType = accountType <$> askNodeConfig

askSelfAddress :: Monad m => NodeT m Address.Address
askSelfAddress = Account.address <$> askAccount

askGenesisBlock :: Monad m => NodeT m Block.Block
askGenesisBlock = genesisBlock <$> askNodeConfig

askNodeDataDir :: Monad m => NodeT m FilePath
askNodeDataDir = Config.nodeDataDir <$> askConfig

-------------------------------------------------------------------------------

getLedger :: MonadBase IO m => NodeT m Ledger.World
getLedger = liftBase . readMVar =<< getNodeState ledger

setLedger :: MonadBase IO m => Ledger.World -> NodeT m ()
setLedger ledger' = modifyNodeState_ ledger $ const $ pure ledger'

-- | Reset the ledger to it's initial state with preallocated accounts
resetLedger :: MonadBase IO m => NodeT m ()
resetLedger = do
  eAccs <- loadPreallocatedAccs
  let eFreshWorld = first show .
        flip Ledger.addAccounts mempty =<< eAccs
  case eFreshWorld of
    Left err         -> Log.warning $ show err
    Right freshWorld -> setLedger freshWorld

withLedgerState :: MonadBase IO m => (Ledger.World -> NodeT m a) -> NodeT m a
withLedgerState f = f =<< getLedger

modifyLedgerState_ :: MonadBase IO m => (Ledger.World -> Ledger.World) -> NodeT m ()
modifyLedgerState_ f = modifyNodeState_ ledger $ pure . f

withPeers :: MonadBase IO m => (Peers -> NodeT m a) -> NodeT m a
withPeers f = f =<< getPeers

getPeers :: MonadBase IO m => NodeT m Peers
getPeers = liftBase . readMVar =<< getNodeState p2pPeers

getPeerNodeIds :: MonadBase IO m => NodeT m [NodeId]
getPeerNodeIds = peersToNodeIds <$> getPeers

getPoAState :: MonadBase IO m => NodeT m CAS.PoAState
getPoAState = liftBase . readMVar =<< getNodeState poaState

setPoAState :: MonadBase IO m => CAS.PoAState -> NodeT m ()
setPoAState pstate =
  modifyNodeState_ poaState $ const $ pure pstate

modifyPoAState_ :: MonadBase IO m => (CAS.PoAState -> CAS.PoAState) -> NodeT m ()
modifyPoAState_ f = modifyNodeState_ poaState $ pure . f

resetPoAState :: MonadBase IO m => NodeT m ()
resetPoAState = setPoAState CAS.defPoAState

getLastBlock :: MonadBase IO m => NodeT m Block.Block
getLastBlock = liftBase . readMVar =<< getNodeState lastBlock

setLastBlock :: MonadBase IO m => Block.Block -> NodeT m ()
setLastBlock = modifyNodeState_ lastBlock . const . pure

resetLastBlock :: MonadReadDB m => NodeT m ()
resetLastBlock = setLastBlock =<< askGenesisBlock

setPeers :: MonadBase IO m => Peers -> NodeT m ()
setPeers = modifyNodeState_ p2pPeers . const .  pure

-- | Modify peers atomically
modifyPeers_ :: MonadBase IO m => (Peers -> Peers) -> NodeT m ()
modifyPeers_ f = modifyNodeState_ p2pPeers $ pure . f

-- | Modify peers atomically, returning a result
modifyPeers :: MonadBase IO m => (Peers -> (Peers,a)) -> NodeT m a
modifyPeers f = modifyNodeState p2pPeers $ pure . f

getInvalidTxPool :: MonadBase IO m => NodeT m MemPool.InvalidTxPool
getInvalidTxPool = liftBase . readMVar =<< getNodeState invalidTxPool

-- | Insert invalid transactions into InvalidTxPool & InvalidTxDB
appendInvalidTxPool
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => [Tx.InvalidTransaction]
  -> NodeT m (Either Text ())
appendInvalidTxPool itxs = do
  appendInvalidTxPool' itxs
  appendInvalidTxsDB itxs

-- | Insert invalid transactions into InvalidTxPool
appendInvalidTxPool' :: MonadBase IO m => [Tx.InvalidTransaction] -> NodeT m ()
appendInvalidTxPool' itxs = modifyNodeState_ invalidTxPool $ pure . MemPool.addInvalidTxs itxs

-- | Insert invalid transactions into InvalidTxDB
appendInvalidTxsDB
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => [Tx.InvalidTransaction]
  -> NodeT m (Either Text ())
appendInvalidTxsDB =
    fmap (first show) .
      lift . try' . DB.writeInvalidTxs
  where
    try'
      :: MonadBaseControl IO m
      => m ()
      -> m (Either SomeException ())
    try' = try

elemInvalidTxPool :: MonadBase IO m => ByteString -> NodeT m Bool
elemInvalidTxPool txHash = pure . MemPool.elemInvalidTxPool txHash =<< getInvalidTxPool

-- | Purge the contents of InvalidTxpool
resetInvalidTxPool :: MonadBase IO m => NodeT m ()
resetInvalidTxPool = modifyNodeState_ invalidTxPool $ pure . MemPool.resetInvalidTxPool

-- | Insert transaction into transaction pool
appendTxMemPool :: MonadBase IO m => Tx.Transaction -> NodeT m ()
appendTxMemPool tx = modifyNodeState_ txPool $ pure . MemPool.appendTx tx

getTxMemPool :: MonadBase IO m => NodeT m MemPool.MemPool
getTxMemPool = liftBase . readMVar =<< getNodeState txPool

resetTxMemPool :: MonadBase IO m => NodeT m ()
resetTxMemPool = modifyNodeState_ txPool $ const $ pure MemPool.emptyMemPool

-- | Atomically remove all invalid transactions from the mempool
-- and return the valid transactions.
pruneTxMemPool :: MonadBase IO m => NodeT m ([Tx.Transaction],[Tx.InvalidTransaction])
pruneTxMemPool =
  withLedgerState $ \world -> do
    nodeEnv <- ask
    modifyNodeState txPool $ \memPool -> do
      let memPoolTxs = DL.toList $ MemPool.transactions $ memPool
      validTxs <- runNodeT nodeEnv $
        withApplyCtx $ \applyCtx ->
          liftBase $ Validate.validateTransactions applyCtx world memPoolTxs
      case validTxs of
        Right _ -> pure (memPool, (memPoolTxs,[]))
        Left errs ->
          let invalidTxs   = flip map errs $ \(Tx.InvalidTransaction tx _) -> tx
              newMemPool   = MemPool.removeTxs memPool invalidTxs
              txsInMemPool = DL.toList $ MemPool.transactions newMemPool
          in pure (newMemPool, (txsInMemPool, errs))

-- | Atomically remove all specified transactions from the MemPool
removeTxsFromMemPool :: MonadBase IO m => [Tx.Transaction] -> NodeT m ()
removeTxsFromMemPool txs  =
  modifyNodeState_ txPool $ \memPool ->
    pure $ MemPool.removeTxs memPool txs

elemTxMemPool :: Tx.Transaction -> MonadBase IO m => NodeT m Bool
elemTxMemPool tx = pure . flip MemPool.elemMemPool tx =<< getTxMemPool

elemTxMemPool' :: ByteString -> MonadBase IO m => NodeT m Bool
elemTxMemPool' txHash = pure . flip MemPool.elemMemPool' txHash =<< getTxMemPool

isTestNode :: Monad m => NodeT m Bool
isTestNode = Config.testMode <$> askConfig

isValidatingNode :: MonadBase IO m => NodeT m Bool
isValidatingNode = do
  validatorAddrs <- CAP.unValidatorSet <$> getValidatorSet
  selfAddr <- askSelfAddress
  return $ selfAddr `Set.member` validatorAddrs

getValidatorSet :: MonadBase IO m => NodeT m CAP.ValidatorSet
getValidatorSet = do
  lastBlock <- getLastBlock
  let poa = Block.consensus $ Block.header lastBlock
  return $ CAP.validatorSet poa

-- | Returns list of peers that are validating nodes
getValidatorPeers :: MonadBase IO m => NodeT m Peers
getValidatorPeers = do
  peers <- getPeers
  validatorAddrs <- CAP.unValidatorSet <$> getValidatorSet
  return $ flip Set.filter peers $ \peer ->
    peerAccAddr peer `Set.member` validatorAddrs

withApplyCtx :: MonadBase IO m => (Validate.ApplyCtx -> NodeT m a) -> NodeT m a
withApplyCtx f = do
  latestBlk   <- getLastBlock
  nodeAddress <- askSelfAddress
  nodePrivKey <- askPrivateKey
  f Validate.ApplyCtx
    { applyCurrBlock   = latestBlk
    , applyNodeAddress = nodeAddress
    , applyNodePrivKey = nodePrivKey
    }

-- | Query transaction status by hash
getTxStatus :: MonadBase IO m => ByteString -> NodeT m Tx.Status
getTxStatus txHash = do
  elemTxMemPool <- elemTxMemPool' txHash
  if elemTxMemPool
    then pure Tx.Pending
    else do
      elemInvalidTxPool <- elemInvalidTxPool txHash
      if elemInvalidTxPool
        then pure Tx.Rejected
        else pure Tx.Accepted

-------------------------------------------------------------------------------
-- Query Ledger (World) state
-------------------------------------------------------------------------------

lookupInLedger :: MonadBase IO m => (Ledger.World -> a) -> NodeT m a
lookupInLedger f = withLedgerState $ return . f

lookupAccount
  :: MonadBase IO m
  => Address.Address
  -> NodeT m (Either Ledger.AccountError Account.Account)
lookupAccount = lookupInLedger . Ledger.lookupAccount

withAccount
  :: MonadBase IO m
  => Address.Address
  -> (Account.Account -> NodeT m a)
  -> NodeT m (Either Ledger.AccountError a)
withAccount addr f = do
  eAcc <- lookupAccount addr
  case eAcc of
    Left err -> pure $ Left err
    Right acc -> Right <$> f acc

-------------------------------------------------------------------------------
-- Sync Ledger State & DB
-------------------------------------------------------------------------------

applyBlock
  :: MonadBase IO m
  => Block.Block
  -> NodeT m (Either Tx.InvalidTransaction ())
applyBlock block =
  withLedgerState $ \ledgerState ->
    withApplyCtx $ \applyCtx -> do
      (newWorld, errs, deltasMap) <- liftBase $
        Validate.applyBlock applyCtx ledgerState block
      -- New block should only be applied if 0 errors in block
      case head errs of
        Just err -> return $ Left err
        Nothing  -> fmap Right $ do
          -- Atomically remove transactions in this block from NodeState mempool
          removeTxsFromMemPool $ Block.transactions block

          -- Update Latest block in NodeState
          setLastBlock block

          -- Update New World state in NodeState
          setLedger newWorld

          -- Write Deltas collected during applyBlock to TxLog
          let blockIdx = Block.index block

          -- Write the entire block's transacction list to TxLog in database
          liftBase $ forM_ (Map.toList deltasMap) $ do
            uncurry $ TxLog.writeDeltas (fromIntegral blockIdx) (TxLog.txLogFile ".")
            uncurry $ TxLog.writeDeltasJSON (fromIntegral blockIdx) (TxLog.txLogFile ".")

syncNodeStateWithDBs
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => NodeT m (Either Text ())
syncNodeStateWithDBs = do
  eRes <- syncWorldWithDBs
  case eRes of
    Left err -> pure $ Left err
    Right _  -> syncLastBlockWithDBs

syncWorldWithDBs :: MonadWriteDB m => NodeT m (Either Text ())
syncWorldWithDBs = withLedgerState (lift . DB.syncWorld)

-- | Since blocks are not stored in ledger(world) state, we
-- must sync them to the DB separately
syncLastBlockWithDBs
  :: (MonadBaseControl IO m, MonadWriteDB m)
  => NodeT m (Either Text ())
syncLastBlockWithDBs =
    fmap (first show) $
      tryWriteBlock =<< getLastBlock
  where
    try' :: MonadBaseControl IO m => m () -> m (Either SqlError ())
    try' = try

    tryWriteBlock = lift . try' . DB.writeBlock

-------------------------------------------------------------------------------
--
-- ** Node Data Persistance to FileSystem **
--
-- XXX Everything below this comment pertains (or should pertain) to reading and
-- writing of node specific data to the File System. Perhaps in the future some
-- of the data should be stored in whichever backend the uplink node is using,
-- but for now, the following code handles the "on disk" storage of:
--
--   * [Network Peers]
--     Serialization of all known peer process ids and their respective accound
--     addresses.
--
--   * [Node Account Data]
--     Data pertaining to an uplink node's account.
--     * Node account (JSON serialized)
--     * Node account public key (PEM)
--     * Node account private key (PEM)
--
--   * [TxLog]
--     A list of modifications to world state resulting from smart contract
--     function calls, i.e. TxCall transactions.
--
--   * [Preallocated Accounts]    XXX (Remove?)
--     A directory of accounts and their key pairs that bootstrap the network.
--     In the initial implementation of Uplink w/ it's Proof of Authority
--     consensus algorithm, these preallocate accounts correspond the the
--     initial validating nodes in the network. These files are created by
--     'uplink keys <validatorsDir> <n validators>'
--
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Read/Write Peers
-------------------------------------------------------------------------------

peersFile :: FilePath -> FilePath
peersFile root = root </> "peers"

loadPeers :: FilePath -> IO Peers
loadPeers root = do
   let peersFile' = peersFile root
   peersFileExists <- doesFileExist peersFile'
   if peersFileExists then
     Binary.decode <$> BSL.readFile peersFile'
   else pure Set.empty

savePeers :: FilePath -> Peers -> IO ()
savePeers root peers = do
   let peersFile' = peersFile root
   BSL.writeFile peersFile' $ Binary.encode peers
   let mode = unionFileModes ownerReadMode ownerWriteMode
   setFileMode peersFile' mode

-------------------------------------------------------------------------------
-- Load Preallocated Accounts
-------------------------------------------------------------------------------

-- | Loads the validator set from a directory of the form:
--   <Dir of Account dirs>/
--       - <Account Dir 1>/
--           - key                 -- Private Key
--           - key.pub             -- Public Key
--           - account             -- JSON Serialized Account
--       - <Account Dir 2>/
--           - key                 -- Private Key
--           - key.pub             -- Public Key
--           - account             -- JSON Serialized Account
--       ...
--       - <Account Dir N>/
--           - key                 -- Private Key
--           - key.pub             -- Public Key
--           - account             -- JSON Serialized Account

loadPreallocatedAccs :: MonadBase IO m => NodeT m (Either Text [Account.Account])
loadPreallocatedAccs = do
  dir <- Config.preallocated <$> askConfig
  liftBase $ loadPreallocatedAccs' dir

loadPreallocatedAccs'
  :: MonadBase IO m
  => FilePath
  -> m (Either Text [Account.Account])
loadPreallocatedAccs' dir = do
  dirExists <- liftBase $ doesDirectoryExist dir
  if not dirExists
    then pure $ Left
      "No preallocated accounts directory found."
    else do
      accDirs <- liftBase $ listDirectory dir
      if (null accDirs)
        then pure $ Left $
          "No accounts found in preallocated accounts directory: " <> show dir
        else fmap (Right . rights) $
          forM accDirs $ \accDir -> do
            eAcc <- liftBase $
              Account.loadAccount $ dir </> accDir
            case eAcc of
              Left err -> Log.warning $ show err
              Right _  -> pure ()
            pure $ fst <$> eAcc
