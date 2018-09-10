{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ConstraintKinds #-}
-- | A representation of nested-parallel in-kernel per-workgroup
-- expressions.
module Futhark.Representation.Kernels.KernelExp
  ( KernelExp(..)
  , GroupStreamLambda(..)
  , SplitOrdering(..)
  , CombineSpace(..)
  , combineSpace
  , scopeOfCombineSpace
  , typeCheckKernelExp
  )
  where

import Control.Monad
import Data.Monoid ((<>))
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Map.Strict as M

import qualified Futhark.Analysis.Alias as Alias
import qualified Futhark.Analysis.Range as Range
import qualified Futhark.Analysis.UsageTable as UT
import Futhark.Representation.Aliases
import Futhark.Representation.Ranges
import Futhark.Transform.Substitute
import Futhark.Transform.Rename
import Futhark.Optimise.Simplify.Lore
import Futhark.Analysis.Usage
import Futhark.Analysis.Metrics
import qualified Futhark.Analysis.ScalExp as SE
import qualified Futhark.Analysis.SymbolTable as ST
import Futhark.Util.Pretty
  ((<+>), (</>), ppr, comma, commasep, Pretty, parens, text, apply, braces, annot, indent)
import qualified Futhark.TypeCheck as TC
import Futhark.Util (chunks)

-- | How an array is split into chunks.
data SplitOrdering = SplitContiguous
                   | SplitStrided SubExp
                   deriving (Eq, Ord, Show)

-- | A combine can be fully or partially in-place.  The initial arrays
-- here work like the ones from the Scatter SOAC.
data CombineSpace = CombineSpace { cspaceScatter :: [(SubExp, Int, VName)]
                                 , cspaceDims :: [(VName,SubExp)] }
                  deriving (Eq, Ord, Show)

combineSpace :: [(VName,SubExp)] -> CombineSpace
combineSpace = CombineSpace []

scopeOfCombineSpace :: CombineSpace -> Scope lore
scopeOfCombineSpace (CombineSpace _ dims) =
  M.fromList $ zip (map fst dims) $ repeat $ IndexInfo Int32

data KernelExp lore = SplitSpace SplitOrdering SubExp SubExp SubExp
                      -- ^ @SplitSpace o w i elems_per_thread@.
                      --
                      -- Computes how to divide array elements to
                      -- threads in a kernel.  Returns the number of
                      -- elements in the chunk that the current thread
                      -- should take.
                      --
                      -- @w@ is the length of the outer dimension in
                      -- the array. @i@ is the current thread
                      -- index. Each thread takes at most
                      -- @elems_per_thread@ elements.
                      --
                      -- If the order @o@ is 'SplitContiguous', thread with index @i@
                      -- should receive elements
                      -- @i*elems_per_tread, i*elems_per_thread + 1,
                      -- ..., i*elems_per_thread + (elems_per_thread-1)@.
                      --
                      -- If the order @o@ is @'SplitStrided' stride@,
                      -- the thread will receive elements @i,
                      -- i+stride, i+2*stride, ...,
                      -- i+(elems_per_thread-1)*stride@.
                    | Combine CombineSpace [Type] [(VName,SubExp)] (Body lore)
                      -- ^ @Combine cspace ts aspace body@ will
                      -- combine values from threads to a single
                      -- (multidimensional) array.  If we define @(is,
                      -- ws) = unzip cspace@, then @ws@ is defined the
                      -- same accross all threads.  The @cspace@
                      -- defines the shape of the resulting array, and
                      -- the identifiers used to identify each
                      -- individual element.  Only threads for which
                      -- @all (\(i,w) -> i < w) aspace@ is true will
                      -- provide a value (of type @ts@), which is
                      -- generated by @body@.
                      --
                      -- The result of a combine is always stored in local
                      -- memory (OpenCL terminology)
                      --
                      -- The same thread may be assigned to multiple
                      -- elements of 'Combine', if the size of the
                      -- 'CombineSpace' exceeds the group size.
                    | GroupReduce SubExp
                      (Lambda lore) [(SubExp,VName)]
                      -- ^ @GroupReduce w lam input@ (with @(nes, arrs) = unzip input@),
                      -- will perform a reduction of the arrays @arrs@ using the
                      -- associative reduction operator @lam@ and the neutral
                      -- elements @nes@.
                      --
                      -- The arrays @arrs@ must all have outer
                      -- dimension @w@, which must not be larger than
                      -- the group size.
                      --
                      -- Currently a GroupReduce consumes the input arrays, as
                      -- it uses them for scratch space to store temporary
                      -- results
                      --
                      -- All threads in a group must participate in a
                      -- GroupReduce (due to barriers)
                      --
                      -- The length of the arrays @w@ can be smaller than the
                      -- number of elements in a group (neutral element will be
                      -- filled in), but @w@ can never be larger than the group
                      -- size.
                    | GroupScan SubExp
                      (Lambda lore) [(SubExp,VName)]
                      -- ^ Same restrictions as with 'GroupReduce'.
                    | GroupStream SubExp SubExp
                      (GroupStreamLambda lore) [SubExp] [VName]
                      -- Morally a StreamSeq
                      -- First  SubExp is the outersize of the array
                      -- Second SubExp is the maximal chunk size
                      -- [SubExp] is the accumulator, [VName] are the input arrays
                    | GroupGenReduce SubExp [VName] (LambdaT lore) SubExp [SubExp] VName
                      -- ^ GroupGenReduce <length> <destarrays> <op> <bucket> <values> <locks array>
                    | Barrier [SubExp]
                      -- ^ HACK: Semantically identity, but inserts a
                      -- barrier afterwards.  This reflects a weakness
                      -- in our kernel representation.
                    deriving (Eq, Ord, Show)

data GroupStreamLambda lore = GroupStreamLambda
  { groupStreamChunkSize :: VName
  , groupStreamChunkOffset :: VName
  , groupStreamAccParams :: [LParam lore]
  , groupStreamArrParams :: [LParam lore]
  , groupStreamLambdaBody :: Body lore
  }

deriving instance Annotations lore => Eq (GroupStreamLambda lore)
deriving instance Annotations lore => Show (GroupStreamLambda lore)
deriving instance Annotations lore => Ord (GroupStreamLambda lore)

instance Attributes lore => IsOp (KernelExp lore) where
  safeOp _ = False
  cheapOp _ = True

instance Attributes lore => TypedOp (KernelExp lore) where
  opType SplitSpace{} =
    pure $ staticShapes [Prim int32]
  opType (Combine (CombineSpace scatter cspace) ts _ _) =
    pure $ staticShapes $
    zipWith arrayOfRow val_ts ws ++
    map (`arrayOfShape` shape) (drop (sum ns*2) ts)
    where shape = Shape $ map snd cspace
          val_ts = concatMap (take 1) $ chunks ns $
                   take (sum ns) $ drop (sum ns) ts
          (ws, ns, _) = unzip3 scatter
  opType (GroupReduce _ lam _) =
    pure $ staticShapes $ lambdaReturnType lam
  opType (GroupScan w lam _) =
    pure $ staticShapes $ map (`arrayOfRow` w) (lambdaReturnType lam)
  opType (GroupStream _ _ lam _ _) =
    pure $ staticShapes $ map paramType $ groupStreamAccParams lam
  opType (GroupGenReduce _ dests _ _ _ _) =
    staticShapes <$> traverse lookupType dests
  opType (Barrier ses) = staticShapes <$> traverse subExpType ses

instance FreeIn SplitOrdering where
  freeIn SplitContiguous = mempty
  freeIn (SplitStrided stride) = freeIn stride

instance Attributes lore => FreeIn (KernelExp lore) where
  freeIn (SplitSpace o w i elems_per_thread) =
    freeIn o <> freeIn [w, i, elems_per_thread]
  freeIn (Combine (CombineSpace scatter cspace) ts active body) =
    freeIn scatter <> freeIn (map snd cspace) <> freeIn ts <> freeIn active <> freeInBody body
  freeIn (GroupReduce w lam input) =
    freeIn w <> freeInLambda lam <> freeIn input
  freeIn (GroupScan w lam input) =
    freeIn w <> freeInLambda lam <> freeIn input
  freeIn (GroupStream w maxchunk lam accs arrs) =
    freeIn w <> freeIn maxchunk <> freeIn lam <> freeIn accs <> freeIn arrs
  freeIn (GroupGenReduce w dests op bucket values locks) =
    freeIn w <> freeIn dests <> freeInLambda op <> freeIn bucket <> freeIn values <> freeIn locks
  freeIn (Barrier ses) = freeIn ses

instance Attributes lore => FreeIn (GroupStreamLambda lore) where
  freeIn (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
    freeInBody body `S.difference` bound_here
    where bound_here = S.fromList $
                       chunk_offset : chunk_size :
                       map paramName (acc_params ++ arr_params)

instance Ranged inner => RangedOp (KernelExp inner) where
  opRanges (SplitSpace _ _ _ elems_per_thread) =
    [(Just (ScalarBound 0),
      Just (ScalarBound (SE.subExpToScalExp elems_per_thread int32)))]
  opRanges _ = repeat unknownRange

instance (Attributes lore, Aliased lore) => AliasedOp (KernelExp lore) where
  opAliases SplitSpace{} =
    [mempty]
  opAliases Combine{} =
    [mempty]
  opAliases (GroupReduce _ lam _) =
    replicate (length (lambdaReturnType lam)) mempty
  opAliases (GroupScan _ lam _) =
    replicate (length (lambdaReturnType lam)) mempty
  opAliases (GroupStream _ _ lam _ _) =
    map (const mempty) $ groupStreamAccParams lam
  opAliases (GroupGenReduce _ dests _ _ _ _) =
    map S.singleton dests
  opAliases (Barrier ses) = map subExpAliases ses

  consumedInOp (GroupReduce _ _ input) =
    S.fromList $ map snd input
  consumedInOp (GroupScan _ _ input) =
    S.fromList $ map snd input
  consumedInOp (GroupStream _ _ lam accs arrs) =
    -- GroupStream always consumes array-typed accumulators.  This
    -- guarantees that we can use their storage for the result of the
    -- lambda.
    S.map consumedArray $
    S.fromList (map paramName acc_params) <> consumedInBody body
    where GroupStreamLambda _ _ acc_params arr_params body = lam
          consumedArray v = fromMaybe v $ subExpVar =<< lookup v params_to_arrs
          params_to_arrs = zip (map paramName $ acc_params ++ arr_params) $
                           accs ++ map Var arrs
  consumedInOp (GroupGenReduce _ dests _ _ _ _) =
    S.fromList dests

  consumedInOp SplitSpace{} = mempty
  consumedInOp Barrier{} = mempty
  consumedInOp (Combine _ _ _ body) = consumedInBody body

instance Substitute SplitOrdering where
  substituteNames _ SplitContiguous =
    SplitContiguous
  substituteNames subst (SplitStrided stride) =
    SplitStrided $ substituteNames subst stride

instance Substitute CombineSpace where
  substituteNames substs (CombineSpace scatter dims) =
    CombineSpace (map sub scatter) (substituteNames substs dims)
    where sub (w, n, a) =
            (substituteNames substs w, n, substituteNames substs a)

instance Attributes lore => Substitute (KernelExp lore) where
  substituteNames subst (SplitSpace o w i elems_per_thread) =
    SplitSpace
    (substituteNames subst o)
    (substituteNames subst w)
    (substituteNames subst i)
    (substituteNames subst elems_per_thread)
  substituteNames subst (Combine cspace ts active v) =
    Combine (substituteNames subst cspace) ts
    (substituteNames subst active) (substituteNames subst v)
  substituteNames subst (GroupReduce w lam input) =
    GroupReduce (substituteNames subst w)
    (substituteNames subst lam) (substituteNames subst input)
  substituteNames subst (GroupScan w lam input) =
    GroupScan (substituteNames subst w)
    (substituteNames subst lam) (substituteNames subst input)
  substituteNames subst (GroupStream w maxchunk lam accs arrs) =
    GroupStream
    (substituteNames subst w) (substituteNames subst maxchunk)
    (substituteNames subst lam)
    (substituteNames subst accs) (substituteNames subst arrs)
  substituteNames subst (GroupGenReduce w dests op bucket vs locks) =
    GroupGenReduce (substituteNames subst w) (substituteNames subst dests)
    (substituteNames subst op) (substituteNames subst bucket) (substituteNames subst vs)
    (substituteNames subst locks)
  substituteNames substs (Barrier ses) = Barrier $ substituteNames substs ses

instance Attributes lore => Substitute (GroupStreamLambda lore) where
  substituteNames
    subst (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
    GroupStreamLambda
    (substituteNames subst chunk_size)
    (substituteNames subst chunk_offset)
    (substituteNames subst acc_params)
    (substituteNames subst arr_params)
    (substituteNames subst body)

instance Rename SplitOrdering where
  rename SplitContiguous =
    pure SplitContiguous
  rename (SplitStrided stride) =
    SplitStrided <$> rename stride

instance Rename CombineSpace where
  rename = substituteRename

instance Renameable lore => Rename (KernelExp lore) where
  rename (SplitSpace o w i elems_per_thread) =
    SplitSpace
    <$> rename o
    <*> rename w
    <*> rename i
    <*> rename elems_per_thread
  rename (Combine cspace ts active v) =
    Combine <$> rename cspace <*> rename ts <*> rename active <*> rename v
  rename (GroupReduce w lam input) =
    GroupReduce <$> rename w <*> rename lam <*> rename input
  rename (GroupScan w lam input) =
    GroupScan <$> rename w <*> rename lam <*> rename input
  rename (GroupStream w maxchunk lam accs arrs) =
    GroupStream <$> rename w <*> rename maxchunk <*>
    rename lam <*> rename accs <*> rename arrs
  rename (GroupGenReduce w dests op bucket vs locks) =
    GroupGenReduce <$> rename w <*> rename dests <*> rename op <*>
    rename bucket <*> rename vs <*> rename locks
  rename (Barrier ses) = Barrier <$> mapM rename ses

instance Renameable lore => Rename (GroupStreamLambda lore) where
  rename (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
    bindingForRename (chunk_size : chunk_offset : map paramName (acc_params++arr_params)) $
    GroupStreamLambda <$>
    rename chunk_size <*>
    rename chunk_offset <*>
    rename acc_params <*>
    rename arr_params <*>
    rename body

instance (Attributes lore,
          Attributes (Aliases lore),
          CanBeAliased (Op lore)) => CanBeAliased (KernelExp lore) where
  type OpWithAliases (KernelExp lore) = KernelExp (Aliases lore)

  addOpAliases (SplitSpace o w i elems_per_thread) =
    SplitSpace o w i elems_per_thread
  addOpAliases (GroupReduce w lam input) =
    GroupReduce w (Alias.analyseLambda lam) input
  addOpAliases (GroupScan w lam input) =
    GroupScan w (Alias.analyseLambda lam) input
  addOpAliases (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk lam' accs arrs
    where lam' = analyseGroupStreamLambda lam
          analyseGroupStreamLambda (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            Alias.analyseBody body
  addOpAliases (GroupGenReduce w dests op bucket vs locks) =
    GroupGenReduce w dests (Alias.analyseLambda op) bucket vs locks
  addOpAliases (Combine cspace ts active body) =
    Combine cspace ts active $ Alias.analyseBody body
  addOpAliases (Barrier ses) = Barrier ses

  removeOpAliases (GroupReduce w lam input) =
    GroupReduce w (removeLambdaAliases lam) input
  removeOpAliases (GroupScan w lam input) =
    GroupScan w (removeLambdaAliases lam) input
  removeOpAliases (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk (removeGroupStreamLambdaAliases lam) accs arrs
    where removeGroupStreamLambdaAliases (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            removeBodyAliases body
  removeOpAliases (GroupGenReduce w dests op bucket vs locks) =
    GroupGenReduce w dests (removeLambdaAliases op) bucket vs locks
  removeOpAliases (Combine cspace ts active body) =
    Combine cspace ts active $ removeBodyAliases body
  removeOpAliases (SplitSpace o w i elems_per_thread) =
    SplitSpace o w i elems_per_thread
  removeOpAliases (Barrier ses) = Barrier ses

instance (Attributes lore,
          Attributes (Ranges lore),
          CanBeRanged (Op lore)) => CanBeRanged (KernelExp lore) where
  type OpWithRanges (KernelExp lore) = KernelExp (Ranges lore)

  addOpRanges (SplitSpace o w i elems_per_thread) =
    SplitSpace o w i elems_per_thread
  addOpRanges (GroupReduce w lam input) =
    GroupReduce w (Range.runRangeM $ Range.analyseLambda lam) input
  addOpRanges (GroupScan w lam input) =
    GroupScan w (Range.runRangeM $ Range.analyseLambda lam) input
  addOpRanges (GroupGenReduce w dests op bucket vs locks) =
    GroupGenReduce w dests (Range.runRangeM $ Range.analyseLambda op) bucket vs locks
  addOpRanges (Combine cspace ts active body) =
    Combine cspace ts active $ Range.runRangeM $ Range.analyseBody body
  addOpRanges (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk lam' accs arrs
    where lam' = analyseGroupStreamLambda lam
          analyseGroupStreamLambda (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            Range.runRangeM $ Range.analyseBody body
  addOpRanges (Barrier ses) = Barrier ses

  removeOpRanges (GroupReduce w lam input) =
    GroupReduce w (removeLambdaRanges lam) input
  removeOpRanges (GroupScan w lam input) =
    GroupScan w (removeLambdaRanges lam) input
  removeOpRanges (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk (removeGroupStreamLambdaRanges lam) accs arrs
    where removeGroupStreamLambdaRanges (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            removeBodyRanges body
  removeOpRanges (GroupGenReduce w dests op bucket vs locks) =
    GroupGenReduce w dests (removeLambdaRanges op) bucket vs locks
  removeOpRanges (Combine cspace ts active body) =
    Combine cspace ts active $ removeBodyRanges body
  removeOpRanges (SplitSpace o w i elems_per_thread) =
    SplitSpace o w i elems_per_thread
  removeOpRanges (Barrier ses) = Barrier ses

instance (Attributes lore, CanBeWise (Op lore)) => CanBeWise (KernelExp lore) where
  type OpWithWisdom (KernelExp lore) = KernelExp (Wise lore)

  removeOpWisdom (GroupReduce w lam input) =
    GroupReduce w (removeLambdaWisdom lam) input
  removeOpWisdom (GroupScan w lam input) =
    GroupScan w (removeLambdaWisdom lam) input
  removeOpWisdom (GroupStream w maxchunk lam accs arrs) =
    GroupStream w maxchunk (removeGroupStreamLambdaWisdom lam) accs arrs
    where removeGroupStreamLambdaWisdom
            (GroupStreamLambda chunk_size chunk_offset acc_params arr_params body) =
            GroupStreamLambda chunk_size chunk_offset acc_params arr_params $
            removeBodyWisdom body
  removeOpWisdom (GroupGenReduce w dests op bucket vs locks) =
    GroupGenReduce w dests (removeLambdaWisdom op) bucket vs locks
  removeOpWisdom (Combine cspace ts active body) =
    Combine cspace ts active $ removeBodyWisdom body
  removeOpWisdom (SplitSpace o w i elems_per_thread) =
    SplitSpace o w i elems_per_thread
  removeOpWisdom (Barrier ses) = Barrier ses

instance ST.IndexOp (KernelExp lore) where

instance Aliased lore => UsageInOp (KernelExp lore) where
  usageInOp (Combine _ _ _ body) =
    mconcat $ map UT.consumedUsage $ S.toList $ consumedInBody body
  usageInOp _ = mempty

instance OpMetrics (Op lore) => OpMetrics (KernelExp lore) where
  opMetrics SplitSpace{} = seen "SplitSpace"
  opMetrics Combine{} = seen "Combine"
  opMetrics (GroupReduce _ lam _) = inside "GroupReduce" $ lambdaMetrics lam
  opMetrics (GroupScan _ lam _) = inside "GroupScan" $ lambdaMetrics lam
  opMetrics (GroupGenReduce _ _ op _ _ _) = inside "GroupGenReduce" $ lambdaMetrics op
  opMetrics (GroupStream _ _ lam _ _) =
    inside "GroupStream" $ groupStreamLambdaMetrics lam
    where groupStreamLambdaMetrics =
            bodyMetrics . groupStreamLambdaBody
  opMetrics Barrier{} = seen "Barrier"

typeCheckKernelExp :: TC.Checkable lore => KernelExp (Aliases lore) -> TC.TypeM lore ()

typeCheckKernelExp Barrier{} = return ()

typeCheckKernelExp (SplitSpace o w i elems_per_thread) = do
  case o of
    SplitContiguous     -> return ()
    SplitStrided stride -> TC.require [Prim int32] stride
  mapM_ (TC.require [Prim int32]) [w, i, elems_per_thread]

typeCheckKernelExp (Combine cspace@(CombineSpace scatter dims) ts aspace body) = do
  mapM_ (TC.require [Prim int32]) ws
  TC.binding (scopeOfCombineSpace cspace) $ do
    let (_as_ws, as_ns, _as_vs) = unzip3 scatter
        num_scatters = sum as_ns
        ts_is = take num_scatters ts
        ts_vs = take num_scatters $ drop num_scatters ts

    unless (length ts_is == num_scatters && length ts_vs == num_scatters) $
      TC.bad $ TC.TypeError "Combine: inconsistent return type annotation."

    forM_ ts_is $ \ts_i -> unless (Prim int32 == ts_i) $
      TC.bad $ TC.TypeError "Combine: index return type must be i32."

    forM_ (zip (chunks as_ns ts_vs) scatter) $ \(ts_vs', (aw, _, a)) -> do
      TC.require [Prim int32] aw
      forM_ ts_vs' $ \ts_v -> TC.requireI [ts_v `arrayOfRow` aw] a
      TC.consume =<< TC.lookupAliases a

    mapM_ TC.checkType ts
    mapM_ (TC.requireI [Prim int32]) a_is
    mapM_ (TC.require [Prim int32]) a_ws
    TC.checkLambdaBody ts body
  where ws = map snd dims
        (a_is, a_ws) = unzip aspace

typeCheckKernelExp (GroupReduce w lam input) =
  checkScanOrReduce w lam input

typeCheckKernelExp (GroupScan w lam input) =
  checkScanOrReduce w lam input

typeCheckKernelExp (GroupGenReduce w dests op bucket vs locks) = do
  TC.require [Prim int32] w

  dest_row_ts <- mapM (fmap rowType . lookupType) dests

  TC.require [Prim int32] bucket

  vs_ts <- mapM subExpType vs
  unless (vs_ts == dest_row_ts) $
    TC.bad $ TC.TypeError $ "Destination arrays have type " ++
    pretty dest_row_ts ++ ", but values to write have type " ++ pretty vs_ts

  let asArg t = (t, mempty)
  TC.checkLambda op $ map asArg $ dest_row_ts ++ vs_ts

typeCheckKernelExp (GroupStream w maxchunk lam accs arrs) = do
  TC.require [Prim int32] w
  TC.require [Prim int32] maxchunk

  acc_args <- mapM TC.checkArg accs
  arr_args <- TC.checkSOACArrayArgs w arrs

  checkGroupStreamLambda acc_args arr_args
  where GroupStreamLambda block_size _ acc_params arr_params body = lam
        checkGroupStreamLambda acc_args arr_args = do
          unless (map TC.argType acc_args == map paramType acc_params) $
            TC.bad $ TC.TypeError
            "checkGroupStreamLambda: wrong accumulator arguments."

          let arr_block_ts =
                map ((`arrayOfRow` Var block_size) . TC.argType) arr_args
          unless (map paramType arr_params == arr_block_ts) $
            TC.bad $ TC.TypeError
            "checkGroupStreamLambda: wrong array arguments."

          let acc_consumable =
                zip (map paramName acc_params) (map TC.argAliases acc_args)
              arr_consumable =
                zip (map paramName arr_params) (map TC.argAliases arr_args)
              consumable = acc_consumable ++ arr_consumable
          TC.binding (scopeOf lam) $ TC.consumeOnlyParams consumable $ do
            TC.checkLambdaParams acc_params
            TC.checkLambdaParams arr_params
            TC.checkLambdaBody (map TC.argType acc_args) body

checkScanOrReduce :: TC.Checkable lore =>
                     SubExp -> Lambda (Aliases lore) -> [(SubExp, VName)]
                  -> TC.TypeM lore ()
checkScanOrReduce w lam input = do
  TC.require [Prim int32] w
  let (nes, arrs) = unzip input
      asArg t = (t, mempty)
  neargs <- mapM TC.checkArg nes
  arrargs <- TC.checkSOACArrayArgs w arrs
  TC.checkLambda lam $
    map asArg [Prim int32, Prim int32] ++
    map TC.noArgAliases (neargs ++ arrargs)

instance Scoped lore (GroupStreamLambda lore) where
  scopeOf (GroupStreamLambda chunk_size chunk_offset acc_params arr_params _) =
    M.insert chunk_size (IndexInfo Int32) $
    M.insert chunk_offset (IndexInfo Int32) $
    scopeOfLParams (acc_params ++ arr_params)

instance PrettyLore lore => Pretty (KernelExp lore) where
  ppr (SplitSpace o w i elems_per_thread) =
    text "splitSpace" <> suff <>
    parens (commasep [ppr w, ppr i, ppr elems_per_thread])
    where suff = case o of SplitContiguous     -> mempty
                           SplitStrided stride -> text "Strided" <> parens (ppr stride)
  ppr (Combine (CombineSpace scatter cspace) ts active body) =
    text "combine" <>
    apply (map (\(_,n,a) -> text "@" <> ppr (n,a)) scatter ++
           map (\(i,w) -> ppr i <+> text "<" <+> ppr w) cspace ++
           [apply (map ppr ts), ppr active]) <+> text "{" </>
    indent 2 (ppr body) </>
    text "}"
  ppr (GroupReduce w lam input) =
    text "reduce" <> parens (commasep [ppr w,
                                       ppr lam,
                                       braces (commasep $ map ppr nes),
                                       commasep $ map ppr els])
    where (nes,els) = unzip input
  ppr (GroupScan w lam input) =
    text "scan" <> parens (commasep [ppr w,
                                     ppr lam,
                                     braces (commasep $ map ppr nes),
                                     commasep $ map ppr els])
    where (nes,els) = unzip input
  ppr (GroupStream w maxchunk lam accs arrs) =
    text "stream" <>
    parens (ppr w <> comma <+> ppr maxchunk <> comma </>
            ppr lam <> comma </>
            braces (commasep $ map ppr accs) <> comma </>
            commasep (map ppr arrs))

  ppr (GroupGenReduce w dests op bucket vs locks) =
    text "gen_reduce" <>
    parens (ppr w <> comma </>
            braces (commasep $ map ppr dests) <> comma </>
            ppr op <> comma </>
            commasep (map ppr $ bucket : vs) </> ppr locks)

  ppr (Barrier ses) = text "barrier" <> parens (commasep $ map ppr ses)

instance PrettyLore lore => Pretty (GroupStreamLambda lore) where
  ppr (GroupStreamLambda block_size block_offset acc_params arr_params body) =
    annot (mapMaybe ppAnnot params) $
    text "fn" <+>
    parens (commasep (block_size' : block_offset' : map ppr params)) <+>
    text "=>" </> indent 2 (ppr body)
    where params = acc_params ++ arr_params
          block_size' = text "int" <+> ppr block_size
          block_offset' = text "int" <+> ppr block_offset
