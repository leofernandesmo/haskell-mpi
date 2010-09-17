{-# LANGUAGE FlexibleContexts, ScopedTypeVariables #-}

module Control.Parallel.MPI.StorableArray
   ( send
   , ssend
   , bsend
   , rsend
   , recv
   , bcast
   , isend
   , ibsend
   , issend
   , irecv
   , sendScatter
   , recvScatter
   , sendScatterv
   , recvScatterv
   , sendGather
   , recvGather
   , sendGatherv
   , recvGatherv
   , withRange
   , withRange_
   ) where

import C2HS
import Data.Array.Base (unsafeNewArray_)
import Data.Array.Storable
import Control.Applicative ((<$>))
import qualified Control.Parallel.MPI.Internal as Internal
import Control.Parallel.MPI.Datatype as Datatype
import Control.Parallel.MPI.Comm as Comm
import Control.Parallel.MPI.Status as Status
import Control.Parallel.MPI.Utils (checkError)
import Control.Parallel.MPI.Tag as Tag
import Control.Parallel.MPI.Rank as Rank
import Control.Parallel.MPI.Request as Request
import Control.Parallel.MPI.Common (commRank)

-- | if the user wants to call recvScatterv for the first time without
-- already having allocated the array, then they can call it like so:
--
-- (array,_) <- withRange range $ recvScatterv root comm
--
-- and thereafter they can call it like so:
--
--  recvScatterv root comm array
withRange :: forall i e a. (Ix i, Storable e) => (i,i) -> (StorableArray i e -> IO a) -> IO (StorableArray i e, a)
withRange range f = do
  arr <- unsafeNewArray_ range -- New, uninitialized array, According to http://hackage.haskell.org/trac/ghc/ticket/3586
                               -- should be faster than newArray_
  res <- f arr
  return (arr, res)

-- | Same as withRange, but discards the result of the processor function
withRange_ :: forall i e a. (Ix i, Storable e) => (i,i) -> (StorableArray i e -> IO ()) -> IO (StorableArray i e)
withRange_ range f = do
  arr <- unsafeNewArray_ range
  f arr
  return arr

send, bsend, ssend, rsend :: forall e i. (Storable e, Ix i) => Comm -> Rank -> Tag -> StorableArray i e -> IO ()
send  = sendWith Internal.send
bsend = sendWith Internal.bsend
ssend = sendWith Internal.ssend
rsend = sendWith Internal.rsend

sendWith :: forall e i. (Storable e, Ix i) =>
  (Ptr () -> CInt -> Datatype -> CInt -> CInt -> Comm -> IO CInt) ->
  Comm -> Rank -> Tag -> StorableArray i e -> IO ()
sendWith send_function comm rank tag array = do
   withStorableArrayAndSize array $ \arrayPtr numBytes -> do
      checkError $ send_function (castPtr arrayPtr) numBytes byte (fromRank rank) (fromTag tag) comm

recv :: forall e i . (Storable e, Ix i) => Comm -> Rank -> Tag -> StorableArray i e -> IO Status
recv comm rank tag arr = do
   withStorableArrayAndSize arr $ \arrayPtr numBytes ->
      alloca $ \statusPtr -> do
         checkError $ Internal.recv (castPtr arrayPtr) numBytes byte (fromRank rank) (fromTag tag) comm (castPtr statusPtr)
         peek statusPtr

bcast :: forall e i. (Storable e, Ix i) => Comm -> Rank -> StorableArray i e -> IO ()
bcast comm sendRank array = do
   withStorableArrayAndSize array $ \arrayPtr numBytes -> do
      checkError $ Internal.bcast (castPtr arrayPtr) numBytes byte (fromRank sendRank) comm

isend, ibsend, issend :: forall e i . (Storable e, Ix i) => Comm -> Rank -> Tag -> StorableArray i e -> IO Request
isend  = isendWith Internal.isend
ibsend = isendWith Internal.ibsend
issend = isendWith Internal.issend

isendWith :: forall e i . (Storable e, Ix i) =>
  (Ptr () -> CInt -> Datatype -> CInt -> CInt -> Comm -> Ptr (Request) -> IO CInt) ->
  Comm -> Rank -> Tag -> StorableArray i e -> IO Request
isendWith send_function comm recvRank tag array = do
   withStorableArrayAndSize array $ \arrayPtr numBytes -> 
      alloca $ \requestPtr -> do
         checkError $ send_function (castPtr arrayPtr) numBytes byte (fromRank recvRank) (fromTag tag) comm requestPtr
         peek requestPtr

irecv :: forall e i . (Storable e, Ix i) => Comm -> Rank -> Tag -> StorableArray i e -> IO Request
irecv comm sendRank tag array = do
   alloca $ \requestPtr ->
      withStorableArrayAndSize array $ \arrayPtr numBytes -> do
         checkError $ Internal.irecv (castPtr arrayPtr) numBytes byte (fromRank sendRank) (fromTag tag) comm requestPtr
         peek requestPtr

{-
   MPI_Scatter allows the element types of the send and recv buffers to be different.
   This is accommodated by changing the sendcount and recvcount arguments. I'm not sure
   about the utility of that feature in C, and I'm even less sure it would be a good idea
   in a strongly typed language like Haskell. So this version of scatter requires that
   the send and recv element types (e) are the same. Note we also use a (i,i) range
   argument instead of a sendcount argument. This makes it easier to work with
   arbitrary Ix types, instead of just integers. This gives scatter the same type signature
   as bcast, although the role of the range is different in the two. In bcast the range
   specifies the lower and upper indices of the entire sent/recv array. In scatter
   the range specifies the lower and upper indices of the sent/recv segment of the
   array.

   XXX is it an error if:
      (arraySize `div` segmentSize) /= commSize
-}
sendScatter :: forall e i. (Storable e, Ix i) => StorableArray i e -> (i, i) -> Rank -> Comm -> IO (StorableArray i e)
sendScatter array recvRange root comm = do
   (foreignPtr, numBytes) <- allocateBuffer recvRange
   withForeignPtr foreignPtr $ \recvPtr ->
     withStorableArray array $ \sendPtr -> 
       checkError $ Internal.scatter (castPtr sendPtr) numBytes byte (castPtr recvPtr) numBytes byte (fromRank root) comm
   unsafeForeignPtrToStorableArray foreignPtr recvRange

recvScatter :: forall e i. (Storable e, Ix i) => (i, i) -> Rank -> Comm -> IO (StorableArray i e)
recvScatter recvRange root comm = do
   (foreignPtr, numBytes) <- allocateBuffer recvRange
   withForeignPtr foreignPtr $ \recvPtr ->
     checkError $ Internal.scatter nullPtr numBytes byte (castPtr recvPtr) numBytes byte (fromRank root) comm
   unsafeForeignPtrToStorableArray foreignPtr recvRange


{-
For Scatterv/Gatherv we need arrays of "stripe lengths" and displacements.

Sometimes it would be easy for end-user to furnish those array, sometimes not.

We could steal the useful idea from mpy4pi and allow user to specify counts and displacements in several
ways - as a number, an "empty" value, or a list/array of values. Semantic is as following:

| count  | displacement | meaning                                                                                  |
|--------+--------------+------------------------------------------------------------------------------------------|
| number | nothing      | Uniform stripes of the given size, placed next to each other                             |
| number | number       | Uniform stripes of the given size, with "displ" values between them                      |
| number | vector       | Uniform stripes of the given size, at given displacements (we could check for overlap)   |
| vector | nothing      | Stripe lengths are given, compute the displacements assuming they are contiguous         |
| vector | number       | Stripe lengths are given, compute the displacements allowing "displ" values between them |
| vector | vector       | Stripes and displacements are pre-computed elsewhere                                     |


We could codify this with typeclass:

class CountsAndDisplacements a b where
  getCountsDisplacements :: (Ix i) => (i,i) -> a -> b -> (StorableArray Int Int, StorableArray Int Int)

instance CountsAndDisplacements Int Int where
  getCountsDisplacements bnds c d = striped bnds c d

instance CountsAndDisplacements Int (Maybe Int) where
  getCountsDisplacements bnds c Nothing  = striped bnds c 0
  getCountsDisplacements bnds c (Just d) = striped bnds c d

instance CountsAndDisplacements Int (StorableArray Int Int) where
  getCountsDisplacements bnds n displs  = countsOnly bnds n

instance CountsAndDisplacements (StorableArray Int Int) (Maybe Int) where
  getCountsDisplacements bnds cs Nothing  = displacementsFromCounts cs 0
  getCountsDisplacements bnds cs (Just d) = displacementsFromCounts cs d

instance CountsAndDisplacements (StorableArray Int Int) (StorableArray Int Int) where
  getCountsDisplacements bnds cs ds  = (cs,ds)

striped  = undefined
countsOnly = undefined
displacementsFromCounts = undefined

What do you think?
-}

-- Counts and displacements should be presented in ready-for-use form for speed, hence the choice of StorableArrays
-- See Serializable for other alternatives.

-- | XXX: this should be moved out to some convenience module
allocateBuffer :: forall e i. (Storable e, Ix i) => (i, i) -> IO (ForeignPtr e, CInt)
allocateBuffer recvRange = do
  let numElements = rangeSize recvRange
      elementSize = sizeOf (undefined :: e)
      numBytes = cIntConv (numElements * elementSize)
  foreignPtr <- mallocForeignPtrArray numElements
  return (foreignPtr, numBytes)
     
-- | XXX: this too should be moved out to some convenience module. Also, name is ugly
arrayByteSize :: (Storable e, Ix i) => StorableArray i e -> e -> IO CInt
arrayByteSize arr el = do
   rSize <- rangeSize <$> getBounds arr
   return $ cIntConv (rSize * sizeOf el)

-- receiver needs comm rank recvcount
-- sender needs everything else
sendScatterv :: forall e i. (Storable e, Ix i) => StorableArray i e -> StorableArray Int Int -> StorableArray Int Int -> (i, i) -> Rank -> Comm -> IO (StorableArray i e)     
sendScatterv array counts displacements recvRange root comm = do
   -- myRank <- commRank comm
   -- XXX: assert myRank == sendRank ?
   (foreignPtr, numBytes) <- allocateBuffer recvRange
   withForeignPtr foreignPtr $ \recvPtr ->
     withStorableArray array $ \sendPtr ->
       withStorableArray counts $ \countsPtr ->  
         withStorableArray displacements $ \displPtr ->  
           checkError $ Internal.scatterv (castPtr sendPtr) (castPtr countsPtr) (castPtr displPtr) byte (castPtr recvPtr) numBytes byte (fromRank root) comm
   unsafeForeignPtrToStorableArray foreignPtr recvRange

withStorableArrayAndSize :: (Storable e, Ix i) => StorableArray i e -> (Ptr e -> CInt -> IO a) -> IO a
withStorableArrayAndSize arr f = do
   numBytes <- arrayByteSize arr (undefined :: e)
   withStorableArray arr $ \ptr -> f ptr numBytes

recvScatterv :: forall e i. (Storable e, Ix i) => Comm -> Rank -> StorableArray i e -> IO ()
recvScatterv comm root arr = do
   -- myRank <- commRank comm
   -- XXX: assert (myRank /= sendRank)
   withStorableArrayAndSize arr $ \recvPtr numBytes ->
     checkError $ Internal.scatterv nullPtr nullPtr nullPtr byte (castPtr recvPtr) numBytes byte (fromRank root) comm
     
{-
XXX we should check that the outRange is large enough to store:

   segmentSize * commSize
-}

recvGather :: forall e i. (Storable e, Ix i) => StorableArray i e -> (i, i) -> Rank -> Comm -> IO (StorableArray i e)
recvGather segment outRange root comm = do
   segmentBytes <- arrayByteSize segment (undefined :: e)
   -- myRank <- commRank comm
   -- XXX: assert myRank == root
   (foreignPtr, _) <- allocateBuffer outRange
   withStorableArray segment $ \sendPtr ->
     withForeignPtr foreignPtr $ \recvPtr ->
       checkError $ Internal.gather (castPtr sendPtr) segmentBytes byte (castPtr recvPtr) segmentBytes byte (fromRank root) comm
   unsafeForeignPtrToStorableArray foreignPtr outRange

sendGather :: forall e i. (Storable e, Ix i) => StorableArray i e -> Rank -> Comm -> IO ()
sendGather segment root comm = do
   segmentBytes <- arrayByteSize segment (undefined :: e)
   -- myRank <- commRank comm
   -- XXX: assert it is /= root
   withStorableArray segment $ \sendPtr -> do
     -- the recvPtr is ignored in this case, so we can make it NULL, likewise recvCount can be 0
     checkError $ Internal.gather (castPtr sendPtr) segmentBytes byte nullPtr 0 byte (fromRank root) comm

recvGatherv :: forall e i. (Storable e, Ix i) => StorableArray i e -> StorableArray Int Int -> StorableArray Int Int -> (i, i) -> Rank -> Comm -> IO (StorableArray i e)
recvGatherv segment counts displacements outRange root comm = do
   segmentBytes <- arrayByteSize segment (undefined :: e)
   -- myRank <- commRank comm
   -- XXX: assert myRank == root
   (foreignPtr, _) <- allocateBuffer outRange
   withStorableArray segment $ \sendPtr ->
     withStorableArray counts $ \countsPtr ->  
        withStorableArray displacements $ \displPtr -> 
          withForeignPtr foreignPtr $ \recvPtr ->
            checkError $ Internal.gatherv (castPtr sendPtr) segmentBytes byte (castPtr recvPtr) (castPtr countsPtr) (castPtr displPtr) byte (fromRank root) comm
   unsafeForeignPtrToStorableArray foreignPtr outRange
    
sendGatherv :: forall e i. (Storable e, Ix i) => StorableArray i e -> Rank -> Comm -> IO ()
sendGatherv segment root comm = do
   segmentBytes <- arrayByteSize segment (undefined :: e)
   -- myRank <- commRank comm
   -- XXX: assert myRank == root
   withStorableArray segment $ \sendPtr ->
     -- the recvPtr, counts and displacements are ignored in this case, so we can make it NULL
     checkError $ Internal.gatherv (castPtr sendPtr) segmentBytes byte nullPtr nullPtr nullPtr byte (fromRank root) comm
