This nightly cron sequentially re-encodes every uploaded video from the last
24h; runs now take 9+ hours and overlap the next trigger. Should we move to a
work queue (Redis/RQ is already in the stack) or shard the cron? Constraints: a
single 4-vCPU worker box today, occasional 10x upload spikes, and re-encoding
the same video twice is wasteful but harmless.
