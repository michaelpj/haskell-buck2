-- | buck2 persistent worker for per-module Haskell compilation. See the
-- cabal file's description and Session.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (catch, throwIO)
import Control.Monad (forever, void)
import qualified Data.ByteString.Char8 as B8
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStr, stderr)
import System.Posix.Process (executeFile, exitImmediately)

import GHC.Utils.Panic (GhcException (..))
import Grpc (serve)
import Session

main :: IO ()
main = do
  args <- getArgs
  socket <- lookupEnv "WORKER_SOCKET"
  case socket of
    Nothing -> oneShot args
    Just path -> persistent path

-- Without buck2's socket: compile the one request on the command line, as
-- a plain action would (the rules use the worker as the action's fallback).
-- A Template Haskell module's dependencies are found through
-- LD_LIBRARY_PATH, which the dynamic linker reads at the start of the
-- process: so start over with it set.
oneShot :: [String] -> IO ()
oneShot args = case parseRequest args of
  Left err -> hPutStr stderr (err ++ "\n") >> exitWith (ExitFailure 2)
  Right req -> do
    ldPath <- lookupEnv "LD_LIBRARY_PATH"
    case reqLdTree req of
      Just tree | ldPath /= Just tree -> do
        self <- getExecutablePath
        env <- getEnvironment
        executeFile self False args (Just (("LD_LIBRARY_PATH", tree) : filter ((/= "LD_LIBRARY_PATH") . fst) env))
      _ -> do
        (code, err) <- startWorker req (\p -> compileRequest p req)
        hPutStr stderr err
        exitWith (if code == 0 then ExitSuccess else ExitFailure code)

-- The session starts with the first request (its compiler, its flags), and
-- then each request is compiled by the thread that received it.
persistent :: FilePath -> IO ()
persistent path = do
  first <- newEmptyMVar
  worker <- newEmptyMVar
  void . forkIO $ serve path $ \argv -> case parseRequest (map B8.unpack argv) of
    Left err -> pure (2, B8.pack (err ++ "\n"))
    Right req -> do
      _ <- tryPutMVar first req
      w <- readMVar worker
      (code, err) <- compileRequest w req
      pure (code, B8.pack err)
  req <- takeMVar first
  -- buck2 ends the worker with SIGTERM when the build is done, which the
  -- GHC session's own signal handler turns into an exception.
  startWorker req (\p -> putMVar worker p >> forever (threadDelay maxBound)) `catch` \e -> case e of
    Signal _ -> exitImmediately ExitSuccess
    _ -> throwIO e
