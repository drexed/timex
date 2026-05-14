# Auto-check

Sometimes you inherit a loop that never calls `deadline.check!`. You cannot rewrite it today, but you still want the thread to notice that time ran out. Auto-check is TIMEx’s opt-in safety net: it peeks at the deadline for you on a schedule, using Ruby’s `TracePoint` machinery.

## TL;DR

```ruby
TIMEx.deadline(2.0, auto_check: true) { legacy_loop }

# Or turn it on by default for the whole process:
TIMEx.configure { |c| c.auto_check_default = true }
```

## How it works (plain English)

TIMEx enables a `TracePoint` on the **current thread** for **`:line`** and **`:b_return`** only. After every `auto_check_interval` such events (default **1000**), it asks the deadline “are we done yet?”. If yes, it raises `Expired`—same as a manual `check!`.

Why not `:c_return`? It fires on almost every C method return (`Hash#[]`, `String#+`, …). Turning that on would slow tight loops to a crawl for little extra win—so we deliberately keep the tap on Ruby-visible edges.

Think of it as a polite friend tapping your shoulder every N Ruby events instead of you remembering to look at the clock.

## Real-world: third-party CSV walk

You dropped in `CSV.foreach` from the stdlib plus a gem that processes each row with heavy Ruby—no `check!` hooks. Wrapping the whole import buys a deadline without forking the vendor stack on day one:

```ruby
TIMEx.deadline(120.0, auto_check: true) do
  CSV.foreach("vendor_dump.csv", headers: true) do |row|
    LegacyRowProcessor.new(row).run   # no checkpoints inside
  end
end
```

Plan to delete `auto_check:` once you either add explicit `check!` calls at safe row boundaries or move the hot part to `Subprocess` / `TwoPhase`.

## When to use it

- Legacy code paths where sprinkling `check!` is a big refactor.
- Short-term bridges while you move toward explicit cooperative checks.

## When not to use it (and what to use instead)

- **New code you control:** prefer `deadline.check!` at safe points. Auto-check is a convenience, not the house style.
- **Long stretches inside C extensions that hold the GVL:** Ruby never gets those TracePoint callbacks. Reach for `Subprocess` or `TwoPhase` instead.
- **Hot tight loops where every percent matters:** auto-check adds overhead (ballpark ~5% on micro-benchmarks). Bump `auto_check_interval` if you need fewer taps on the shoulder.

Auto-check is also **off** inside `Deadline#shield`, so cleanup blocks can finish without surprise cancellation.
