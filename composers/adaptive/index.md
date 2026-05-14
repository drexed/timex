# Adaptive

You *could* guess a fixed timeout for every RPC and hope it fits slow days and fast days alike—or you can let **Adaptive** learn from recent runs and pick a budget that stretches when the service is healthy and tightens when it is not.

**Mental model:** a tiny notebook of “how long did the last N calls take?” TIMEx turns that guess into a fresh `Deadline`, runs your nested strategy, then writes down how long reality took so the next call can do better.

## What it does

1. Ask the **history** object for an estimated latency (milliseconds).
1. Multiply, clamp between **floor** and **ceiling**, and build an adaptive deadline from that.
1. If you also pass an outer `deadline:` to `#call`, TIMEx takes the **tighter** of the two—your cap always wins when you need a hard stop.
1. After the child strategy finishes, record the observed duration so the next estimate improves.

**Cold start:** when there is no history yet, the adaptive budget is the **ceiling** (generous first guess). Once samples exist, estimates kick in.

## Quick example

```ruby
adaptive = TIMEx::Composers::Adaptive.new(
  child:      :cooperative,
  multiplier: 1.5,
  floor_ms:   25,
  ceiling_ms: 30_000
)

adaptive.call { rpc.call }
```

## Knobs (the ones you will actually touch)

| Knob          | Plain English                                                                                  |
| ------------- | ---------------------------------------------------------------------------------------------- |
| `child:`      | The real strategy that runs your block—usually `:cooperative` or whatever you already trust.   |
| `multiplier:` | Headroom on top of the estimate (1.5× means “give it half again as long as the model thinks”). |
| `floor_ms:`   | Never go shorter than this—protects you from absurdly tiny budgets when samples look instant.  |
| `ceiling_ms:` | Never go longer than this—and also the first-run budget before any samples exist.              |
| `history:`    | Optional store; defaults to an in-memory sliding window (see below).                           |

## Default history (in memory)

Out of the box, **`InMemoryStore`** implements a streaming **P² quantile estimator** (~p99 by default), blends in an **EWMA** safety margin, and publishes a lock-free **`estimate_ms`** after each **`record`**. Tune **`window:`** (how many samples before marker reset) and **`alpha:`** (EWMA smoothing).

If you need Redis, Postgres, or another shared store so every process agrees on latency, plug in your own object.

## Custom history store

Your store only needs two methods:

- **`record(ms)`** — called after each run with observed latency in milliseconds.
- **`estimate_ms`** — returns a single number in milliseconds, or **`nil`** if you have no opinion yet (Adaptive will use the ceiling until data shows up).

```ruby
class RedisHistory
  def initialize(client, key:, window:)
    @c, @k, @w = client, key, window
  end

  def record(ms)
    @c.lpush(@k, ms)
    @c.ltrim(@k, 0, @w - 1)
  end

  def estimate_ms
    samples = @c.lrange(@k, 0, -1).map(&:to_f).sort
    return nil if samples.empty?

    samples[((samples.size - 1) * 0.99).round]
  end
end

TIMEx::Composers::Adaptive.new(child: :cooperative, history: RedisHistory.new(...))
```

## Telemetry

Adaptive emits **`composer.adaptive`** with `estimate_ms`, `budget_ms`, `deadline_ms` (post-clamp), `elapsed_ms`, and `outcome`. Pair with a logger or OTel adapter and you get a clean record of how the budget shrank or grew over time. See [Telemetry](https://drexed.github.io/timex/telemetry/index.md).

## Real-world: per-tenant Elasticsearch search

Tenant A’s `search` index lives in a few hundred docs and returns in 30 ms. Tenant B is a 50-million-doc beast that needs 1.5 s on a good day. A fixed timeout either starves A or paints B as “broken.” Keying the history store by tenant lets Adaptive learn one budget per tenant from real traffic:

```ruby
SEARCH_HISTORIES = Concurrent::Map.new { |h, k| h[k] = TIMEx::Composers::Adaptive::InMemoryStore.new }

def tenant_search(tenant_id:, query:, outer_deadline:)
  adaptive = TIMEx::Composers::Adaptive.new(
    child:      :cooperative,
    multiplier: 1.5,
    floor_ms:   50,
    ceiling_ms: 2_000,
    history:    SEARCH_HISTORIES[tenant_id]
  )
  adaptive.call(deadline: outer_deadline) { Search::Client.query(tenant_id, query) }
end
```

Quiet tenants get tight budgets that fail fast when something is wrong; loud tenants get the headroom they actually need—no per-tenant config file to keep in sync with reality.
