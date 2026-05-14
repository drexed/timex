# Migrating from stdlib `Timeout`

If your muscle memory says `require "timeout"` and `Timeout.timeout(n)`, you
are not alone. This page is a gentle swap guide: same rough idea (stop after N
seconds), but with names and knobs that play nicely with the rest of TIMEx.

## TL;DR

```ruby
# Before
require "timeout"
Timeout.timeout(2) { work }

# After (1) — still interrupts the block like stdlib, but you asked for it by name
require "timex"
TIMEx.deadline(2.0, strategy: :unsafe) { work }

# After (2) — nicer when you control the loop: you pick safe places to look at the clock
TIMEx.deadline(2.0) do |d|
  loop do
    d.check!
    work_step
  end
end
```

Path (1) is the “I need a drop-in” story. Path (2) is the “I can add a few
`check!` calls” story—the one we hope new code uses.

## Real-world: replace `Timeout` in one integration

A legacy integration used `Timeout.timeout(30)` around a SOAP client. The
first safe step is naming the sharp edge, then tightening the loop when you
touch that file again:

```ruby
# Before — whole client call interrupted asynchronously
Timeout.timeout(30) { soap_client.call(payload) }

# After — same urgency, explicit unsafe strategy until you can add check! / IO
TIMEx.deadline(30.0, strategy: :unsafe) { soap_client.call(payload) }
```

Once the SOAP layer exposes streaming or per-chunk hooks, switch to
`TIMEx::Strategies::IO` or cooperative `check!` and drop `:unsafe`.

## Pick your replacement (simple matrix)

| What you are wrapping | Reach for |
|---|---|
| A pure Ruby loop you wrote | Cooperative mode + `deadline.check!` |
| `Net::HTTP`, sockets, blocking IO | `TIMEx::Strategies::IO` (read / write / connect) or the library’s own `*_timeout` options |
| A C extension call you cannot change | `Subprocess` |
| A whole Rack request | `Propagation::RackMiddleware` + `TwoPhase` |
| A background job with a soft “please stop” and a hard ceiling | `TwoPhase` (soft: cooperative, hard: subprocess) |
| Code you cannot audit line by line | `TwoPhase` (soft: unsafe, hard: subprocess) — still clearer than stdlib because the hard stop lives in a separate process |

If a row feels fuzzy, skim [Getting Started](getting_started.md) and the
strategy pages—it is OK to read twice.

## Why bother leaving stdlib?

- **Random interrupt points.** `Timeout.timeout` raises on whatever Ruby
  instruction happens to be running. That can mean “oops, we were holding a
  mutex,” which is hard to debug and easy to ship by accident.
- **Global thread tricks.** The mechanism is coarse; a bare `rescue` or
  `rescue Exception` can hide the timeout and leave you thinking work finished
  when it did not.
- **No shared budget.** Nested calls each start their own timer. TIMEx prefers
  one deadline you pass down like a shared allowance.
- **You can see timeouts happen.** Strategies emit finish events (strategy,
  outcome, elapsed time). Wire a [Telemetry](telemetry.md) adapter and your logs
  or traces tell the same story your code does.

None of this means stdlib is “evil” for every script—see
[Comparison](comparison.md) for when “good enough” is honestly good enough.
