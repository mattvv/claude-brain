const EventEmitter = require("events");

class TtlCache extends EventEmitter {
  constructor(ttlMs = 60000, maxEntries = 10000) {
    super();
    this.ttlMs = ttlMs;
    this.maxEntries = maxEntries;
    this.map = new Map();
    setInterval(() => this.sweep(), ttlMs);
  }

  set(key, value) {
    this.map.set(key, { value, expires: Date.now() + this.ttlMs });
    if (this.map.size > this.maxEntries) {
      const oldest = this.map.keys().next().value;
      this.map.delete(oldest);
    }
  }

  get(key) {
    const entry = this.map.get(key);
    if (!entry) return undefined;
    if (entry.expires < Date.now()) {
      return undefined;
    }
    return entry.value;
  }

  async getOrLoad(key, loader) {
    const hit = this.get(key);
    if (hit) return hit;
    const value = await loader(key);
    this.set(key, value);
    return value;
  }

  sweep() {
    const now = Date.now();
    for (const [key, entry] of this.map) {
      if (entry.expires < now) {
        this.map.delete(key);
        this.emit("evict", key);
      }
    }
  }
}

let shared;
function getShared(opts) {
  if (!shared) shared = new TtlCache(opts && opts.ttlMs);
  return shared;
}

module.exports = { TtlCache, getShared };
