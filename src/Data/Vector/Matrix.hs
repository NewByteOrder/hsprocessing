{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}

module Data.Vector.Matrix where

--import Data.Vector

import qualified Data.Vector             as V
import qualified Data.Vector.Mutable     as MV

import           Prelude  ()
import qualified Prologue as P
import           Prologue hiding ((*), (+), sum)

import Data.Convert
import Data.Monoid (Sum(Sum), getSum)
import Control.Monad.State
import Data.List.Split (chunksOf)
import Type.List (RemovedIdx, ElAt)



data Boxed   = Boxed deriving (Show)
data Unboxed = Uboxed deriving (Show)




class                                  KnownNats (a :: [Nat]) where natLstVal :: Integral i => Proxy a -> [i]
instance                               KnownNats '[]          where natLstVal _ = []
instance (KnownNat a, KnownNats as) => KnownNats (a ': as)    where natLstVal _ = fromIntegral (natVal (Proxy :: Proxy a))
                                                                                : natLstVal            (Proxy :: Proxy as)

-----------------------------------------------------------------------
-- Arrays
-----------------------------------------------------------------------

-- === Types ===

data family Array (shape :: [Nat]) t a

type family ShapeOf (a :: * -> * -> *) :: [Nat]
type family TypeOf  (a :: * -> *)      :: *

class IsArray f where array :: Iso (f t a) (f t' a') (Array (ShapeOf f) t a) (Array (ShapeOf f) t' a')

-- TODO[WD]: Refactor - UnsafeIndex should be used from the containers library
class UnsafeIndex f t where unsafeIndex :: Int -> f t a -> a

-- utils
shapeOf :: forall f t a. KnownNats (ShapeOf f) => f t a -> [Int]
shapeOf _ = natLstVal (Proxy :: Proxy (ShapeOf f))


-- array info instances
type instance ShapeOf (Array shape)   = shape
type instance TypeOf  (Array shape t) = t

-- math relations instances
type instance ProductOf (Array sh t a) (Array sh t b) = Array sh t (ProductOf a b)

instance (sh ~ sh', t ~ t', Mul a b, IsList (Array sh t a), IsList (Array sh t b), IsList (Array sh t (ProductOf a b)))
      => Mul (Array sh t a) (Array sh' t' b) where
    a * b = fromList $ (uncurry (*) <$> zip (toList a) (toList b))

-- utils instances
instance IsArray  (Array shape) where array = id

instance (Monoid (Item (Array sh t a)), IsList (Array sh t a), KnownNats sh)
      => Monoid (Array sh t a) where
    mempty = fromList $ replicate (product $ natLstVal (Proxy :: Proxy sh)) mempty

instance IsList' (Array sh t a) => IsList (Array sh t a) where
    type Item (Array sh t a) = a
    fromList = fromList'
    toList   = toList'

-- TODO[WD]: refactor the IsList' class. It is used to show that for each Array data family instance, Item is the last param
class IsList' l where
  fromList' :: [Item l] -> l
  toList'   :: l        -> [Item l]


-- === Reshape ===

type family   Reshaped (sh :: [Nat]) (f :: * -> * -> *) :: * -> * -> *
type instance Reshaped nsh (Array sh) = Array nsh

class Reshape sh f t where unsafeReshape :: Proxy sh -> f t a -> Reshaped sh f t a
                           reshape       :: Proxy sh -> f t a -> Reshaped sh f t a


-- === ExtractDim ===

-- TODO[WD]: make it more general - extractDim should be named focusDim and be an Lens'
class ExtractDim (idx :: Nat) sh t where extractDim :: Proxy idx -> Array sh t a -> Array '[ElAt idx sh] t (Array (RemovedIdx idx sh) t a)

type ExtractRows = ExtractDim 1
type ExtractCols = ExtractDim 0

cols :: (ExtractCols sh t, idx ~ 0) => Array sh t a -> Array '[ElAt idx sh] t (Array (RemovedIdx idx sh) t a)
cols = extractDim (Proxy :: Proxy (0 :: Nat))

rows :: (ExtractRows sh t, idx ~ 1) => Array sh t a -> Array '[ElAt idx sh] t (Array (RemovedIdx idx sh) t a)
rows = extractDim (Proxy :: Proxy (1 :: Nat))


-- === Generators ===

class Generate sh t where
    generateArray :: (Int -> [Int] -> a) -> Array sh t a

type Generated f t = (Generate (ShapeOf f) t, IsArray f)

generate' :: Generated f t => (Int -> [Int] -> a) -> f t a
generate' = view (from array) . generateArray

generate :: Generated f t => ([Int] -> a) -> f t a
generate = generate' . const

constant :: Generated f t => a -> f t a
constant = generate . const

diagonal :: Generated f t => a -> a -> f t a
diagonal diag bgrnd = generate $ \lst -> if and $ fmap (== head lst) lst then diag else bgrnd



-----------------------------------------------------------------------
-- Matrix
-----------------------------------------------------------------------

newtype Matrix (width :: Nat) (height :: Nat) t a = Matrix (Array '[width, height] t a)

type instance ShapeOf (Matrix w h)   = '[w,h]
type instance TypeOf  (Matrix w h t) = t

-- derivings

deriving instance Show    (Array '[w,h] t a) => Show    (Matrix w h t a)
deriving instance Functor (Array '[w,h] t)   => Functor (Matrix w h t)

-- math relations instances

type instance ProductOf (Matrix w h t a) (Matrix w' h' t b) = Matrix w' h t (ProductOf a b)

instance ( w ~ h', t ~ t', Mul a b, IsList (Matrix w h t a), IsList (Matrix w' h' t' b), IsList (Matrix w' h t c)
         , ExtractRows '[w ,h ] t 
         , ExtractCols '[w',h'] t'
         , Generated (Matrix w' h) t
         , UnsafeIndex (Array '[w']) t'
         , IsList (Array '[h'] t' b)
         , UnsafeIndex (Array '[h]) t
         , IsList (Array '[w] t a)
         , c ~ (ProductOf a b)
         , Add c c
         , SumOf c c ~ c
         , Num c
         )
      => Mul (Matrix w h t a) (Matrix w' h' t' b) where
    m * m' = generate (\[x,y] -> gen x y) where
        a       = view array m
        a'      = view array m'
        rs      = rows a
        cs      = cols a'
        gen x y = sum (uncurry (*) <$> zip row col) where
            col = toList $ unsafeIndex x cs
            row = toList $ unsafeIndex y rs


--sum :: (Foldable t, Add a a, SumOf a a ~ a, Num a) => t a -> a


--generate :: Generated f t => ([Int] -> a) -> f t a
--generate = generate' . const

-- utils instances

instance IsArray (Matrix w h) where array = polyWrapped

instance Rewrapped (Matrix w h t a) (Matrix w h t' a')
instance Wrapped   (Matrix w h t a) where
    type Unwrapped (Matrix w h t a) = Array '[w, h] t a
    _Wrapped' = iso (\(Matrix a) -> a) Matrix

instance (IsList d, Monoid (Item d), KnownNats '[w,h], d ~ Unwrapped (Matrix w h t a))
      => Monoid (Matrix w h t a) where
    mempty = Matrix mempty 
    mappend (Matrix m1) (Matrix m2) = Matrix $ m1 <> m2

instance IsList (Unwrapped (Matrix w h t a)) => IsList (Matrix w h t a) where
    type Item (Matrix w h t a) = Item (Unwrapped (Matrix w h t a))
    fromList = view unwrapped . fromList
    toList   = toList . view wrapped




-----------------------------------------------------------------------
-- XForm & Quaternion
-----------------------------------------------------------------------

newtype XForm (dim :: Nat) t a = XForm (Matrix dim dim t a)
type    Quaternion             = XForm 4

-- class instances

type instance ShapeOf (XForm dim)   = '[dim,dim]
type instance TypeOf  (XForm dim t) = t

deriving instance Show (Unwrapped (XForm dim t a)) => Show    (XForm dim t a)
deriving instance Functor (Matrix dim dim t)       => Functor (XForm dim t)

instance IsArray (XForm dim) where array = polyWrapped . array

instance Rewrapped (XForm dim t a) (XForm dim' t' a')
instance Wrapped   (XForm dim t a) where
    type Unwrapped (XForm dim t a) = Matrix dim dim t a
    _Wrapped' = iso (\(XForm a) -> a) XForm


instance (Generated (XForm dim) t, Num a) => Monoid (XForm dim t a) where
    mempty = diagonal 1 0

instance IsList (Unwrapped (XForm dim t a)) => IsList (XForm dim t a) where
    type Item (XForm dim t a) = Item (Unwrapped (XForm dim t a))
    fromList = view unwrapped . fromList
    toList   = toList . view wrapped

-----------------------------------------------------------------------
-- Vector
-----------------------------------------------------------------------

newtype Vector (dim   :: Nat) t a = Vector (Array '[dim] t a)

type instance ShapeOf (Vector dim)   = '[dim]
type instance TypeOf  (Vector dim t) = t

-- class instances

deriving instance Show    (Array '[dim] t a) => Show    (Vector dim t a)
deriving instance Functor (Array '[dim] t)   => Functor (Vector dim t)

instance Rewrapped (Vector dim t a) (Vector dim t' a')
instance Wrapped   (Vector dim t a) where
    type Unwrapped (Vector dim t a) = Array '[dim] t a
    _Wrapped' = iso (\(Vector a) -> a) Vector

instance IsArray (Vector t) where array = polyWrapped

instance (IsList d, Monoid (Item d), KnownNat dim, d ~ Unwrapped (Vector dim t a))
      => Monoid (Vector dim t a) where
    mempty = Vector mempty

instance IsList (Array '[dim] t a) => IsList (Vector dim t a) where
    type Item (Vector dim t a) = Item (Unwrapped (Vector dim t a))
    fromList = view unwrapped . fromList
    toList   = toList . view wrapped



-- === Accessors ===

unsafeVIdx :: Int -> Lens' (V.Vector a) a
unsafeVIdx idx = lens (flip V.unsafeIndex idx) (\v el -> V.unsafeUpd v [(idx,el)])

unsafeSlice :: Int -> Int -> Lens' (V.Vector a) (V.Vector a)
unsafeSlice idx len = lens (V.unsafeSlice idx len) (\v els -> V.take (idx - 1) v <> els <> V.drop (idx + len - 1) v)


instance DimToSmallForIndex 0 "x" => Dim1 (Vector 0  ) Boxed
instance {-# OVERLAPPABLE #-}        Dim1 (Vector dim) Boxed where x = array . wrapped . unsafeVIdx 0

instance (DimToSmallForIndex 0 "y", Dim1 (Vector 0) Boxed) => Dim2 (Vector 0)   Boxed
instance (DimToSmallForIndex 1 "y", Dim1 (Vector 1) Boxed) => Dim2 (Vector 1)   Boxed
instance {-# OVERLAPPABLE #-}                                 Dim2 (Vector dim) Boxed where y = array . wrapped . unsafeVIdx 1

instance (DimToSmallForIndex 0 "z", Dim2 (Vector 0) Boxed) => Dim3 (Vector 0)   Boxed
instance (DimToSmallForIndex 1 "z", Dim2 (Vector 1) Boxed) => Dim3 (Vector 1)   Boxed
instance (DimToSmallForIndex 2 "z", Dim2 (Vector 2) Boxed) => Dim3 (Vector 2)   Boxed
instance {-# OVERLAPPABLE #-}                                 Dim3 (Vector dim) Boxed where z = array . wrapped . unsafeVIdx 2

instance (DimToSmallForIndex 0 "w", Dim3 (Vector 0) Boxed) => Dim4 (Vector 0)   Boxed
instance (DimToSmallForIndex 1 "w", Dim3 (Vector 1) Boxed) => Dim4 (Vector 1)   Boxed
instance (DimToSmallForIndex 2 "w", Dim3 (Vector 2) Boxed) => Dim4 (Vector 2)   Boxed
instance (DimToSmallForIndex 3 "w", Dim3 (Vector 3) Boxed) => Dim4 (Vector 3)   Boxed
instance {-# OVERLAPPABLE #-}                                 Dim4 (Vector dim) Boxed where w = array . wrapped . unsafeVIdx 3


------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
-- CARTESIAN

class DimToSmallForIndex (d :: Nat) (idx :: Symbol)

class             Dim1 f t where x   :: Lens' (f t a) a
class Dim1 f t => Dim2 f t where y   :: Lens' (f t a) a
                                 xy  :: Lens' (f t a) (Vector 2 t a)
                                 yx  :: Lens' (f t a) (Vector 2 t a)
class Dim2 f t => Dim3 f t where z   :: Lens' (f t a) a
                                 xz  :: Lens' (f t a) (Vector 2 t a)
                                 zx  :: Lens' (f t a) (Vector 2 t a)
                                 yz  :: Lens' (f t a) (Vector 2 t a)
                                 zy  :: Lens' (f t a) (Vector 2 t a)

                                 xyz :: Lens' (f t a) (Vector 3 t a)
                                 xzy :: Lens' (f t a) (Vector 3 t a)
                                 yxz :: Lens' (f t a) (Vector 3 t a)
                                 yzx :: Lens' (f t a) (Vector 3 t a)
                                 zxy :: Lens' (f t a) (Vector 3 t a)
                                 zyx :: Lens' (f t a) (Vector 3 t a)

class Dim3 f t => Dim4 f t where w   :: Lens' (f t a) a
                                 wx  :: Lens' (f t a) (Vector 2 t a)
                                 xw  :: Lens' (f t a) (Vector 2 t a)
                                 wy  :: Lens' (f t a) (Vector 2 t a)
                                 yw  :: Lens' (f t a) (Vector 2 t a)
                                 wz  :: Lens' (f t a) (Vector 2 t a)
                                 zw  :: Lens' (f t a) (Vector 2 t a)

                                 wxy :: Lens' (f t a) (Vector 3 t a)
                                 wyx :: Lens' (f t a) (Vector 3 t a)
                                 xwy :: Lens' (f t a) (Vector 3 t a)
                                 xyw :: Lens' (f t a) (Vector 3 t a)
                                 ywx :: Lens' (f t a) (Vector 3 t a)
                                 yxw :: Lens' (f t a) (Vector 3 t a)

                                 wxz :: Lens' (f t a) (Vector 3 t a)
                                 wzx :: Lens' (f t a) (Vector 3 t a)
                                 xwz :: Lens' (f t a) (Vector 3 t a)
                                 xzw :: Lens' (f t a) (Vector 3 t a)
                                 zwx :: Lens' (f t a) (Vector 3 t a)
                                 zxw :: Lens' (f t a) (Vector 3 t a)

                                 wzy :: Lens' (f t a) (Vector 3 t a)
                                 wyz :: Lens' (f t a) (Vector 3 t a)
                                 zwy :: Lens' (f t a) (Vector 3 t a)
                                 zyw :: Lens' (f t a) (Vector 3 t a)
                                 ywz :: Lens' (f t a) (Vector 3 t a)
                                 yzw :: Lens' (f t a) (Vector 3 t a)

                                 xyzw :: Lens' (f t a) (Vector 4 t a)
                                 xzyw :: Lens' (f t a) (Vector 4 t a)
                                 yxzw :: Lens' (f t a) (Vector 4 t a)
                                 yzxw :: Lens' (f t a) (Vector 4 t a)
                                 zxyw :: Lens' (f t a) (Vector 4 t a)
                                 zyxw :: Lens' (f t a) (Vector 4 t a)

                                 xywz :: Lens' (f t a) (Vector 4 t a)
                                 xzwy :: Lens' (f t a) (Vector 4 t a)
                                 yxwz :: Lens' (f t a) (Vector 4 t a)
                                 yzwx :: Lens' (f t a) (Vector 4 t a)
                                 zxwy :: Lens' (f t a) (Vector 4 t a)
                                 zywx :: Lens' (f t a) (Vector 4 t a)

                                 xwyz :: Lens' (f t a) (Vector 4 t a)
                                 xwzy :: Lens' (f t a) (Vector 4 t a)
                                 ywxz :: Lens' (f t a) (Vector 4 t a)
                                 ywzx :: Lens' (f t a) (Vector 4 t a)
                                 zwxy :: Lens' (f t a) (Vector 4 t a)
                                 zwyx :: Lens' (f t a) (Vector 4 t a)

                                 wxyz :: Lens' (f t a) (Vector 4 t a)
                                 wxzy :: Lens' (f t a) (Vector 4 t a)
                                 wyxz :: Lens' (f t a) (Vector 4 t a)
                                 wyzx :: Lens' (f t a) (Vector 4 t a)
                                 wzxy :: Lens' (f t a) (Vector 4 t a)
                                 wzyx :: Lens' (f t a) (Vector 4 t a)


------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------


-- ~~~ Boxed Array ~~~

type B_Array sh = Array sh Boxed
newtype instance Array sh Boxed a = B_Array (V.Vector a) deriving (Show, Functor, Foldable, Traversable)

instance Rewrapped (Array sh Boxed a) (Array sh' Boxed a')
instance Wrapped   (Array sh Boxed a) where
    type Unwrapped (Array sh Boxed a) = (V.Vector a)
    _Wrapped' = iso (\(B_Array a) -> a) B_Array

instance Reshape nsh (Array sh) Boxed where unsafeReshape _ (B_Array a) = B_Array a 

instance IsList' (Array sh Boxed a) where
    fromList' = view unwrapped . fromList
    toList'   = toList . view wrapped


instance UnsafeIndex (Array sh) Boxed where
    unsafeIndex idx = flip V.unsafeIndex idx . view wrapped


-- TODO[WD]: make it more general, suitable for processing arbitrary dimension arrays
instance KnownNats '[w, h] => ExtractDim 0 [w,h] Boxed where
    extractDim _ a = fromList $ flip fmap [0 .. w - 1] $ \col -> B_Array $ V.generate h $ \row -> V.unsafeIndex v (row * w + col) where
        [w,h] = shapeOf a
        v     = a ^. wrapped

instance KnownNats '[w, h] => ExtractDim 1 [w,h] Boxed where
    extractDim _ a = fromList $ flip fmap [0 .. h - 1] $ \row -> B_Array $ V.generate w $ \col -> V.unsafeIndex v (row * w + col) where
        [w,h] = shapeOf a
        v     = a ^. wrapped






--cols m@(Matrix a) = flip fmap [0 .. width m - 1] $ \c -> Vec . Matrix $ V.generate (height m) $ \r -> V.unsafeIndex a (r * width m + c)

instance KnownNats sh => Generate sh Boxed where
    generateArray f = B_Array $ flip evalState ixes $ V.generateM size $ \i -> f i <$> getIx where
        shape = natLstVal (Proxy :: Proxy sh) :: [Int]
        size  = product shape
        ixes  = multiRange $ fmap pred shape
        getIx = do
            (i:is) <- get
            put is
            return i



---

prettyPrint a = mapM_ print $ chunksOf w $ toList a where
    [w,h] = shapeOf a


---






type family ProductOf a b
type HomoProductOf a = ProductOf a a

infixl 7 *
class Mul a b where (*) :: a -> b -> ProductOf a b
                    default (*) :: (Num a, a ~ b, a ~ HomoProductOf a) => a -> b -> ProductOf a b
                    (*) = (P.*) 


type family SumOf a b
type HomoSumOf a = SumOf a a

infixl 7 +
class Add a b where (+) :: a -> b -> SumOf a b
                    default (+) :: (Num a, a ~ b, a ~ HomoSumOf a) => a -> b -> SumOf a b
                    (+) = (P.+) 

sum :: (Foldable t, Add a a, SumOf a a ~ a, Num a) => t a -> a
sum = foldl (+) 0

type instance ProductOf Int Int = Int
instance      Mul       Int Int

type instance ProductOf Float Float = Float
instance      Mul       Float Float

type instance ProductOf Double Double = Double
instance      Mul       Double Double

---

type instance SumOf Int Int = Int
instance      Add   Int Int

type instance SumOf Float Float = Float
instance      Add   Float Float

type instance SumOf Double Double = Double
instance      Add   Double Double

--instance {-# OVERLAPPABLE #-} (Num a, a ~ b, a ~ HomoProductOf a) => Mul a b where (*) = (P.*)  




--instance (sh ~ sh', t ~ t', Mul a b, IsList (Array sh t a), IsList (Array sh t b), IsList (Array sh t (ProductOf a b)))
--      => Mul (Array sh t a) (Array sh' t' b) where
--    a * b = fromList $ (uncurry (*) <$> zip (toList a) (toList b))


main = do 
    --let m = fmap getSum (mempty :: Matrix 4 4 Boxed (Sum Float))
    let 
        m = generate (\[x,y] -> (x,y)) :: Array '[3,4] Boxed (Int, Int)
        --m = fmap getSum (mempty :: Quaternion Boxed (Sum Int))
        --m = diagonal 1 0 :: Quaternion Boxed Int
        --m = mempty :: Quaternion Boxed Int
        --v = fmap getSum (mempty :: Vector 2 Boxed (Sum Int))

        --m1 = diagonal 1 0 :: Matrix 4 4 Boxed Int
        m1 = fromList [1,2,3,4] :: Matrix 2 2 Boxed Int
        m2 = fromList [5,6,7,8] :: Matrix 2 2 Boxed Int
        --m2 = constant 5   :: Matrix 4 4 Boxed Int

        v = fromList [1,2,3] :: Vector 3 Boxed Int --  (mempty :: Vector 2 Boxed (Sum Int))



    print "vvvvvvvvvvvvvv"

    prettyPrint $ m1
    print ""
    prettyPrint $ m2
    print ""
    prettyPrint $ m1 * m2


    --mapM_ print $ toList $ rows m
    --print ""

    --mapM_ print $ toList $ cols m

    --prettyPrint m

    print "^^^^^^^^^^^^^"



    let lst = [4,3,5]
        lstf = fmap (\a -> [0..a]) lst

        l1 = [0..5]
        l2 = [[]]

        --lx = mconcat $ flip fmap l1 $ \i -> flip fmap l2 $ \l2i -> flip fmap l2i $ \j -> [i,j]
        --lx acc range = mconcat $ flip fmap range $ flip fmap acc . (:)
        

    print $ multiRange [3,2,5]
    --print $ (,,) <$> [0..4] <*> [0..3] <*> [0..5] 

    --let m = fromList [1,2,3,4,5,6,7,8] :: Matrix 4 2 Float
    --    m2 = diagonal 1 :: Matrix 4 4 Float

    --print m2

    --mapM print $ rows m2
    --mapM print $ cols m2
    --mapM print $ rows m

    --print "---"

    --mapM print $ rows $ transpose m

    print $ (2 :: Int) * (8 :: Int)
    print "end"

multiRange = foldl lx [[]] . fmap (\a -> [0..a]) . reverse where
    lx acc range = mconcat $ flip fmap acc $ flip fmap range . flip (:)






--instance IsArray (Matrix t w h)  where array = id

--newtype Matrix (width :: Nat) (height :: Nat) a = Matrix { fromMatrix :: V.Vector a } deriving (Show, Eq, Functor)

--newtype Vec dim a = Vec {fromVec :: Matrix dim 1 a} deriving (Show, Eq, Functor) 

--encode :: Int -> (Int,Int) -> Int
--encode m (i,j) = (i-1) * m + j - 1
--{-# INLINE encode #-}

--decode :: Int -> Int -> (Int,Int)
--decode m k = over each (+1) $ quotRem k m
--{-# INLINE decode #-}



--instance IsList (Matrix w h a) where
--    type Item (Matrix w h a) = a
--    fromList = Matrix . V.fromList

--width :: forall w h a. KnownNat w => Matrix w h a -> Int
--width _ = unsafeConvert $ natVal (Proxy :: Proxy w)

--height :: forall w h a. KnownNat h => Matrix w h a -> Int
--height _ = unsafeConvert $ natVal (Proxy :: Proxy h)


--rows :: (KnownNat w, KnownNat h) => Matrix w h a -> [Vec w a]
--rows m@(Matrix a) = flip fmap [0 .. height m - 1] $ \r -> Vec . Matrix $ V.slice (r * width m) (width m) a

--cols :: (KnownNat w, KnownNat h) => Matrix w h a -> [Vec h a]
--cols m@(Matrix a) = flip fmap [0 .. width  m - 1] $ \c -> Vec . Matrix $ V.generate (height m) $ \r -> V.unsafeIndex a (r * width m + c)

--fromRowsUnsafe :: [Vec w a] -> Matrix w h a
--fromRowsUnsafe = Matrix . V.concat . fmap (fromMatrix . fromVec)

--fromRows :: KnownNat h => [Vec w a] -> Matrix w h a
--fromRows vs = if (height mx > length vs) then error "Dimensions mismatch." else mx where
--    mx = fromRowsUnsafe vs

--transpose :: (KnownNat w, KnownNat h) => Matrix w h a -> Matrix h w a
--transpose = fromRowsUnsafe . cols

---- | /O(rows)/. Get a column of a matrix as a vector.
---- getCol :: Int -> Matrix a -> V.Vector a
---- {-# INLINE getCol #-}
---- getCol j (M n _ ro co w v) = V.generate n $ \i -> v V.! encode w (i+1+ro,j+co)

----diagonal :: forall w h a. (Num a, KnownNat r, KnownNat c)
----         => a -> Matrix w h a
----diagonal a = Matrix $ fromListVector (Z :. width :. height) $ take (width * height) $ cycle pattern where
----    width    = unsafeConvert $ natVal (Proxy :: Proxy r) :: Int
----    height    = unsafeConvert $ natVal (Proxy :: Proxy c) :: Int
----    pattern = a : replicate height 0



--diagonal :: (Num a, KnownNat w, KnownNat h) => a -> Matrix w h a
--diagonal a = mx where
--    mx      = Matrix $ V.fromList $ take (mwidth * mheight) $ cycle pattern
--    pattern = a : replicate mheight 0
--    mheight   = height mx
--    mwidth   = width mx



