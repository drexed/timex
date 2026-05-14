# Unsafe

!!! danger "Seriously—read this twice"

    **`Unsafe`** uses **`Thread#raise`** to inject **`TIMEx::Expired`** at
    whatever moment Ruby next checks for async exceptions. That can leave
    mutexes half-locked, buffers half-written, and file handles dangling. It is
    the same bargain as stdlib **`Timeout`**—fast, familiar, and sharp enough to
    cut you.

## Quick example

```ruby
TIMEx.deadline(2.0, strategy: :unsafe) { legacy_block }
```

You get a timeout without rewriting the loop. You also accept the corruption
lottery if the interrupted code was not written for this.

## At a glance

| Topic | Plain English |
| --- | --- |
| CPU-heavy work | Often yes—next interrupt check can be “soon-ish.” |
| Blocking IO | **Maybe**—depends on whether the C extension cooperates with thread raises. |
| Mutexes / shared state | **No**—assume the worst. |
| Runs everywhere | Yes—no fork required. |
| How tight the timeout is | Millisecond-ish, but *where* it lands is not your call. |

## The one respectable job for `Unsafe`

Almost never the first tool. The grown-up pattern is **[TwoPhase](../composers/two_phase.md)**:
be nice with **[Cooperative](cooperative.md)** first, then **`Unsafe`** only
after a grace window when soft cancellation cannot reach the work **and** you
decide a wedged process is worse than a risky interrupt.

```ruby
TIMEx::Composers::TwoPhase.new(
  soft: :cooperative, hard: :unsafe, grace: 0.5, hard_deadline: 1.0,
  idempotent: true
).call(deadline: 2.0) { work }
```

Untrusted code? **[Subprocess](subprocess.md)**. Full stop.
