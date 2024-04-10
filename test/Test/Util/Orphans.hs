{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE StandaloneKindSignatures   #-}
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Test.Util.Orphans () where

import           Control.Concurrent.Class.MonadMVar (MonadMVar (..))
import           Control.Concurrent.Class.MonadSTM (MonadSTM (..))
import qualified Control.Concurrent.MVar as Real
import qualified Control.Concurrent.STM as Real
import           Control.Monad ((<=<))
import           Control.Monad.IOSim (IOSim)
import           Data.Kind (Type)
import           Database.LSMTree.Common (IOLike)
import           Database.LSMTree.Internal.BlobRef
import           Database.LSMTree.Internal.Serialise (SerialiseKey)
import           Database.LSMTree.Normal (LookupResult, RangeLookupResult,
                     TableHandle)
import qualified Database.LSMTree.Orphans ()
import           Test.QuickCheck.Modifiers (Small (..))
import           Test.QuickCheck.StateModel (Realized)
import           Test.QuickCheck.StateModel.Lockstep (InterpretOp)
import qualified Test.QuickCheck.StateModel.Lockstep.Op as Op
import qualified Test.QuickCheck.StateModel.Lockstep.Op.SumProd as SumProd
import           Test.Util.TypeFamilyWrappers (WrapBlob (..), WrapBlobRef (..),
                     WrapTableHandle (..))

{-------------------------------------------------------------------------------
  IOSim
-------------------------------------------------------------------------------}

instance IOLike (IOSim s)

type instance Realized (IOSim s) a = RealizeIOSim s a

type RealizeIOSim :: Type -> Type -> Type
type family RealizeIOSim s a where
  -- io-classes
  RealizeIOSim s (Real.TVar a)  = TVar (IOSim s) a
  RealizeIOSim s (Real.TMVar a) = TMVar (IOSim s) a
  RealizeIOSim s (Real.MVar a)  = MVar (IOSim s) a
  -- lsm-tree
  RealizeIOSim s (TableHandle IO k v blob)       = TableHandle (IOSim s) k v blob
  RealizeIOSim s (LookupResult k v blobref)      = LookupResult k v (RealizeIOSim s blobref)
  RealizeIOSim s (RangeLookupResult k v blobref) = RangeLookupResult k v (RealizeIOSim s blobref)
  RealizeIOSim s (BlobRef IO blob)               = BlobRef (IOSim s) blob
  -- Type family wrappers
  RealizeIOSim s (WrapTableHandle h IO k v blob) = WrapTableHandle h (IOSim s) k v blob
  RealizeIOSim s (WrapBlobRef h IO blob)         = WrapBlobRef h (IOSim s) blob
  RealizeIOSim s (WrapBlob blob)                 = WrapBlob blob
  -- Congruence
  RealizeIOSim s (f a b) = f (RealizeIOSim s a) (RealizeIOSim s b)
  RealizeIOSim s (f a)   = f (RealizeIOSim s a)
  -- Default
  RealizeIOSim s a = a

instance InterpretOp SumProd.Op (Op.WrapRealized (IOSim s)) where
  intOp ::
       SumProd.Op a b
    -> Op.WrapRealized (IOSim s) a
    -> Maybe (Op.WrapRealized (IOSim s) b)
  intOp = \case
      SumProd.OpId    -> Just
      SumProd.OpFst   -> Just . Op.WrapRealized . fst . Op.unwrapRealized
      SumProd.OpSnd   -> Just . Op.WrapRealized . snd . Op.unwrapRealized
      SumProd.OpLeft  -> either (Just . Op.WrapRealized) (const Nothing) . Op.unwrapRealized
      SumProd.OpRight -> either (const Nothing) (Just . Op.WrapRealized) . Op.unwrapRealized
      SumProd.OpComp g f -> Op.intOp g <=< Op.intOp f

{-------------------------------------------------------------------------------
  QuickCheck
-------------------------------------------------------------------------------}

deriving newtype instance SerialiseKey a => SerialiseKey (Small a)
