module Yuki.N.AtomicFile
  ( atomicEncodeFile,
    atomicWriteText,
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Functor (($>))
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import System.Directory (createDirectoryIfMissing, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, hFlush, openBinaryTempFile)

atomicEncodeFile :: (ToJSON value) => FilePath -> value -> IO ()
atomicEncodeFile path = atomicWriteLazy path . encode

atomicWriteText :: FilePath -> Text -> IO ()
atomicWriteText path = atomicWriteLazy path . LazyByteString.fromStrict . TextEncoding.encodeUtf8

atomicWriteLazy :: FilePath -> LazyByteString.ByteString -> IO ()
atomicWriteLazy path bytes =
  createDirectoryIfMissing True dir
    *> bracketOnError
      (openBinaryTempFile dir (takeFileName path <> ".tmp"))
      cleanup
      commit
 where
  dir = takeDirectory path
  cleanup (temporary, handle) = ignoringIO (hClose handle) *> ignoringIO (removeFile temporary)
  commit (temporary, handle) =
    LazyByteString.hPutStr handle bytes
      *> hFlush handle
      *> hClose handle
      *> renameFile temporary path

ignoringIO :: IO () -> IO ()
ignoringIO action = (try action :: IO (Either IOException ())) $> ()
