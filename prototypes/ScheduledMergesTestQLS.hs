{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ScheduledMergesTestQLS (tests) where

import           Prelude hiding (lookup)

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import           Data.Proxy
import           Data.Constraint (Dict(..))

import           Control.Monad.ST
import           Control.Tracer (Tracer, nullTracer)

import           ScheduledMerges

import           Test.QuickCheck
import           Test.QuickCheck.StateModel hiding (lookUpVar)
import           Test.QuickCheck.StateModel.Lockstep hiding (ModelOp)
import qualified Test.QuickCheck.StateModel.Lockstep.Defaults as Lockstep
import qualified Test.QuickCheck.StateModel.Lockstep.Run      as Lockstep
import           Test.Tasty
import           Test.Tasty.QuickCheck (testProperty)


-------------------------------------------------------------------------------
-- Tests
--

tests :: TestTree
tests = testGroup "ScheduledMerges" [
      testProperty "ScheduledMerges vs model" prop_LSM
    ]

prop_LSM :: Actions (Lockstep Model) -> Property
prop_LSM = Lockstep.runActions (Proxy :: Proxy Model)


-------------------------------------------------------------------------------
-- QLS infrastructure
--

type ModelLSM = Int

newtype Model = Model { mlsms :: Map ModelLSM (Map Key Value) }
  deriving (Show)

type ModelOp r = Model -> (r, Model)

modelNew       ::                             ModelOp ModelLSM
modelInsert    :: ModelLSM -> Key -> Value -> ModelOp ()
modelDelete    :: ModelLSM -> Key ->          ModelOp ()
modelLookup    :: ModelLSM -> Key ->          ModelOp (Maybe Value)
modelDuplicate :: ModelLSM ->                 ModelOp ModelLSM
modelDump      :: ModelLSM ->                 ModelOp (Map Key Value)

initModel :: Model
initModel = Model { mlsms = Map.empty }

modelNew Model {mlsms} =
    (mlsm, Model { mlsms = Map.insert mlsm Map.empty mlsms })
  where
    mlsm = Map.size mlsms

modelInsert mlsm k v Model {mlsms} =
    ((), Model { mlsms = Map.adjust (Map.insert k v) mlsm mlsms })

modelDelete mlsm k Model {mlsms} =
    ((), Model { mlsms = Map.adjust (Map.delete k) mlsm mlsms })

modelLookup mlsm k model@Model {mlsms} =
    (result, model)
  where
    Just mval = Map.lookup mlsm mlsms
    result    = Map.lookup k mval

modelDuplicate mlsm Model {mlsms} =
    (mlsm', Model { mlsms = Map.insert mlsm' mval mlsms })
  where
    Just mval = Map.lookup mlsm mlsms
    mlsm'     = Map.size mlsms

modelDump mlsm model@Model {mlsms} =
    (mval, model)
  where
    Just mval = Map.lookup mlsm mlsms

instance StateModel (Lockstep Model) where
  data Action (Lockstep Model) a where
    ANew    :: Action (Lockstep Model) (LSM RealWorld)
    
    AInsert :: ModelVar Model (LSM RealWorld)
            -> Either (ModelVar Model Key) Key -- to refer to a prior key
            -> Value
            -> Action (Lockstep Model) (Key)

    ADelete :: ModelVar Model (LSM RealWorld)
            -> Either (ModelVar Model Key) Key
            -> Action (Lockstep Model) ()
   
    ALookup :: ModelVar Model (LSM RealWorld)
            -> Either (ModelVar Model Key) Key
            -> Action (Lockstep Model) (Maybe Value)

    ADuplicate :: ModelVar Model (LSM RealWorld)
               -> Action (Lockstep Model) (LSM RealWorld)

    ADump   :: ModelVar Model (LSM RealWorld)
            -> Action (Lockstep Model) (Map Key Value)

  initialState    = Lockstep.initialState initModel
  nextState       = Lockstep.nextState
  precondition    = Lockstep.precondition
  arbitraryAction = Lockstep.arbitraryAction
  shrinkAction    = Lockstep.shrinkAction

instance RunModel (Lockstep Model) IO where
  perform       = \_state -> runActionIO
  postcondition = Lockstep.postcondition
  monitoring    = Lockstep.monitoring (Proxy :: Proxy IO)

instance InLockstep Model where
  data ModelValue Model a where
    MLSM    :: ModelLSM      -> ModelValue Model (LSM RealWorld)
    MUnit   :: ()            -> ModelValue Model ()
    MInsert :: Key           -> ModelValue Model (Key)
    MLookup :: Maybe Value   -> ModelValue Model (Maybe Value)
    MDump   :: Map Key Value -> ModelValue Model (Map Key Value)

  data Observable Model a where
    ORef :: Observable Model (LSM RealWorld)
    OId  :: (Show a, Eq a) => a -> Observable Model a

  observeModel (MLSM    _) = ORef
  observeModel (MUnit   x) = OId x
  observeModel (MInsert x) = OId x
  observeModel (MLookup x) = OId x
  observeModel (MDump   x) = OId x

  usedVars  ANew             = []
  usedVars (AInsert v evk _) = SomeGVar v
                             : case evk of Left vk -> [SomeGVar vk]; _ -> []
  usedVars (ADelete v evk)   = SomeGVar v
                             : case evk of Left vk -> [SomeGVar vk]; _ -> []
  usedVars (ALookup v evk)   = SomeGVar v
                             : case evk of Left vk -> [SomeGVar vk]; _ -> []
  usedVars (ADuplicate v)    = [SomeGVar v]
  usedVars (ADump v)         = [SomeGVar v]

  modelNextState = runModel

  arbitraryWithVars findVars _model =
    case findVars (Proxy :: Proxy (LSM RealWorld)) of
      []   -> return (Some ANew)
      vars ->
        frequency $
            -- inserts of potentially fresh keys
          [ (3, fmap Some $
                  AInsert <$> elements vars
                          <*> fmap Right arbitrarySizedNatural -- key
                          <*> arbitrarySizedNatural)           -- value
          ]
            -- inserts of the same keys as used earlier
       ++ [ (1, fmap Some $
                  AInsert <$> elements vars
                          <*> fmap Left (elements kvars) -- key var
                          <*> arbitrarySizedNatural)    -- value
          | let kvars = findVars (Proxy :: Proxy Key)
          , not (null kvars)
          ]
          -- deletes of arbitrary keys:
       ++ [ (1, fmap Some $
                  ADelete <$> elements vars
                          <*> fmap Right arbitrarySizedNatural) -- key value
          ]
          -- deletes of the same key as inserted earlier:
       ++ [ (1, fmap Some $
                  ADelete <$> elements vars
                          <*> fmap Left (elements kvars)) -- key var
          | let kvars = findVars (Proxy :: Proxy Key)
          , not (null kvars)
          ]
          -- lookup of arbitrary keys:
       ++ [ (1, fmap Some $
                  ALookup <$> elements vars
                          <*> fmap Right arbitrarySizedNatural) -- key value
          ]
          -- lookup of the same key as inserted earlier:
       ++ [ (3, fmap Some $
                  ALookup <$> elements vars
                          <*> fmap Left (elements kvars)) -- key var
          | let kvars = findVars (Proxy :: Proxy Key)
          , not (null kvars)
          ]
       ++ [ (1, fmap Some $
                  ADump <$> elements vars)
          ]
       ++ [ (1, fmap Some $
                  ADuplicate <$> elements vars)
          ]

  shrinkWithVars _findVars _model (AInsert var (Right k) v) =
    [ Some $ AInsert var (Right k') v' | (k', v') <- shrink (k, v) ]

  shrinkWithVars _findVars _model (AInsert var (Left _kv) v) =
    [ Some $ AInsert var (Right k) v | k <- shrink 100 ]

  shrinkWithVars _findVars _model (ADelete var (Right k)) =
    [ Some $ ADelete var (Right k') | k' <- shrink k ]

  shrinkWithVars _findVars _model (ADelete var (Left _kv)) =
    [ Some $ ADelete var (Right k) | k <- shrink 100 ]

  shrinkWithVars _findVars _model _action = []
    

instance RunLockstep Model IO where
  observeReal _ action result =
    case (action, result) of
      (ANew,         _) -> ORef
      (AInsert{},    x) -> OId x
      (ADelete{},    x) -> OId x
      (ALookup{},    x) -> OId x
      (ADump{},      x) -> OId x
      (ADuplicate{}, _) -> ORef

  showRealResponse _ ANew = Nothing
  showRealResponse _ AInsert{} = Just Dict
  showRealResponse _ ADelete{} = Just Dict
  showRealResponse _ ALookup{} = Just Dict
  showRealResponse _ ADump{}   = Just Dict
  showRealResponse _ ADuplicate{} = Nothing

deriving instance Show (Action (Lockstep Model) a)
deriving instance Show (Observable Model a)
deriving instance Show (ModelValue Model a)

deriving instance Eq (Action (Lockstep Model) a)
deriving instance Eq (Observable Model a)
deriving instance Eq (ModelValue Model a)


runActionIO :: Action (Lockstep Model) a
            -> LookUp IO
            -> IO a
runActionIO action lookUp =
  stToIO $
  case action of
    ANew              -> new
    AInsert var evk v -> insert tr (lookUpVar var) k v >> return k
      where k = either lookUpVar id evk
    ADelete var evk   -> delete tr (lookUpVar var) k >> return ()
      where k = either lookUpVar id evk
    ALookup var evk   -> lookupResultValue <$> lookup (lookUpVar var) k
      where k = either lookUpVar id evk
    ADuplicate var    -> duplicate (lookUpVar var)
    ADump      var    -> logicalValue (lookUpVar var)
  where
    lookUpVar :: ModelVar Model a -> a
    lookUpVar = lookUpGVar (Proxy :: Proxy IO) lookUp

    lookupResultValue (NotFound _k)           = Nothing
    lookupResultValue (Found _k v)            = Just v
    lookupResultValue (FoundWithBlob _k v _b) = Just v

    tr :: Tracer (ST RealWorld) Event
    tr = nullTracer

runModel :: Action (Lockstep Model) a
         -> ModelLookUp Model
         -> Model -> (ModelValue Model a, Model)
runModel action lookUp m =
  case action of
    ANew -> (MLSM mlsm, m')
      where (mlsm, m') = modelNew m

    AInsert var evk v -> (MInsert k, m')
      where ((), m') = modelInsert (lookUpLsMVar var) k v m
            k = either lookUpKeyVar id evk

    ADelete var evk -> (MUnit (), m')
      where ((), m') = modelDelete (lookUpLsMVar var) k m
            k = either lookUpKeyVar id evk

    ALookup var evk -> (MLookup mv, m')
      where (mv, m') = modelLookup (lookUpLsMVar var) k m
            k = either lookUpKeyVar id evk

    ADuplicate var -> (MLSM mlsm', m')
      where (mlsm', m') = modelDuplicate (lookUpLsMVar var) m

    ADump var -> (MDump mapping, m)
      where (mapping, _) = modelDump (lookUpLsMVar var) m
  where
    lookUpLsMVar :: ModelVar Model (LSM RealWorld) -> ModelLSM
    lookUpLsMVar var = case lookUp var of MLSM r -> r

    lookUpKeyVar :: ModelVar Model Key -> Key
    lookUpKeyVar var = case lookUp var of MInsert k -> k

