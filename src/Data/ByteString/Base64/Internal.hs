{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Data.ByteString.Base64.Internal
( -- * Base64 encoding
  encodeB64Padded
, encodeB64Unpadded

  -- * Base64 decoding
, decodeB64

  -- * Decoding Tables
  -- ** Standard
, decodeB64Table
  -- ** Base64-url
, decodeB64UrlTable

  -- * Encoding Tables
  -- ** Standard
, base64Table

  -- ** Base64-url
, base64UrlTable
) where


import Data.Bits
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Internal
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.ForeignPtr
import Foreign.Ptr
import Foreign.Storable

import GHC.Exts
import GHC.ForeignPtr
import GHC.Word

import System.IO.Unsafe

-- -------------------------------------------------------------------------- --
-- Internal data

-- | Only the lookup table need be a foreignptr,
-- and then, only so that we can automate some touches to keep it alive
--
data T2 = T2
  {-# UNPACK #-} !(Ptr Word8)
  {-# UNPACK #-} !(ForeignPtr Word16)

packTable :: Addr# -> T2
packTable alphabet = etable
  where
    ix (I# n) = W8# (indexWord8OffAddr# alphabet n)
    {-# INLINE ix #-}

    !etable = unsafeDupablePerformIO $ do

      -- Bytestring pack without the intermediate wrapper.
      -- TODO: factor out as CString
      --
      let bs = concat
            [ [ ix i, ix j ]
            | !i <- [0..63]
            , !j <- [0..63]
            ]

          go !_ [] = return ()
          go !p (a:as) = poke p a >> go (plusPtr p 1) as
          {-# INLINE go #-}

      !efp <- mallocPlainForeignPtrBytes 8192
      withForeignPtr efp $ \p -> go p bs
      return (T2 (Ptr alphabet) (castForeignPtr efp))
{-# INLINE packTable #-}

base64UrlTable :: T2
base64UrlTable = packTable "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"#
{-# NOINLINE base64UrlTable #-}

base64Table :: T2
base64Table = packTable "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"#
{-# NOINLINE base64Table #-}


-- -------------------------------------------------------------------------- --
-- Unpadded Base64

encodeB64Unpadded :: T2 -> ByteString -> ByteString
encodeB64Unpadded (T2 _ !efp) (PS sfp !soff !slen) =
    unsafeCreate dlen $ \dptr ->
    withForeignPtr sfp $ \sptr ->
    withForeignPtr efp $ \eptr ->
      encodeB64UnpaddedInternal
        eptr
        (plusPtr sptr soff)
        (castPtr dptr)
        (plusPtr sptr (soff + slen))
  where
    dlen :: Int
    !dlen = 4 * ((slen + 2) `div` 3)
{-# INLINE encodeB64Unpadded #-}

-- | Unpadded Base64. The implicit assumption is that the input
-- data has a length that is a multiple of 3
--
encodeB64UnpaddedInternal
    :: Ptr Word16
    -> Ptr Word8
    -> Ptr Word16
    -> Ptr Word8
    -> IO ()
encodeB64UnpaddedInternal etable sptr dptr end = go sptr dptr
  where
    w32 :: Word8 -> Word32
    w32 i = fromIntegral i
    {-# INLINE w32 #-}

    go !src !dst
      | src >= end = return ()
      | otherwise = do

        !i <- w32 <$> peek src
        !j <- w32 <$> peek (plusPtr src 1)
        !k <- w32 <$> peek (plusPtr src 2)

        let !w = (shiftL i 16) .|. (shiftL j 8) .|. k

        !x <- peekElemOff etable (fromIntegral (shiftR w 12))
        !y <- peekElemOff etable (fromIntegral (w .&. 0xfff))

        poke dst x
        poke (plusPtr dst 2) y

        go (plusPtr src 3) (plusPtr dst 4)
{-# INLINE encodeB64UnpaddedInternal #-}

-- -------------------------------------------------------------------------- --
-- Padded Base64

encodeB64Padded :: T2 -> ByteString -> ByteString
encodeB64Padded (T2 !aptr !efp) (PS !sfp !soff !slen) =
    unsafeCreate dlen $ \dptr ->
    withForeignPtr sfp $ \sptr ->
    withForeignPtr efp $ \eptr ->
      encodeB64PaddedInternal
        aptr
        eptr
        (plusPtr sptr soff)
        (castPtr dptr)
        (plusPtr sptr (soff + slen))
  where
    dlen :: Int
    !dlen = 4 * ((slen + 2) `div` 3)
{-# INLINE encodeB64Padded #-}

encodeB64PaddedInternal
    :: Ptr Word8
    -> Ptr Word16
    -> Ptr Word8
    -> Ptr Word16
    -> Ptr Word8
    -> IO ()
encodeB64PaddedInternal (Ptr !alpha) !etable !sptr !dptr !end = go sptr dptr
  where
    ix (W8# i) = W8# (indexWord8OffAddr# alpha (word2Int# i))
    {-# INLINE ix #-}

    w32 :: Word8 -> Word32
    w32 = fromIntegral
    {-# INLINE w32 #-}

    go !src !dst
      | plusPtr src 2 >= end = finalize src (castPtr dst)
      | otherwise = do

        -- ideally, we want to do single read @uint32_t w = src[0..3]@ and simply
        -- discard the upper bits. TODO.
        --
        !i <- w32 <$> peek src
        !j <- w32 <$> peek (plusPtr src 1)
        !k <- w32 <$> peek (plusPtr src 2)

        -- pack 3 'Word8's into a the first 24 bits of a 'Word32'
        --
        let !w = (shiftL i 16) .|. (shiftL j 8) .|. k

        -- ideally, we'd want to pack this is in a single read, then
        -- a single write
        --
        !x <- peekElemOff etable (fromIntegral (shiftR w 12))
        !y <- peekElemOff etable (fromIntegral (w .&. 0xfff))

        poke dst x
        poke (plusPtr dst 2) y

        go (plusPtr src 3) (plusPtr dst 4)


    finalize :: Ptr Word8 -> Ptr Word8 -> IO ()
    finalize !src !dst
      | src == end = return ()
      | otherwise = do
        !k <- peekByteOff src 0

        let !a = shiftR (k .&. 0xfc) 2
            !b = shiftL (k .&. 0x03) 4

        pokeByteOff dst 0 (ix a)

        if plusPtr src 2 == end
        then do
          !k' <- peekByteOff src 1

          let !b' = shiftR (k' .&. 0xf0) 4 .|. b
              !c' = shiftL (k' .&. 0x0f) 2

          -- ideally, we'd want to pack these is in a single write
          --
          pokeByteOff dst 1 (ix b')
          pokeByteOff dst 2 (ix c')
        else do
          pokeByteOff dst 1 (ix b)
          pokeByteOff @Word8 dst 2 0x3d

        pokeByteOff @Word8 dst 3 0x3d
{-# INLINE encodeB64PaddedInternal #-}

-- -------------------------------------------------------------------------- --
-- Decoding Base64

-- | Non-URLsafe b64 decoding table (naive)
--
decodeB64Table :: ForeignPtr Word8
decodeB64Table = dtfp
  where
    PS !dtfp _ _ = BS.pack
      [ 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x3e,0xff,0xff,0xff,0x3f
      , 0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x3b,0x3c,0x3d,0xff,0xff,0xff,0x63,0xff,0xff
      , 0xff,0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e
      , 0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0xff,0xff,0xff,0xff,0xff
      , 0xff,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28
      , 0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,0x30,0x31,0x32,0x33,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      ]
{-# NOINLINE decodeB64Table #-}

decodeB64UrlTable :: ForeignPtr Word8
decodeB64UrlTable = dtfp
  where
    PS !dtfp _ _ = BS.pack
      [ 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x3e,0xff,0xff
      , 0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x3b,0x3c,0x3d,0xff,0xff,0xff,0x63,0xff,0xff
      , 0xff,0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e
      , 0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0xff,0xff,0xff,0xff,0x3f
      , 0xff,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28
      , 0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,0x30,0x31,0x32,0x33,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      , 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
      ]
{-# NOINLINE decodeB64UrlTable #-}

decodeB64 :: ForeignPtr Word8 -> ByteString -> Either Text ByteString
decodeB64 !dtfp (PS !sfp !soff !slen)
    | r /= 0 = Left "invalid padding"
    | otherwise = unsafeDupablePerformIO $ do
      !dfp <- mallocPlainForeignPtrBytes dlen
      withForeignPtr dfp $ \dptr ->
        withForeignPtr dtfp $ \dtable ->
        withForeignPtr sfp $ \sptr ->
          decodeB64Internal
            dtable
            (plusPtr sptr soff)
            dptr
            (plusPtr sptr (soff + slen))
            dfp
  where
    (!q, !r) = divMod slen 4
    !dlen = q * 3
{-# INLINE decodeB64 #-}

decodeB64Internal
    :: Ptr Word8
        -- ^ decode lookup table
    -> Ptr Word8
        -- ^ src pointer
    -> Ptr Word8
        -- ^ dst pointer
    -> Ptr Word8
        -- ^ end of src ptr
    -> ForeignPtr Word8
        -- ^ dst foreign ptr (for consing bs)
    -> IO (Either Text ByteString)
decodeB64Internal !dtable !sptr !dptr !end !dfp = go dptr sptr 0
  where
    bail = return . Left . T.pack
    {-# INLINE bail #-}

    finalize !n = return (Right (PS dfp 0 n))
    {-# INLINE finalize #-}

    look :: Ptr Word8 -> IO Word32
    look p = do
      !i <- peekByteOff @Word8 p 0
      !v <- peekByteOff @Word8 dtable (fromIntegral i)
      return (fromIntegral v)
    {-# INLINE look #-}

    go !dst !src !n
      | src >= end = return (Right (PS dfp 0 n))
      | otherwise = do
        !a <- look src
        !b <- look (src `plusPtr` 1)
        !c <- look (src `plusPtr` 2)
        !d <- look (src `plusPtr` 3)

        let !w = (a `shiftL` 18) .|. (b `shiftL` 12) .|.
              (c `shiftL` 6) .|. d

        if a == 0x63 || b == 0x63
        then bail
          $ "invalid padding near offset: "
          ++ show (src `minusPtr` sptr)
        else
          if a .|. b .|. c .|. d == 0xff
          then bail
            $ "invalid base64 encoding near offset: "
            ++ show (src `minusPtr` sptr)
          else do
            poke @Word8 dst (fromIntegral (w `shiftR` 16))
            if c == 0x63
            then finalize (n + 1)
            else do
              poke @Word8 (dst `plusPtr` 1) (fromIntegral (w `shiftR` 8))
              if d == 0x63
              then finalize (n + 2)
              else do
                poke @Word8 (dst `plusPtr` 2) (fromIntegral w)
                go (dst `plusPtr` 3) (src `plusPtr` 4) (n + 3)
{-# INLINE decodeB64Internal #-}
