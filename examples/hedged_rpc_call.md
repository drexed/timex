# Hedged RPC call

Tail latency on an idempotent read replica is best handled by racing a
second copy of the same request after a small delay and keeping the
first answer.

```ruby
require "timex"

PROFILE_HEDGED = TIMEx::Composers::Hedged.new(
  after:      0.050, # fire a backup if attempt 1 is still pending at 50ms
  max:        2,     # one primary + one hedge, no stampedes
  child:      :cooperative,
  idempotent: true   # GET /profiles/:id is a pure read
).freeze

def fetch_profile(id, deadline: 0.5)
  PROFILE_HEDGED.call(deadline: deadline) do |d|
    replica = ProfileReplicas.pick # round-robin between regions
    replica.get("/profiles/#{id}", deadline: d)
  end
rescue TIMEx::Expired
  ProfileCache.last_known(id) # graceful degradation
end
```

`max: 2` doubles peak load on the read path in the worst case, which
is the explicit trade you accept for cutting p99. Hedging is only safe
when the downstream really is idempotent — duplicate `POST /charges`
would be a bad day. The composer raises at construction time if you
omit `idempotent: true`, which is on purpose.

See [Hedged](../docs/composers/hedged.md).
