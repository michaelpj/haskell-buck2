-- | The version of the request and of what the worker writes back, which
-- the rules name in each request (_WORKER_CONTRACT in compile.bzl): a
-- worker installed for another version of the rules says so rather than
-- misreading the request.
module Contract (contract) where

contract :: String
contract = "1"
