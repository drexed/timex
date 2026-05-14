# Redis with a deadline

`redis-rb` accepts per-operation timeouts. Build the client with the
remaining budget so a slow Redis can't hold a request hostage, and
fall back gracefully when the cache is the non-critical path.

```ruby
require "redis"
require "connection_pool"
require "timex"

REDIS_POOL = ConnectionPool.new(size: 25, timeout: 1) { Redis.new(url: ENV.fetch("REDIS_URL")) }

def cached(key, deadline:)
  remaining = deadline.remaining
  return yield if remaining <= 0 # past budget; skip the cache hop entirely

  REDIS_POOL.with do |redis|
    redis.with_timeout(remaining) do
      cached = redis.get(key)
      return cached if cached

      value = yield
      redis.set(key, value, ex: 60)
      value
    end
  end
rescue Redis::BaseConnectionError, Redis::TimeoutError
  yield # cache is a best-effort dependency, never a blocker
end

TIMEx.deadline(0.250) do |d|
  cached("user:1:profile", deadline: d) { Profile.find(1).to_json }
end
```

For pipelines or multi-key fan-out, derive a tighter per-op deadline
with `Deadline#min` so one slow key can't eat the whole budget:

```ruby
TIMEx.deadline(1.0) do |d|
  [a_key, b_key, c_key].map { |k| cached(k, deadline: d.min(0.2)) { fallback_for(k) } }
end
```

Rescuing both `Redis::TimeoutError` and `Redis::BaseConnectionError`
keeps the call site honest about cache being non-essential — if Redis
is down or slow you serve the canonical answer instead of returning a
500.

See [Deadline](../docs/basics/deadline.md) for `min`.
