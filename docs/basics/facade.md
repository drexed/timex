# Facade: `TIMEx.deadline`, `TIMEx.call`

These two methods are the **front door** of the gem. Same story every time:
you bring a budget (seconds, `nil`, or a ready-made `Deadline`), TIMEx picks a
strategy, and your block receives the live **`Deadline`** so cooperative code can
`check!` as it goes.

```ruby
TIMEx.deadline(2.0) { |d| work(d) }

# alias—nice for code review
TIMEx.deadline(2.0) { |d| work(d) }

# you already built the Deadline
TIMEx.deadline(my_deadline) { |d| work(d) }
```

## Options

```ruby
TIMEx.deadline(
  deadline_or_seconds,
  strategy:    nil,         # Symbol, callable strategy, or nil → default
  auto_check:  nil,         # nil → use config default; true/false per call
  on_timeout:  :raise,      # :raise | :raise_standard | :return_nil | :result | Proc
  **strategy_specific_opts,
  &block
)
```

| Option | What it does |
| --- | --- |
| `strategy:` | Override the default cooperative runner. Reach for IO, subprocess, or a composer instance when the problem is not “my own Ruby loop.” |
| `auto_check:` | Opt into TracePoint polling so legacy code gets `check!` without you rewriting it—trade CPU for safety. See [Auto-check](../auto_check.md). |
| `on_timeout:` | What happens when time is up (`Expired` vs `TimeoutError`, `nil`, `Result.timeout`, or your proc). Per-call wins over global config. |
| `**strategy_specific_opts` | Passed through to the strategy you picked—each strategy documents its own extras. |

### `on_timeout:` cheat sheet

| Value | What you get back |
| --- | --- |
| `:raise` (default) | Raises `TIMEx::Expired` (a bare `Exception`—survives `rescue => e`). |
| `:raise_standard` | Raises `TIMEx::TimeoutError` (a `StandardError`); original `Expired` is on `#original`. |
| `:return_nil` | Quietly returns `nil` so the caller can branch on truthiness. |
| `:result` | Returns a frozen `TIMEx::Result.timeout(...)` you pattern-match (`result in [:timeout, _, _]`) or `value!` to re-raise. |
| `Proc` | Your proc receives the `Expired`; whatever it returns becomes the call's return value. |

## How the default strategy is chosen

TIMEx walks this list and stops at the first hit:

1. You passed **`strategy:`** explicitly—always wins.
2. **`Registry.default_selector`** says otherwise (companion gems sometimes
   inject “use the scheduler when Async is active,” that kind of thing).
3. Fall back to **`config.default_strategy`**, which is **`:cooperative`** out
   of the box.

If that sounds like plumbing, it is—most apps only touch step 1 when they need
to. Global wiring lives in [Configuration](../configuration.md) and
[Internals](../internals.md).

## Real-world: hand an SDK the remaining budget

The Rack middleware already minted a `Deadline` for this request, and your
Stripe (or any third-party) SDK accepts its own `timeout:` option. Use
**`deadline`** so you do not start a fresh clock, and feed
**`deadline.remaining`** into the SDK so its socket timeouts agree with what
the caller asked for:

```ruby
def charge!(amount_cents:, customer_id:, deadline:)
  TIMEx.deadline(deadline) do |d|
    Stripe::PaymentIntent.create(
      { amount: amount_cents, currency: "usd", customer: customer_id, confirm: true },
      { open_timeout: d.remaining, read_timeout: d.remaining }
    )
  end
end
```

If `d` expires mid-call, Stripe’s own socket timeout fires with the same
number TIMEx is tracking—no “my timer says 0, yours says 30” mystery.
