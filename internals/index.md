# Internals

This page is for anyone who likes knowing *where the levers are*. You do not need it to ship a feature—but after you read it, stack traces from TIMEx should feel less mysterious.

## How the pieces connect

Think of **`TIMEx.deadline`** (and friends) as a host at a restaurant: it looks up your reservation in the **strategy registry**, seats you with the right **strategy**, and keeps an eye on the **`Deadline`** while you eat. Telemetry and propagation helpers hang out at the same party so you can observe and share budgets.

```
flowchart TB
  Facade["TIMEx.deadline / TIMEx.deadline"]
  Registry[Strategy Registry]
  Facade --> Registry
  Registry --> Coop[Cooperative]
  Registry --> IO_[IO]
  Registry --> Wakeup
  Registry --> Closeable
  Registry --> Unsafe
  Registry --> Subprocess
  Registry --> Ractor_[Ractor]
  Composers["Composers (TwoPhase, Hedged, Adaptive)"]
  Facade -. optional callable .-> Composers
  Composers --> Deadline
  Coop --> Deadline
  IO_ --> Deadline
  Deadline --> Clock
  Facade --> Telemetry
  Propagation[Propagation: header / Rack] --> Deadline
```

**Plain-English tour:**

- **Facade** — `TIMEx.deadline`, `TIMEx.deadline` delegate to whatever strategy you pass in, or—when you omit it—to the configured default from the registry.
- **Registry** — maps symbols like `:cooperative` to real strategy classes; also holds hooks like `default_selector` for companion gems. Built-in composers are **not** registered by default—you `.new` them (or register your own alias).
- **Strategies** — each registered runner owns a slice of the problem (cooperative checkpoints, IO polling, subprocess isolation, …).
- **Composers** — `TwoPhase`, `Hedged`, `Adaptive`: strategy-shaped objects that call one or more registered strategies; same `#call(deadline:, …)` surface area.
- **Deadline + Clock** — monotonic math so “two seconds” means two seconds even if wall clocks jump.
- **Propagation** — optional helpers that parse or emit headers so budgets cross process boundaries.
- **Telemetry** — tells you what finished, how, and how long it took.
- **Result** — when you opt into `on_timeout: :result`, you get back a frozen `TIMEx::Result` (`:ok` / `:timeout` / `:error`) instead of an exception. Pattern match on it or call `value!` to re-raise—handy for service objects that prefer Either-shaped returns.

## What a strategy must do

Most custom strategies subclass **`TIMEx::Strategies::Base`** and implement `run`:

```ruby
class MyStrategy < TIMEx::Strategies::Base
  protected

  def run(deadline)
    yield(deadline) # the user block
    # ... timing / escalation logic ...
  end
end

TIMEx::Registry.register(:my, MyStrategy)
```

**Checklist (the boring stuff that keeps production boring):**

- Let **`Base`** coerce the incoming deadline with `TIMEx::Deadline.coerce`—do not hand-roll parsing unless you have a strong reason.
- Raise **`TIMEx::Expired`** when time is truly up. It subclasses `Exception` on purpose (see below).
- Respect **`Deadline#shield`** blocks—users can mark regions where expiry should wait.
- Be safe to call more than once: no thread leaks, no stray file descriptors, no surprise background timers left running.

## What a composer is

A **composer** is anything that exposes `#call(deadline:, on_timeout:, **opts, &block)` and forwards to one or more strategies. Composers **do not** have to inherit `Base`; read `TwoPhase`, `Hedged`, and `Adaptive` as living examples of “orchestrate, do not reinvent.”

## Why `Expired` is not a `StandardError`

`TIMEx::Expired < Exception`, **not** `< StandardError`. That sounds picky, but it saves you from this trap:

```ruby
begin
  TIMEx.deadline(0.01) { sleep 1 }
rescue => e
  # Swallows StandardError only—Expired still propagates
end
```

So a bare `rescue => e` will **not** accidentally eat a deadline. When you really mean “catch everything including expiry,” spell it out:

```ruby
rescue StandardError, TIMEx::Expired => e
```

Prefer **`on_timeout: :raise_standard`** when you want a **`TimeoutError`** (`StandardError`) instead—handy for codebases that intentionally rescue broad `StandardError` but still need a timeout signal.

Or use a **`TwoPhase`** backstop when you need cleanup *and* a harder stop after grace.

## Rules of thumb

- **The `Deadline` is the contract.** Strategies disagree on *how* to stop; they should agree on *when* the budget is spent.
- **Cooperative first, violent later.** Escalate strategy by strategy instead of jumping straight to `Unsafe` because it felt fast in a spike.
- **Compose, don’t fork-copy-paste.** If you need two behaviors, a composer plus two strategies beats one mega-class.
- **Read telemetry when behavior surprises you.** Time bugs love to hide in nested calls and header skew.
