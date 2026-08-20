We need to cut latency on the /profile endpoint. Two options: cache inside
UpstreamFetcher (all callers benefit, but invalidation is far from the write
path) or cache in the handler layer (close to invalidation, but per-endpoint).
Given the code below, which layer should own the cache, and how should
invalidation work when update_profile runs?
