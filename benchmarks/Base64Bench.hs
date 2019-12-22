{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
module Main
( main
) where


import Control.DeepSeq

import Criterion
import Criterion.Main

import "memory" Data.ByteArray.Encoding as Mem
import Data.ByteString
import "base64-bytestring" Data.ByteString.Base64 as Bos
import "base64" Data.ByteString.Base64 as B64
import Data.ByteString.Random (random)
import Data.Text (Text)
import qualified Data.Text.Encoding.Base64 as B64T
import qualified Data.Text.Encoding as T

import GHC.Natural


main :: IO ()
main = defaultMain $ fmap benchN
    [ 25
    , 100
    , 1000
    , 10000
    , 100000
    , 1000000
    ]
  where
    benchN n = env (random n) $ bgroup (show n) . bgroup_
    bgroup_ e =
      [ bgroup "encode"
        [ encodeBench @Mem e
        , encodeBench @Bos e
        , encodeBench @B64 e
        , encodeBench @T64 (T.decodeLatin1 e)
        ]
      , bgroup "base64 decode"
        [ decodeBench @Mem e
        , decodeBench @Bos e
        -- , decodeBench @B64 e
        ]
      ]

encodeBench :: forall a. Harness a => Base64 a -> Benchmark
encodeBench = bench (label @a) . nf (encoder @a)

decodeBench :: forall a. Harness a => Base64 a -> Benchmark
decodeBench = bench (label @a) . nf (decoder @a)


class (NFData (Base64 a), NFData (Err a)) => Harness a where
    type Base64 a
    type Err a
    label :: String
    encoder :: Base64 a -> Base64 a
    decoder :: Base64 a -> Either (Err a) (Base64 a)

data Mem
instance Harness Mem where
    type Base64 Mem = ByteString
    type Err Mem = String
    label = "memory"
    encoder = Mem.convertToBase Mem.Base64
    decoder = Mem.convertFromBase Mem.Base64

data Bos
instance Harness Bos where
    type Base64 Bos = ByteString
    type Err Bos = String
    label = "base64-bytestring"
    encoder = Bos.encode
    decoder = Bos.decode

data B64
instance Harness B64 where
    type Base64 B64 = ByteString
    type Err B64 = Text
    label = "base64"
    encoder = B64.encodeBase64
    decoder = B64.decodeBase64

data T64
instance Harness T64 where
    type Base64 T64 = Text
    type Err T64 = Text
    label = "base64-text"
    encoder = B64T.encodeBase64
    decoder = B64T.decodeBase64