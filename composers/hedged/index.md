# Hedged

Tail latency is the ghost that makes dashboards look fine while a few users wait forever. **Hedged** fights back the simple way: start one attempt, wait a beat, fire another copy if nobody answered yet, and let the **first success** win—like hailing two taxis when you are late for a flight.

**Mental model:** parallel duplicate work under one shared deadline. That means extra load on the downstream service and it only makes sense when doing the same call twice (or thrice) is safe.

## What it does

1. Launch attempt **1** under your `deadline:`.
1. If nothing finishes within **`after`** seconds, launch attempt **2**, and so on, up to **`max`** threads.
1. First happy result wins; TIMEx cancels the stragglers.
1. If every attempt times out or blows up, you get the same timeout / error story as any other strategy (controlled by `on_timeout:`).

## Quick example

```ruby
TIMEx::Composers::Hedged.new(
  after: 0.2,
  max: 3,
  child: :cooperative,
  idempotent: true   # required — read below
).call(deadline: 1.0) { rpc.call }
```

**Heads-up:** `max` defaults to **2** if you omit it—enough for one backup, not a stampede.

## Trade-offs (no sugar coating)

| Question                         | Answer                                                                   |
| -------------------------------- | ------------------------------------------------------------------------ |
| Does it hide slow p99 tails?     | Usually yes—that is the point.                                           |
| Worst-case extra traffic         | Up to **`max`** copies of the same call in flight at once.               |
| Safe for “charge my card” POSTs? | Only if the server is truly idempotent—otherwise you might charge twice. |

## Why `idempotent: true` is mandatory

Hedged literally runs your block in more than one thread. If the block is not safe to repeat—think “insert row,” “send email,” “decrement inventory”—you will feel that in production.

TIMEx **refuses** to build a `Hedged` composer unless you pass `idempotent: true`. That is not bureaucracy; it is a bright yellow sticker that says *I know duplicate executions are OK here.*

## Real-world: read from the fastest replica

Read-heavy services sometimes issue the **same** idempotent `GET` (or a read-only SQL) against two replicas and take whichever answers first—classic tail-latency shaving when duplicates are cheap and the database dedupes by snapshot isolation:

```ruby
TIMEx::Composers::Hedged.new(
  after: 0.05,
  max: 2,
  child: :cooperative,
  idempotent: true
).call(deadline: 0.5) do
  replica = rand < 0.5 ? :east : :west
  fetch_user_snapshot(replica: replica, id: id) # your idempotent GET / read replica
end
```

Only do this when the downstream is explicitly OK with double reads (caches, materialized views, idempotent GET semantics). Never hedge “debit account” unless the API is designed for it.
