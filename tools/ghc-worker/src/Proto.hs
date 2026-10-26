-- | The protobuf messages of buck2's worker protocol (worker.proto), by hand:
-- the two messages used are small enough that a protobuf library isn't worth
-- a dependency. Wire format: a varint key (field number << 3 | wire type),
-- then a varint (type 0) or a length-prefixed byte string (type 2).
module Proto (ExecuteCommand (..), decodeExecuteCommand, encodeExecuteResponse, encodeExecuteCommand, decodeExecuteResponse) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word64, Word8)

data ExecuteCommand = ExecuteCommand
  { ecArgv :: [ByteString]
  , ecEnv :: [(ByteString, ByteString)]
  }

-- Each field: (number, wire type, payload); varints are returned as the
-- number in 'Left', byte strings in 'Right'.
fields :: ByteString -> [(Word64, Either Word64 ByteString)]
fields bs
  | B.null bs = []
  | otherwise =
      let (key, rest) = varint bs
          num = key `shiftR` 3
       in case key .&. 7 of
            0 -> let (v, rest') = varint rest in (num, Left v) : fields rest'
            2 ->
              let (len, rest') = varint rest
                  (payload, rest'') = B.splitAt (fromIntegral len) rest'
               in (num, Right payload) : fields rest''
            1 -> fields (B.drop 8 rest)
            5 -> fields (B.drop 4 rest)
            _ -> []

varint :: ByteString -> (Word64, ByteString)
varint = go 0 0
  where
    go acc shift bs = case B.uncons bs of
      Nothing -> (acc, B.empty)
      Just (b, rest) ->
        let acc' = acc .|. (fromIntegral (b .&. 0x7f) `shiftL` shift)
         in if b .&. 0x80 == 0 then (acc', rest) else go acc' (shift + 7) rest

decodeExecuteCommand :: ByteString -> ExecuteCommand
decodeExecuteCommand bs =
  ExecuteCommand
    { ecArgv = [a | (1, Right a) <- fs]
    , ecEnv = [entry e | (2, Right e) <- fs]
    }
  where
    fs = fields bs
    entry e =
      let efs = fields e
       in (B.concat (take 1 [k | (1, Right k) <- efs]), B.concat (take 1 [v | (2, Right v) <- efs]))

-- ExecuteResponse: exit_code (1, varint), stderr (2, string).
encodeExecuteResponse :: Int -> ByteString -> ByteString
encodeExecuteResponse code err =
  BL.toStrict . BB.toLazyByteString $
    putVarint 8 <> putVarint (fromIntegral (fromIntegral code :: Word64))
      <> putVarint 18 <> putVarint (fromIntegral (B.length err)) <> BB.byteString err

putVarint :: Word64 -> BB.Builder
putVarint n
  | n < 0x80 = BB.word8 (fromIntegral n)
  | otherwise = BB.word8 (fromIntegral (n .&. 0x7f) .|. 0x80 :: Word8) <> putVarint (n `shiftR` 7)

-- | The other direction of each message, for a client of the worker (the
-- test suite): an ExecuteCommand with the argv, and the exit code and
-- stderr of an ExecuteResponse.
encodeExecuteCommand :: [ByteString] -> ByteString
encodeExecuteCommand argv =
  BL.toStrict . BB.toLazyByteString . mconcat $
    [putVarint 10 <> putVarint (fromIntegral (B.length a)) <> BB.byteString a | a <- argv]

decodeExecuteResponse :: ByteString -> (Int, ByteString)
decodeExecuteResponse bs = (fromIntegral code, B.concat (take 1 [e | (2, Right e) <- fs]))
  where
    fs = fields bs
    code = case [c | (1, Left c) <- fs] of
      c : _ -> c
      [] -> 0
