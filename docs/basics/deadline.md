# Deadline

If TIMEx were a board game, **`TIMEx::Deadline`** would be the money on the
table. Strategies, composers, and your own code all speak the same object: “how
much time is left, and when is that officially over?”

You can build one from seconds, from a wall-clock moment, or from `nil` /
`Numeric` shorthands—everything else in the gem is basically choreography around
this value.

## Build one

```ruby
TIMEx::Deadline.in(1.5)                # 1.5s from “now” (monotonic clock)
TIMEx::Deadline.at_wall(Time.parse("2026-01-01T00:00Z"))
TIMEx::Deadline.infinite               # never expires (identity for #min)
TIMEx::Deadline.coerce(2.0)            # Numeric → Deadline; handy at boundaries
```

**Mental model:** `in` is “budget from now.” `at_wall` is “real-world calendar
time,” useful when another machine sent you a timestamp. `infinite` means “no
rush.” `coerce` is the polite adapter when someone hands you a raw number.

## Read it

```ruby
d.remaining        # Float seconds left
d.remaining_ms     # same idea, milliseconds
d.remaining_ns     # integer nanoseconds (sharp elbows for hot paths)
d.initial_ms       # original budget in ms (finite deadlines), handy for telemetry
d.expired?         # true once monotonic “now” passes the anchor
d.infinite?
d.depth            # how many hops this budget traveled (propagation)
d.origin           # optional label for who started the clock
```

If you are new here: **`remaining`** is the human-friendly number;
**`expired?`** is the yes/no gate before you keep burning CPU.

## Combine and enforce

```ruby
inner.min(outer)         # tighter deadline wins; infinite acts like “no opinion”
deadline.check!          # raises TIMEx::Expired if you are already late
deadline.shield { ... }  # run cleanup without check! ruining your day
```

**`min`** is how nested calls share one budget: whoever is stricter wins.
**`check!`** is the cooperative heartbeat—call it in loops you control.
**`shield`** is for “I know we are past the limit but I still need two lines of
cleanup.”

## Real-world: caller budget vs local SLA

An edge handler might receive `X-TIMEx-Deadline` from a mobile client while
your service policy says “never more than 800 ms in this tier.” **`min`**
applies both caps so the tighter wins—users cannot accidentally grant
themselves infinite time, and a stingy gateway cannot starve you past what your
team promised:

```ruby
inbound  = TIMEx::Deadline.from_header(request.get_header("X-TIMEx-Deadline"))
local    = TIMEx::Deadline.in(0.8)
deadline = inbound ? inbound.min(local) : local
TIMEx.deadline(deadline) { downstream.call(deadline: deadline) }
```

## On the wire (headers)

```ruby
deadline.to_header                    # "ms=1837;depth=1"
deadline.to_header(prefer: :wall)     # "wall=2026-01-01T00:00:00.000Z;depth=1"
TIMEx::Deadline.from_header(str)      # parse; nil if the string is nonsense
```

| Piece | Plain English |
| --- | --- |
| `ms=` | “Milliseconds left,” tied to **monotonic** time—great inside one data center because the wall clock cannot jump backward and confuse the math. |
| `wall=` | “Absolute stop time,” better when hosts disagree a little on “now” but you trust NTP-ish sync. The receiver re-anchors against its own monotonic clock. |

If wall skew looks ugly, TIMEx can **warn through telemetry** when drift beats
`config.skew_tolerance_ms`. See [Configuration](../configuration.md) and
[Telemetry](../telemetry.md).

## Why monotonic?

Wall clock can jump backward (NTP fixes itself, leap shenanigans, someone moves
the system clock). **`CLOCK_MONOTONIC`** only moves forward, so a deadline built
on it does not accidentally gain or lose minutes because the OS “fixed” time.
