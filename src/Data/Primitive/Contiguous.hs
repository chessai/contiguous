{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UnboxedTuples #-}
module Data.Primitive.Contiguous
  ( Contiguous(..)
  , Always
  , map
  , foldr
  , foldMap
  , foldl'
  , foldr'
  , foldMap'
  , foldlM'
  , traverse_
  , itraverse_
  , unsafeFromListN
  , unsafeFromListReverseN
  , liftHashWithSalt
  ) where

import Prelude hiding (map,foldr,foldMap)
import Control.Monad.ST (ST,runST)
import Data.Bits (xor)
import Data.Kind (Type)
import Data.Primitive
import GHC.Exts (ArrayArray#,Constraint,sizeofByteArray#,sizeofArray#,sizeofArrayArray#)

class Always a
instance Always a

-- | A contiguous array of elements.
class Contiguous (arr :: Type -> Type) where
  type family Mutable arr = (r :: Type -> Type -> Type) | r -> arr
  type family Element arr :: Type -> Constraint
  empty :: arr a
  null :: arr b -> Bool
  new :: Element arr b => Int -> ST s (Mutable arr s b)
  replicateM :: Element arr b => Int -> b -> ST s (Mutable arr s b)
  index :: Element arr b => arr b -> Int -> b
  index# :: Element arr b => arr b -> Int -> (# b #)
  indexM :: (Element arr b, Monad m) => arr b -> Int -> m b
  read :: Element arr b => Mutable arr s b -> Int -> ST s b
  write :: Element arr b => Mutable arr s b -> Int -> b -> ST s ()
  resize :: Element arr b => Mutable arr s b -> Int -> ST s (Mutable arr s b)
  size :: Element arr b => arr b -> Int
  sizeMutable :: Element arr b => Mutable arr s b -> ST s Int
  unsafeFreeze :: Mutable arr s b -> ST s (arr b)
  copy :: Element arr b => Mutable arr s b -> Int -> arr b -> Int -> Int -> ST s ()
  copyMutable :: Element arr b => Mutable arr s b -> Int -> Mutable arr s b -> Int -> Int -> ST s ()
  clone :: Element arr b => arr b -> Int -> Int -> arr b
  cloneMutable :: Element arr b => Mutable arr s b -> Int -> Int -> ST s (Mutable arr s b)
  equals :: (Element arr b, Eq b) => arr b -> arr b -> Bool
  unlift :: arr b -> ArrayArray#
  lift :: ArrayArray# -> arr b

instance Contiguous PrimArray where
  type Mutable PrimArray = MutablePrimArray
  type Element PrimArray = Prim
  empty = mempty
  new = newPrimArray
  replicateM = replicatePrimArrayM
  index = indexPrimArray
  index# arr ix = (# indexPrimArray arr ix #)
  indexM arr ix = return (indexPrimArray arr ix)
  read = readPrimArray
  write = writePrimArray
  resize = resizeMutablePrimArray
  size = sizeofPrimArray
  sizeMutable = getSizeofMutablePrimArray
  unsafeFreeze = unsafeFreezePrimArray
  copy = copyPrimArray
  copyMutable = copyMutablePrimArray
  clone = clonePrimArray
  cloneMutable = cloneMutablePrimArray
  equals = (==)
  unlift = toArrayArray#
  lift = fromArrayArray#
  null (PrimArray a) = case sizeofByteArray# a of
    0# -> True
    _ -> False

instance Contiguous Array where
  type Mutable Array = MutableArray
  type Element Array = Always
  empty = mempty
  new n = newArray n errorThunk
  replicateM = newArray
  index = indexArray
  index# = indexArray##
  indexM = indexArrayM
  read = readArray
  write = writeArray
  resize = resizeArray
  size = sizeofArray
  sizeMutable = pure . sizeofMutableArray
  unsafeFreeze = unsafeFreezeArray
  copy = copyArray
  copyMutable = copyMutableArray
  clone = cloneArray
  cloneMutable = cloneMutableArray
  equals = (==)
  unlift = toArrayArray#
  lift = fromArrayArray#
  null (Array a) = case sizeofArray# a of
    0# -> True
    _ -> False

instance Contiguous UnliftedArray where
  type Mutable UnliftedArray = MutableUnliftedArray
  type Element UnliftedArray = PrimUnlifted
  empty = emptyUnliftedArray
  new = unsafeNewUnliftedArray
  replicateM = newUnliftedArray
  index = indexUnliftedArray
  index# arr ix = (# indexUnliftedArray arr ix #)
  indexM arr ix = return (indexUnliftedArray arr ix)
  read = readUnliftedArray
  write = writeUnliftedArray
  resize = resizeUnliftedArray
  size = sizeofUnliftedArray
  sizeMutable = pure . sizeofMutableUnliftedArray
  unsafeFreeze = unsafeFreezeUnliftedArray
  copy = copyUnliftedArray
  copyMutable = copyMutableUnliftedArray
  clone = cloneUnliftedArray
  cloneMutable = cloneMutableUnliftedArray
  equals = (==)
  unlift = toArrayArray#
  lift = fromArrayArray#
  null (UnliftedArray a) = case sizeofArrayArray# a of
    0# -> True
    _ -> False

errorThunk :: a
errorThunk = error "Contiguous typeclass: unitialized element"
{-# NOINLINE errorThunk #-}

resizeArray :: Always a => MutableArray s a -> Int -> ST s (MutableArray s a)
resizeArray !src !sz = do
  dst <- newArray sz errorThunk
  copyMutableArray dst 0 src 0 (min sz (sizeofMutableArray src))
  return dst
{-# INLINE resizeArray #-}

resizeUnliftedArray :: PrimUnlifted a => MutableUnliftedArray s a -> Int -> ST s (MutableUnliftedArray s a)
resizeUnliftedArray !src !sz = do
  dst <- unsafeNewUnliftedArray sz
  copyMutableUnliftedArray dst 0 src 0 (min sz (sizeofMutableUnliftedArray src))
  return dst
{-# INLINE resizeUnliftedArray #-}

emptyUnliftedArray :: UnliftedArray a
emptyUnliftedArray = runST (unsafeNewUnliftedArray 0 >>= unsafeFreezeUnliftedArray)
{-# NOINLINE emptyUnliftedArray #-}

-- | Map over the elements of an array.
map :: (Contiguous arr1, Element arr1 b, Contiguous arr2, Element arr2 c) => (b -> c) -> arr1 b -> arr2 c
map f a = runST $ do
  mb <- new (size a)
  let go !i
        | i == size a = return ()
        | otherwise = do
            x <- indexM a i
            write mb i (f x)
            go (i+1)
  go 0
  unsafeFreeze mb
{-# INLINABLE map #-}

-- | Right fold over the element of an array.
foldr :: (Contiguous arr, Element arr a) => (a -> b -> b) -> b -> arr a -> b
foldr f z arr = go 0
  where
    !sz = size arr
    go !i
      | sz > i = case index# arr i of
          (# x #) -> f x (go (i+1))
      | otherwise = z

-- | Strict left fold over the elements of an array.
foldl' :: (Contiguous arr, Element arr a) => (b -> a -> b) -> b -> arr a -> b
foldl' f !z !ary =
  let
    !sz = size ary
    go !i !acc
      | i == sz = acc
      | (# x #) <- index# ary i = go (i+1) (f acc x)
  in go 0 z
{-# INLINABLE foldl' #-}

-- | Strict right fold over the elements of an array.
foldr' :: (Contiguous arr, Element arr a) => (a -> b -> b) -> b -> arr a -> b
foldr' f !z !ary =
  let
    go i !acc
      | i == -1 = acc
      | (# x #) <- index# ary i
      = go (i-1) (f x acc)
  in go (size ary - 1) z
{-# INLINABLE foldr' #-}

-- | Monoidal fold over the element of an array.
foldMap :: (Contiguous arr, Element arr a, Monoid m) => (a -> m) -> arr a -> m
foldMap f arr = go 0
  where
    !sz = size arr
    go !i
      | sz > i = case index# arr i of
          (# x #) -> mappend (f x) (go (i+1))
      | otherwise = mempty
{-# INLINABLE foldMap #-}

-- | Strict monoidal fold over the elements of an array.
foldMap' :: (Contiguous arr, Element arr a, Monoid m)
  => (a -> m) -> arr a -> m
foldMap' f !ary =
  let
    !sz = size ary
    go !i !acc
      | i == sz = acc
      | (# x #) <- index# ary i = go (i+1) (mappend acc (f x))
  in go 0 mempty
{-# INLINABLE foldMap' #-}

-- | Strict left monadic fold over the elements of an array.
foldlM' :: (Contiguous arr, Element arr a, Monad m) => (b -> a -> m b) -> b -> arr a -> m b
foldlM' f z0 arr = go 0 z0
  where
    !sz = size arr
    go !i !acc1
      | i < sz = do
          let (# x #) = index# arr i
          acc2 <- f acc1 x
          go (i + 1) acc2
      | otherwise = return acc1
{-# INLINABLE foldlM' #-}

clonePrimArray :: Prim a => PrimArray a -> Int -> Int -> PrimArray a
clonePrimArray !arr !off !len = runST $ do
  marr <- newPrimArray len
  copyPrimArray marr 0 arr off len
  unsafeFreezePrimArray marr
{-# INLINE clonePrimArray #-}

cloneMutablePrimArray :: Prim a => MutablePrimArray s a -> Int -> Int -> ST s (MutablePrimArray s a)
cloneMutablePrimArray !arr !off !len = do
  marr <- newPrimArray len
  copyMutablePrimArray marr 0 arr off len
  return marr
{-# INLINE cloneMutablePrimArray #-}

replicatePrimArrayM :: Prim a
  => Int -- ^ length
  -> a -- ^ element
  -> ST s (MutablePrimArray s a)
replicatePrimArrayM len a = do
  marr <- newPrimArray len
  setPrimArray marr 0 len a
  return marr
{-# INLINE replicatePrimArrayM #-}

-- | Create an array from a list. If the given length does
-- not match the actual length, this function has undefined
-- behavior.
unsafeFromListN :: (Contiguous arr, Element arr a)
  => Int -- ^ length of list
  -> [a] -- ^ list
  -> arr a
unsafeFromListN n l = runST $ do
  m <- new n
  let go !_ [] = return ()
      go !ix (x : xs) = do
        write m ix x
        go (ix+1) xs
  go 0 l
  unsafeFreeze m

-- | Create an array from a list, reversing the order of the
-- elements. If the given length does not match the actual length,
-- this function has undefined behavior.
unsafeFromListReverseN :: (Contiguous arr, Element arr a)
  => Int
  -> [a]
  -> arr a
unsafeFromListReverseN n l = runST $ do
  m <- new n
  let go !_ [] = return ()
      go !ix (x : xs) = do
        write m ix x
        go (ix-1) xs
  go (n - 1) l
  unsafeFreeze m

traverse_ ::
     (Contiguous arr, Element arr a, Applicative f)
  => (a -> f b)
  -> arr a
  -> f ()
traverse_ f a = go 0 where
  !sz = size a
  go !ix = if ix < sz
    then f (index a ix) *> go (ix + 1)
    else pure ()
{-# INLINABLE traverse_ #-}

itraverse_ ::
     (Contiguous arr, Element arr a, Applicative f)
  => (Int -> a -> f b)
  -> arr a
  -> f ()
itraverse_ f a = go 0 where
  !sz = size a
  go !ix = if ix < sz
    then f ix (index a ix) *> go (ix + 1)
    else pure ()
{-# INLINABLE itraverse_ #-}

liftHashWithSalt :: (Contiguous arr, Element arr a)
  => (Int -> a -> Int)
  -> Int
  -> arr a
  -> Int
liftHashWithSalt f s0 arr = go 0 s0 where
  sz = size arr
  go !ix !s = if ix < sz
    then 
      let !(# x #) = index# arr ix
       in go (ix + 1) (f s x)
    else hashIntWithSalt s ix
{-# INLINABLE liftHashWithSalt #-}

hashIntWithSalt :: Int -> Int -> Int
hashIntWithSalt salt x = salt `combine` x

combine :: Int -> Int -> Int
combine h1 h2 = (h1 * 16777619) `xor` h2


