<div align="center">
  <img src="./src/timex-light-logo.png#gh-light-mode-only" width="200" alt="TIMEx Light Logo">
  <img src="./src/timex-dark-logo.png#gh-dark-mode-only" width="200" alt="TIMEx Dark Logo">

  ---

  Deadlines, budgets, and cancellation you can reason about in production.

  [Home](https://drexed.github.io/timex) ·
  [Documentation](https://drexed.github.io/timex/getting_started) ·
  [Blog](https://drexed.github.io/timex/blog) ·
  [Changelog](./CHANGELOG.md) ·
  [Report Bug](https://github.com/drexed/timex/issues) ·
  [Request Feature](https://github.com/drexed/timex/issues) ·
  [AI Skills](https://github.com/drexed/timex/blob/main/skills) ·
  [llms.txt](https://drexed.github.io/timex/llms.txt) ·
  [llms-full.txt](https://drexed.github.io/timex/llms-full.txt)

  <img alt="Version" src="https://img.shields.io/gem/v/timex">
  <img alt="Build" src="https://github.com/drexed/timex/actions/workflows/ci.yml/badge.svg">
  <img alt="License" src="https://img.shields.io/badge/license-LGPL%20v3-blue.svg">
</div>

# TIMEx

TIMEx is a **deadline engine** for Ruby: one facade runs your code under a `Deadline`, picks an execution strategy (cooperative checks, thread wakeup, IO deadlines, subprocesses, and more), and routes expiry through consistent `on_timeout` semantics—without pulling in a framework.

> [!NOTE]
> [Documentation](https://drexed.github.io/timex/getting_started/) reflects the latest code on `main`. For version-specific documentation, refer to the `docs/` directory within that version's tag.

## What you get

- **`TIMEx.deadline` / `TIMEx.call`** — single entrypoint with `strategy:`, `on_timeout:`, `auto_check:`, and strategy-specific options
- **`Deadline`** — monotonic + wall alignment, narrowing (`#min`), skew-aware header encoding (`X-TIMEx-Deadline`)
- **Strategies** — `:cooperative`, `:unsafe`, `:io`, `:wakeup`, `:subprocess`, `:closeable`, `:ractor` (when `Ractor` is defined), each registered on `TIMEx::Registry`
- **Composers** — `TwoPhase`, `Hedged`, `Adaptive` for multi-attempt and staged execution
- **`on_timeout`** — `:raise` (default), `:raise_standard`, `:return_nil`, `:result`, or a custom `Proc` with shared dispatch in `TimeoutHandling`
- **`Result`** — discriminated `:ok` / `:timeout` / `:error` outcomes when you opt out of raising
- **Propagation** — `Deadline#to_header` / `Deadline.from_header` plus optional Rack middleware for cross-service budgets
- **Telemetry & clocks** — pluggable `Telemetry.adapter`, injectable monotonic/wall `Clock`, and `TIMEx::Test::VirtualClock` for tests
- **Rails (opt-in)** — install generator adds initializer hooks without loading Rails from the core require

See the [feature comparison](https://drexed.github.io/timex/comparison/) for how TIMEx compares to `Timeout.timeout` and other patterns.

## Requirements

- Ruby: MRI 3.3+ or a compatible JRuby/TruffleRuby release
- Runtime dependencies: none beyond the standard library (no ActiveSupport required)

Rails middleware and generators load only when you opt in after `bundle install`.

## Installation

```sh
gem install timex
# - or -
bundle add timex
```

## Quick example

### 1. Budget

Pass seconds, a `Deadline`, or `nil` for an infinite budget. The block receives a frozen `Deadline` you can thread through helpers.

```ruby
deadline = TIMEx::Deadline.in(2.5)
TIMEx.deadline(deadline) { |d| process!(d) }
```

### 2. Run

The default `:cooperative` strategy runs your block and performs a final `check!` so CPU-bound work still observes expiry at cooperative points.

```ruby
TIMEx.deadline(1.0) do |deadline|
  rows = fetch_rows
  deadline.check!
  summarize(rows)
end
```

### 3. On expiry

Override per call or via `TIMEx.configure`. Use `:result` when you want a `TIMEx::Result` instead of an exception.

```ruby
outcome = TIMEx.deadline(0.01, on_timeout: :result, strategy: :unsafe) do
  sleep 5 # interrupted when the budget is exhausted
end

outcome.timeout? # => true
```

### 4. Propagate

Serialize remaining budget into an outbound request so downstream services share the same cap.

```ruby
req["X-TIMEx-Deadline"] = TIMEx::Deadline.in(3.0).to_header
# or use TIMEx::Propagation::RackMiddleware on the server (see docs)
```

Ready to go deeper? Start with [Getting Started](https://drexed.github.io/timex/getting_started/) and [Migrating from stdlib `Timeout`](https://drexed.github.io/timex/migrating_from_stdlib_timeout/).

## Contributing

Bug reports and pull requests are welcome at <https://github.com/drexed/timex>. We're committed to fostering a welcoming, collaborative community. Please follow our [code of conduct](CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [LGPLv3 License](https://www.gnu.org/licenses/lgpl-3.0.html).
