-- | The worker: its GHC sessions, one per set of session flags, and the
-- compile of each request in its session. See Note [How the worker works].
module Worker (Worker, withWorker, compileRequest, shutdown) where

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar
import Control.Exception (SomeAsyncException, SomeException, finally, fromException, mask, mask_, throwIO, try, uninterruptibleMask_)
import Control.Monad (when)
import Data.IORef
import Data.List (partition, sortOn)
import qualified Data.Map as M
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Version (showVersion)
import Foreign.C.Types (CInt (..))
import System.Environment (lookupEnv)
import System.Info (fullCompilerVersion)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcess)
import Text.Read (readMaybe)

import GHC (getSession, runGhc)
import GHC.Driver.Env (hsc_NC)
import GHC.Types.Name.Cache (NameCache)
import GHC.Clock (getMonotonicTime)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import GHC.Types.SourceError (SourceError)
import GHC.Unit.Finder.Types (FinderCache)
import Control.Monad.IO.Class (liftIO)

import Compat (sharedFileHashes)
import Request
import Session

-- | The worker's sessions, one per set of session flags (see Note [How the
-- worker works]). A session is made when the first request with its flags
-- comes, and keeps the interfaces it has read until it is dropped (see Note
-- [Dropping the idle sessions]).
data Worker = Worker
  { wCompiler :: String -- the GHC the requests name, the worker's own
  , wLibdir :: FilePath
  , wSessions :: MVar (M.Map [String] Entry)
  , wMaxSessions :: Int -- the sessions kept, in use or idle
  , wCompiled :: MVar (M.Map FilePath (Set.Set Node)) -- per target's output directory, the modules compiled, until all are
  , wVerbose :: Bool
  , wFiles :: FinderCache -- whose file hashes the sessions share: see Note [Hashing the libraries] in Session
  , wNames :: NameCache -- which the sessions share: see Note [One name cache for all the sessions] in Session
  , wShared :: Shared -- what else the sessions share
  , wMode :: SessionMode -- how the sessions compile (GHC_WORKER_SESSION_MODE)
  }

-- | A session, made or being made (or that failed to be made), and its
-- use.
data Entry = Entry
  { eSession :: MVar (Either SomeException GhcSession)
  , eInFlight :: Int -- requests using it
  , eLastDone :: Double -- when its last compile finished
  , eFinished :: Bool -- whether its target's modules are all compiled
  }

-- | Run the worker with the GHC of the first request, which must be the one
-- it was built with. No compile uses the session `runGhc` makes: it is
-- there for GHC's signal handlers, which turn buck2's SIGTERM into a
-- 'Signal' exception (see Main), and for its name cache, which the
-- sessions share (see Note [One name cache for all the sessions] in
-- Session). The sessions that compile are made on demand.
withWorker :: Request -> (Worker -> IO a) -> IO a
withWorker first k = do
  version <- trim <$> readProcess (reqCompiler first) ["--numeric-version"] ""
  let built = showVersion fullCompilerVersion
  when (version /= built) $
    fail ("ghc-worker: built with GHC " ++ built ++ ", but the rules' GHC (" ++ reqCompiler first ++ ") is " ++ version ++ ": install the worker with the project's GHC")
  libdir <- trim <$> readProcess (reqCompiler first) ["--print-libdir"] ""
  sessions <- newMVar M.empty
  verbose <- isJust <$> lookupEnv "GHC_WORKER_VERBOSE"
  maxSessions <- maybe getNumCapabilities pure . (>>= readMaybe) =<< lookupEnv "GHC_WORKER_SESSIONS"
  compiled <- newMVar M.empty
  files <- sharedFileHashes
  shared <- newShared
  mode <- lookupEnv "GHC_WORKER_SESSION_MODE" >>= \m -> case m of
    Nothing -> pure AutoSessions
    Just "auto" -> pure AutoSessions
    Just "make" -> pure MakeSessions
    Just "one-shot" -> pure OneShotSessions
    Just other -> fail ("ghc-worker: GHC_WORKER_SESSION_MODE is " ++ other ++ ", not auto, make or one-shot")
  -- See Note [Starting the object linker once].
  initLinker 1
  runGhc (Just libdir) $ do
    names <- hsc_NC <$> getSession
    liftIO (k (Worker (reqCompiler first) libdir sessions maxSessions compiled verbose files names shared mode))
  where
    trim = reverse . dropWhile (`elem` "\r\n") . reverse

-- | GHC's object linker, started (with its CAFs kept, as GHC's interpreter
-- starts it).
foreign import ccall unsafe "initLinker_" initLinker :: CInt -> IO ()

-- | Drop the idle sessions of finished targets, and the least recently
-- used of the other idle sessions while there are more sessions than the
-- worker's `wMaxSessions`, from the map of the sessions; the map left, and
-- those dropped, to be ended. See Note [Dropping the idle sessions].
dropIdle :: Worker -> M.Map [String] Entry -> (M.Map [String] Entry, [Entry])
dropIdle w m = (foldr M.delete m (map fst gone), map snd gone)
  where
    (finished, idle) = partition (eFinished . snd) (sortOn (eLastDone . snd) (M.toList (M.filter ((== 0) . eInFlight) m)))
    gone = finished ++ take (M.size m - length finished - wMaxSessions w) idle

-- | Count a module compiled in a session. Once its target's modules are all
-- compiled, mark the target's sessions finished, to be dropped when idle,
-- and start counting the target's modules again. A target whose analysis
-- failed is never finished.
compiledIn :: Worker -> GhcSession -> Node -> IO ()
compiledIn w s n = mask_ $ do
  let target = gsOutDir s
  finished <- modifyMVar (wCompiled w) $ \m -> do
    let done = Set.insert n (M.findWithDefault Set.empty target m)
    pure $ case gsModules s of
      Just modules | modules `Set.isSubsetOf` done -> (M.delete target m, True)
      _ -> (M.insert target done m, False)
  when finished $ do
    uninterruptibleMask_ $ modifyMVar_ (wSessions w) $ traverse $ \e -> do
      made <- tryReadMVar (eSession e)
      pure $ case made of
        Just (Right s') | gsOutDir s' == target -> e{eFinished = True}
        _ -> e
    when (wVerbose w) $ hPutStrLn stderr ("ghc-worker: " ++ target ++ " finished")

-- | End the sessions dropped, in a thread of their own, so that the request
-- that dropped them is answered without waiting for their external
-- interpreters to stop. (If one can't be ended, its temporary files are
-- left.)
endDropped :: Worker -> Int -> [Entry] -> IO ()
endDropped _ _ [] = pure ()
endDropped w left gone = do
  _ <- forkIO $ mapM_ (\e -> tryNonAsync (endEntry e) >>= either (\err -> hPutStrLn stderr ("ghc-worker: ending a session: " ++ show err)) pure) gone
  -- Not a major GC to reclaim it now: in a worker that loaded libraries for
  -- Template Haskell, every major GC checks each static closure against
  -- them, and a shared worker drops sessions all the time.
  when (wVerbose w) $ hPutStrLn stderr ("ghc-worker: " ++ show (length gone) ++ " idle sessions dropped, " ++ show left ++ " left")

-- | End a session, if it was made.
endEntry :: Entry -> IO ()
endEntry e = tryReadMVar (eSession e) >>= mapM_ (either (const (pure ())) endSession)

-- | End every session, before the worker exits; verbose, log the worker's
-- peak memory, largest live heap, time spent collecting garbage, and CPU
-- time of its mutator and its collections, if the RTS keeps them (+RTS -T).
shutdown :: Worker -> IO ()
shutdown w = do
  readMVar (wSessions w) >>= mapM_ endEntry . M.elems
  enabled <- getRTSStatsEnabled
  when (wVerbose w && enabled) $ do
    stats <- getRTSStats
    hPutStrLn stderr ("ghc-worker: peak memory " ++ show (max_mem_in_use_bytes stats `div` 2 ^ (20 :: Int)) ++ " MB, max live " ++ show (max_live_bytes stats `div` 2 ^ (20 :: Int)) ++ " MB, GC " ++ show (gc_elapsed_ns stats `div` 10 ^ (6 :: Int)) ++ " ms")
    hPutStrLn stderr ("ghc-worker: CPU mutator " ++ show (mutator_cpu_ns stats `div` 10 ^ (6 :: Int)) ++ " ms, GC " ++ show (gc_cpu_ns stats `div` 10 ^ (6 :: Int)) ++ " ms")

-- | Use the session for a request's flags, made if there is none yet. If it
-- can't be made, the request fails with the reason, as do those waiting
-- for it, and the next request with its flags tries again; if the request
-- making it is cancelled, those waiting make it again.
withSession :: Worker -> Request -> (GhcSession -> IO a) -> IO a
withSession w r k = mask $ \restore -> do
  let flags = sessionFlags r
  -- Masked except while the session is made and used: a request cancelled
  -- anywhere else could leave its entry's session unanswered, and those
  -- waiting for it blocked, or its count of requests in flight off, and
  -- the session never dropped.
  (var, fresh) <- modifyMVar (wSessions w) $ \m -> case M.lookup flags m of
    Just e -> pure (M.insert flags e{eInFlight = eInFlight e + 1} m, (eSession e, False))
    Nothing -> do
      v <- newEmptyMVar
      pure (M.insert flags (Entry v 1 0 False) m, (v, True))
  -- The entry this request counted itself in, which a failed session's
  -- request may have removed, and another taken its place. (Uninterruptible
  -- waits for the lock, which is only held briefly.)
  let ours f = M.update (\e -> Just (if eSession e == var then f e else e)) flags
      -- Under the sessions' lock, which a request holds to count itself in
      -- flight: so none is using a session dropped here.
      done = do
        t <- getMonotonicTime
        (left, gone) <- uninterruptibleMask_ $ modifyMVar (wSessions w) $ \m -> do
          let (m', gone) = dropIdle w (ours (\e -> e{eInFlight = eInFlight e - 1, eLastDone = t}) m)
          pure (m', (M.size m', gone))
        endDropped w left gone
  (`finally` done) $ do
    when fresh $ do
      t0 <- getMonotonicTime
      made <- try (restore (newSession (wLibdir w) (wFiles w) (wNames w) (wShared w) (wMode w) r))
      t1 <- getMonotonicTime
      -- A failed entry goes before those waiting see the failure, so that
      -- any that make the session again, and the next request, find none.
      case made of
        Left _ -> uninterruptibleMask_ (modifyMVar_ (wSessions w) (pure . M.filter ((/= var) . eSession)))
        Right _ -> pure ()
      putMVar var made
      when (wVerbose w) $ hPutStrLn stderr ("ghc-worker: a " ++ either (const "") (\s -> if gsOneShot s then "one-shot " else "--make ") made ++ "session for the flags of " ++ reqModPath r ++ " in " ++ show (round ((t1 - t0) * 1000) :: Int) ++ "ms")
      either (\e -> when (isAsync e) (throwIO e)) (const (pure ())) made
    made <- readMVar var
    case made of
      -- The request that was making it was cancelled, which isn't this
      -- one's failure: make the session again.
      Left e | isAsync e, not fresh -> restore (withSession w r k)
      _ -> either throwIO (restore . k) made
  where
    isAsync e = isJust (fromException e :: Maybe SomeAsyncException)

-- | Compile a request's module in the session for its flags; the exit code
-- and the diagnostics of the module.
compileRequest :: Worker -> Request -> IO (Int, String)
compileRequest w r
  | reqCompiler r /= wCompiler w =
      pure (2, "ghc-worker: this worker runs " ++ wCompiler w ++ ", the request names " ++ reqCompiler r ++ "\n")
  | otherwise = do
      diagnostics <- newIORef []
      t0 <- getMonotonicTime
      result <- tryNonAsync (withSession w r (\s -> compile s (\d -> modifyIORef' diagnostics (d :)) r >>= compiledIn w s))
      t1 <- getMonotonicTime
      ds <- reverse <$> readIORef diagnostics
      when (wVerbose w) $ hPutStrLn stderr ("ghc-worker: " ++ reqModPath r ++ " " ++ show (round ((t1 - t0) * 1000) :: Int) ++ "ms")
      let text = map diagText ds
      pure $ case result of
        Right () | not (any diagIsError ds) -> (0, unlines text)
        Right () -> (1, unlines text)
        -- A compile's errors come as the exception (GHC's --make driver
        -- logs them itself, after the compile), as do the driver's in
        -- summarising the source.
        Left e -> case fromException e :: Maybe SourceError of
          Just se -> (1, unlines (text ++ [show se]))
          Nothing -> (1, unlines (text ++ ["ghc-worker: " ++ show e]))

{- Note [How the worker works]

buck2 starts the worker as a persistent worker (see Note [The persistent
worker] in compile.bzl), and sends it each module's compile action as a
request: the action's arguments, over gRPC on a Unix socket. The worker
compiles the requests concurrently, each in the thread that received it,
and answers each with the exit code and the diagnostics. One worker serves
many targets.

Terms

- Request: one module to compile (see Request). When buck2 runs the action
  without the worker, the compile script
  (prelude/haskell/tools/per_module_compile.py) takes the same request.
- Session flags: the flags of a request that the target's modules share.
  Each way a target is built in (static, shared, profiled) has its own, and
  so do its Template Haskell modules, which compile against other package
  dbs (see Note [Libraries of the early package dbs] in compile.bzl).
- Session: a GHC session for one set of session flags, which keeps the
  interfaces it has read. The worker makes one when the first request with
  its flags comes, and drops it when it is no longer needed.
- Home modules: the modules of the session's target. Each compile gets a
  home package table of its own (see Note [Each compile's home modules] in
  Session).
- Boot interface: the interface of a module's .hs-boot file, which
  {-# SOURCE #-} imports see in place of the module.

The modules

- Main: the process, which starts with the first request and ends on
  buck2's SIGTERM, or when buck2 has gone.
- Grpc and Proto: buck2's worker protocol.
- Request: a request's arguments, and the flags of its session.
- Worker: the sessions, and when to drop them (Note [Dropping the idle
  sessions]).
- Session: compiling a request in a session (Note [The session's state],
  and the Notes after it).
- DepFile: the .abi file and dep file the rules need besides GHC's outputs.
- Compat: what differs between the GHC versions the worker builds with.
-}

{- Note [Starting the object linker once]

1. The problem

The runtime has one object linker per process. Each session's interpreter
starts it the first time it runs code, by calling initLinker_. That
function is meant to be safe to call repeatedly, but it records whether it
has already run in a flag that it neither locks nor sets atomically. So if
two sessions ran their first splices at the same time, both would fill the
linker's symbol table, the table's chains would loop, and both compiles
would hang. (GHC's --make never hits this: it has one interpreter, which
starts the linker once.)

2. The solution

The worker starts the linker itself when it starts, before any session can.
-}

{- Note [Dropping the idle sessions]

1. The problem

A --make session keeps every interface it has read: a few hundred MB for
a large package. (A one-shot session keeps little of its own, since the
interfaces it reads go into a state that all one-shot sessions share: see
Note [One-shot sessions] in Session.) buck2 keeps the worker until the end
of the build, and one worker
serves many targets (see Note [The persistent worker] in compile.bzl). If
the worker kept every session, a clean build of a large project would use
more memory than the machine has.

So the worker has to drop sessions. But dropping a session that is still
needed costs time: the next request for it makes it again, which means
analysing the target's sources and reading its imports from disk again.
And sessions are often idle while still needed. buck2 starts each module as
soon as its imports are compiled, so many targets are part-built at once,
each waiting for a slow module of its own or of a dependency, and there are
more of them than compiles running at once (-j).

2. The solution

After each compile, the worker:

  - drops the idle sessions of every finished target (see 3); and
  - while it has more sessions, in use or idle, than its limit, drops the
    least recently used idle session. The limit is GHC_WORKER_SESSIONS,
    which the rules set from the buckconfig, or else the number of
    capabilities.

The count bounds the memory, as cabal's -j does for its ghc --make
processes. Using the number of capabilities scales it with the machine, as
buck2's default -j does. Since buck2's -j bounds the sessions in use, a
count of at least -j never holds a compile back; a count below it lets the
worker drop a session as soon as its compile is done.

3. Finished targets

A target is finished once the worker has compiled every module and boot
interface that GHC's analysis of the target found, in any of its sessions.
A target's sessions are those with its output directory. A target has one
of those for each way it is built in (static, shared, profiled), since each
way is compiled separately, though with the same unit id.

A target that is only built in part never finishes, and its sessions are
dropped by the count alone. That happens when a module is asked for alone,
when a build needs only some of a target's modules, in an incremental
build, when a module fails, and when GHC's analysis of the target fails (a
module whose imports don't parse, say), which leaves nothing to count
against. If a target is asked for again after it has finished, its sessions
are just made again: that costs work, but never compiles anything wrongly.

4. Measurements

On the bench's `project` (bench/Main.hs), where all 30 targets are
part-built at once, at -j8 (GHC_WORKER_SESSIONS=4, 16 and 32, with
`cabal bench --benchmark-options='8 3 project'`):

  limit   one-shot sessions                 --make sessions
           made  wall         peak           made  wall         peak
  4         122  21.8-24.7s   5.2 GB          121  38.0-44.6s   2.4 GB
  16         94  22.2-24.7s   5.2 GB           92  32.9-40.3s   5.2 GB
  32         30  23.1-25.2s   5.2 GB           30  22.5-23.1s   5.2 GB

So with one-shot sessions the limit matters little, and with --make
sessions it trades memory for speed.

5. The alternatives

  - A timeout bounds nothing: with thirty seconds, the worker holds on to
    every target finished in the last half minute.
  - A memory threshold would overshoot: the RTS only knows the live heap
    after a major GC, and a dropped session's memory only comes back at the
    next one.
  - Exiting doesn't work: buck2 keeps the worker it started until the build
    is done, and fails each action sent to it once it has exited, rather
    than starting another.
  - Keeping the sessions with requests to come: the worker can't see them,
    since buck2 sends an action only when it runs it. It could guess from
    the modules of a target whose imports are compiled, but when many
    targets advance in turn, all of them have such a module, and some
    sessions must be dropped all the same.

After a drop, the memory left is the RTS's own: the allocation area, which
the RTS never gives back (hence the small -A in the cabal file), and what
it keeps of the heap's peak.
-}
