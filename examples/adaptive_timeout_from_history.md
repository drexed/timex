# Adaptive timeout from history

Fixed timeouts either starve fast tenants or paint slow tenants as
broken. `Adaptive` learns each tenant's real latency and picks a budget
that tightens on good days and relaxes on bad ones.

```ruby
require "concurrent"
require "timex"

SEARCH_HISTORIES = Concurrent::Map.new do |h, tenant_id|
  h[tenant_id] = TIMEx::Composers::Adaptive::InMemoryStore.new(window: 256)
end

def tenant_search(tenant_id:, query:, outer_deadline: 2.0)
  adaptive = TIMEx::Composers::Adaptive.new(
    child:      :cooperative,
    multiplier: 1.5,
    floor_ms:   50,
    ceiling_ms: 2_000,
    history:    SEARCH_HISTORIES[tenant_id]
  )

  adaptive.call(deadline: outer_deadline) do |deadline|
    Search::Client.query(tenant_id, query, deadline: deadline)
  end
rescue TIMEx::Expired
  Search::Result.empty(reason: :timeout)
end
```

Cold start uses the ceiling. After a handful of samples the budget
narrows toward `1.5 × p99(history)`, clamped to floor/ceiling. The
outer `deadline:` is a hard cap — a flapping tenant can't drag the
whole request past the caller's SLA.

For multi-process deployments swap `InMemoryStore` for a Redis-backed
store keyed by tenant. See [Adaptive](../docs/composers/adaptive.md)
for the store contract (`record(ms)` + `estimate_ms`).
