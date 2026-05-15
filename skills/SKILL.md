---
name: timex
description: Build, debug, and document TIMEx deadline execution in Ruby. Use when enforcing budgets with TIMEx.deadline or TIMEx.call, choosing strategies and composers, handling Expired and on_timeout modes, propagating X-TIMEx-Deadline headers, configuring telemetry and clocks, or testing with VirtualClock. Don't use for generic Ruby refactors, CMDx-style service objects, or unrelated timeout wrappers without TIMEx APIs.
---

# TIMEx Agent Skill

TIMEx is a Ruby **deadline engine**: one entrypoint runs a block under a frozen `Deadline`, resolves a **strategy** (how expiry is enforced), and routes overrun through **`on_timeout`** semantics. Full doc trees load from [llms.txt](https://drexed.github.io/timex/llms.txt) and [llms-full.txt](https://drexed.github.io/timex/llms-full.txt); human docs live on [the project site](https://drexed.github.io/timex/getting_started).

## Call flow

`TIMEx.deadline` is an alias of `TIMEx.call`. Each invocation:

1. **Coerces** the first argument with `Deadline.coerce` (seconds, `Deadline`, wall `Time`, or `nil` → infinite).
2. **Resolves** `strategy:` via `Registry.resolve_for_call` (`nil` → configured default, often `:cooperative`).
3. Wraps the block in **`AutoCheck.run`** when `auto_check: true` (or when `auto_check` is `nil` and `Configuration#auto_check_default` is true): periodic `TracePoint`-driven `deadline.check!` for CPU-heavy work.
4. Invokes the strategy’s **`#call(deadline:, on_timeout:, **opts, &block)`** — typically `Strategies::Base#call`, which instruments telemetry (unless the adapter is null), runs `#run`, rescues `Expired`, and dispatches **`TimeoutHandling#handle_timeout`**.
5. Returns the block’s value, a handler return (`:return_nil`, `:result`, custom `Proc`), or raises per `on_timeout`.

Strategies raise `TIMEx::Expired` on overrun (inherits **`Exception`**, not `StandardError`). Composers (`TwoPhase`, `Hedged`, `Adaptive`) are callable like strategies and reuse the same `on_timeout` contract.

## API surface

| Area | Primary APIs |
|------|----------------|
| Entry | `TIMEx.deadline(...)`, `TIMEx.call(...)` — `strategy:`, `on_timeout:`, `auto_check:`, strategy-specific `**opts` |
| Deadline | `Deadline.in`, `at_wall`, `infinite`, `coerce`, `from_header`, `to_header`, `#remaining`, `#expired?`, `#check!`, `#min` |
| Strategies (registered) | `:cooperative`, `:unsafe`, `:io`, `:wakeup`, `:closeable`, `:subprocess`, `:ractor` (if `Ractor` defined) |
| Composers | `TIMEx::Composers::TwoPhase`, `Hedged`, `Adaptive` — instantiate and pass as `strategy:` |
| Timeout dispatch | `on_timeout:` `:raise` (default), `:raise_standard`, `:return_nil`, `:result`, or `Proc` |
| Outcomes | `TIMEx::Result.ok` / `.timeout` / `.error`, `#ok?`, `#timeout?`, `#value!` |
| Registry | `TIMEx::Registry.register`, `fetch`, `resolve`, `default_selector` |
| Config | `TIMEx.configure` / `TIMEx.config` — defaults for strategy, `on_timeout`, `auto_check_*`, telemetry, clock, skew |
| Propagation | `Deadline::HEADER_NAME` (`X-TIMEx-Deadline`), `Propagation::HttpHeader`, `Propagation::RackMiddleware` |
| Cancellation | `TIMEx::CancellationToken` — manual cooperative cancel alongside deadlines |
| Tests | `TIMEx::Test::VirtualClock` — deterministic monotonic/wall time |

## Minimal call

```ruby
TIMEx.deadline(2.5) do |deadline|
  do_work(deadline)
end
```

## Cooperative checks

```ruby
TIMEx.deadline(1.0) do |deadline|
  rows = fetch_rows
  deadline.check!        # raises TIMEx::Expired if over budget
  summarize(rows)
end
```

## Unsafe + Result

```ruby
outcome = TIMEx.deadline(
  0.01,
  strategy: :unsafe,
  on_timeout: :result
) { sleep 5 }

outcome.timeout? # => true
outcome.error    # => TIMEx::Expired (carried on timeout results)
```

## Strategies (built-in)

- **`:cooperative`** — final `check!` after the block; no async injection. Safe default; CPU-bound loops need explicit `check!` or `auto_check: true`.
- **`:unsafe`** — watchdog `Thread.raise`; can interrupt anywhere. Prefer only when the block tolerates async exceptions.
- **`:io`** — bounds blocking IO via platform primitives where available.
- **`:wakeup`** — timer thread wakes blocked IO where supported.
- **`:closeable`** — associates closeables with the deadline lifecycle.
- **`:subprocess`** — isolates work in a child process (platform-specific).
- **`:ractor`** — Ractor-based isolation when defined.

Register custom callables with `TIMEx::Registry.register(:name, callable)`. Resolve `strategy:` with a `Symbol`, registered class/instance, or any object responding to `#call(deadline:, on_timeout:, **opts, &block)` matching `Strategies::Base`.

## Composers

- **`TwoPhase`** — soft strategy in a worker thread, then **hard** strategy after `grace` if soft overruns; requires **`idempotent: true`** (block may run twice; first attempt may be `Thread#kill`ed).
- **`Hedged`** — staggered parallel attempts (`after:`, `max:`); **`idempotent: true`** required; losers killed with `Thread#kill`.
- **`Adaptive`** — picks a child budget from an internal latency estimator (`InMemoryStore`); feeds timeouts back into estimates before applying the caller’s `on_timeout:`.

## `on_timeout`

Modes (`TIMEx::ON_TIMEOUT_SYMBOLS`): `:raise` → `Expired`; `:raise_standard` → `TimeoutError` (subclass of `StandardError`, `#cause`-like via `#original`); `:return_nil` → `nil`; `:result` → `Result.timeout(...)`. A **`Proc`** receives the `Expired` and may return or raise.

## `Result`

Frozen discriminated union: `:ok`, `:timeout`, `:error`. Use `#value!` / `#unwrap` to explode non-OK paths; `#value_or` / `#unwrap_or` for fallbacks. Supports `#deconstruct` / `#deconstruct_keys` for pattern matching.

## Propagation

- Serialize: `deadline.to_header` → `X-TIMEx-Deadline` wire format (bounded size, depth, skew rules).
- Parse: `Deadline.from_header(str)` → `Deadline` or `nil` on rejection (malformed, ambiguous `ms`+`wall`, depth caps, etc.).
- Rack: `TIMEx::Propagation::RackMiddleware` decodes inbound headers, clamps/rejects, optional outbound remaining injection — see gem docs for options (`default_seconds`, `expose_remaining`, etc.).

## Configuration

```ruby
TIMEx.configure do |c|
  c.default_strategy = :cooperative
  c.default_on_timeout = :raise
  c.auto_check_default = false
  c.auto_check_interval = 1000
  c.telemetry_adapter = my_adapter # must respond to #emit
  c.clock = my_clock               # #monotonic_ns, #wall_ns
  c.skew_tolerance_ms = 250
end
```

`TIMEx.reset_configuration!` restores defaults (tests).

## Telemetry

`TIMEx::Telemetry.instrument` / `emit` wrap strategy calls and several composers when a non-null adapter is configured. Strategies skip instrumentation overhead when the adapter is the null adapter.

## AutoCheck

When enabled, uses `TracePoint` on Ruby events and respects **`Thread.current.thread_variable_get(:timex_shielded)`** to skip checks inside critical regions.

## Cancellation

`CancellationToken#cancel` / `#on_cancel` for explicit cooperative cancellation (e.g. hedged losers). Observer errors are swallowed and reported via telemetry.

## Exceptions and errors

- **`TIMEx::Expired`** — `< Exception`; not caught by bare `rescue` or `rescue StandardError`.
- **`TIMEx::TimeoutError`** — `< StandardError`; use when interoperating with typical rescue chains (`on_timeout: :raise_standard`).
- **`TIMEx::Error`**, **`ConfigurationError`**, **`StrategyNotFoundError`** — configuration/registry misuse.

## Testing

Use **`TIMEx::Test::VirtualClock`** to advance monotonic/wall time deterministically instead of sleeping in specs. Reset configuration between examples if mutating globals.

## Common pitfalls

1. **`rescue` without listing `Expired`** — timeout escapes generic handlers; rescue `TIMEx::Expired` explicitly or use `:raise_standard`.
2. **Passing a bare `Symbol` as the first argument** — `Deadline.coerce` rejects it (use `strategy:` keyword).
3. **Assuming `:cooperative` stops tight CPU loops** — without `deadline.check!`, `auto_check: true`, or a harder strategy, loops can run past budget until the post-block check.
4. **`TwoPhase` / `Hedged` without idempotent blocks** — side effects and partial mutations under `Thread#kill` / double invocation corrupt state.
5. **Mutating shared state under `:unsafe`** — async `raise` can leave invariants broken mid-method.
6. **Trusting raw propagated headers** — always parse with `from_header`; rejections return `nil`; rely on middleware policy for depth and expiry-on-arrival.
7. **Infinite parent deadlines in composers** — soft budgets and waits may behave differently when `deadline.infinite?`; read composer docs for edge cases.

## References

- Site docs: [Getting started](https://drexed.github.io/timex/getting_started), [comparison](https://drexed.github.io/timex/comparison), [migrating from stdlib Timeout](https://drexed.github.io/timex/migrating_from_stdlib_timeout)
- Repo `docs/` on each release tag for version-locked prose
- [llms-full.txt](https://drexed.github.io/timex/llms-full.txt) for exhaustive machine-oriented bundling
