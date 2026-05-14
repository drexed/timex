# Ractor

Give TIMEx a **pure-ish CPU chunk**, ship it to a **Ractor**, and wait—up to your deadline—for an answer. If the clock wins first, TIMEx **walks away**: the Ractor keeps chewing in the background and its result is **dropped**.

**Mental model:** texting a friend for trivia at a bar quiz. If they reply before last call, great. If not, you guess yourself—they might still text you later, but you are not waiting at the door.

## Quick example

```ruby
TIMEx.deadline(2.0, strategy: :ractor) { pure_function(input) }
```

Keep the block **shareable** and side-effect light—Ractors still have sharp edges in Ruby.

## At a glance

| Topic                  | Plain English                                                                                               |
| ---------------------- | ----------------------------------------------------------------------------------------------------------- |
| CPU-heavy work         | **No hard stop** inside the Ractor if you time out—the work may finish anyway.                              |
| Blocking IO            | Same story: you stopped waiting, not the syscall.                                                           |
| Mutexes / shared state | Safer than threads for isolation—Ractors do not share mutable soup by default.                              |
| Ruby version           | Same baseline as the gem (**3.3+** today). Ractors remain **experimental** in MRI—ship with extra paranoia. |

## When this actually helps

- Optional **speculative compute** (prefetch, warm cache) where losing the result is fine because another code path covers you.
- CPU-only **embarrassingly parallel** helpers that never touch the outside world.

## When to pick something else

If you **must reclaim CPU** when time is up, use **[Subprocess](https://drexed.github.io/timex/strategies/subprocess/index.md)** so the OS can actually evict the work.

## Real-world: speculative cache warm on a product page

The product page already has the data it needs from Postgres. While the template renders, you would *like* to pre-decode a related-products JSON blob into the cache—but only if it finishes in under 50 ms. Past that, the page ships without it and the next request can warm the cache itself:

```ruby
def related_products_warm!(product_id, blob)
  TIMEx.deadline(0.05, strategy: :ractor, on_timeout: :return_nil) do
    parsed = JSON.parse(blob, symbolize_names: true)
    Rails.cache.write("related:#{product_id}", parsed, expires_in: 5.minutes)
    parsed
  end
end
```

If 50 ms is not enough this time, the ractor keeps parsing in the background (telemetry emits `ractor.leak`) and your request returns `nil` instead of waiting—exactly the trade-off speculative work is supposed to make.
