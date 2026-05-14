# Lease-based distributed job

A long-running import grabs a Redis lease, runs under a deadline equal
to the lease TTL minus a small safety margin, and releases the lease
atomically on exit. If the worker dies, the lease expires and another
worker picks the job up.

```ruby
require "redis"
require "securerandom"
require "timex"

class Lease

  RELEASE_LUA = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  LUA

  def self.acquire(key, ttl:, redis: Redis.new, margin: 1.0)
    token = SecureRandom.hex(8)
    raise "lease busy: #{key}" unless redis.set(key, token, nx: true, ex: ttl.to_i)

    deadline = TIMEx::Deadline.in(ttl - margin)
    yield deadline
  ensure
    redis&.eval(RELEASE_LUA, keys: [key], argv: [token]) if token
  end

end

Lease.acquire("import:42", ttl: 30) do |deadline|
  TIMEx.deadline(deadline) do |d|
    Importer.run(id: 42, deadline: d)
  end
end
```

The `margin` keeps `TIMEx::Expired` from firing *after* Redis has
already let the lease lapse — that gap is where two workers would
process the same job concurrently. The Lua `compare-and-delete` makes
sure a worker that overran the lease never deletes a successor's
token.

See [Deadline](../docs/basics/deadline.md).
