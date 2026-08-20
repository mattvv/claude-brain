Review this Rust utility module for correctness bugs, race conditions, and
error-handling gaps. It runs on a single-vCPU Linux box; the FileLock guards a
JSONL ledger shared between short-lived processes.
