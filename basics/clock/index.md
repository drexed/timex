# Clock

Real programs wait on the network. **Tests** should not spend real seconds doing that. `TIMEx::Clock` is the small indirection that answers “what time is it?” so production keeps real nanoseconds while specs can **fast-forward** time without `sleep`.

## Production clock (default)

In the wild, TIMEx reads **`Process.clock_gettime`** in nanoseconds:

- **Monotonic** clock drives deadlines (`Deadline.in`, `expired?`, `check!`).
- **Wall** clock is only for things like `Deadline#wall_ns` when you serialize or compare with timestamps humans care about.

You rarely touch this directly—think of it as the honest stopwatch behind the curtain.

## Virtual clock in tests

```ruby
TIMEx::Test.with_virtual_clock do
  d = TIMEx::Deadline.in(1.0)
  TIMEx::Test.advance(2.0)
  d.expired? # => true
end
```

The fake clock lives in a **thread variable** (`Thread.current.thread_variable_*`), which means **all fibers in the same thread share it**—useful when you `Fiber.schedule` inside a spec. Only code paths that ask TIMEx for time through the deadline APIs above will “see” the jump; child threads start with the real clock unless you install one explicitly there too.

**Heads-up:** strategies that block on the **real OS**—think `Subprocess` or `Wakeup`—still wait on real kernel time. The virtual clock is for Ruby-level deadline math, not for “make `Kernel#sleep` instant.”

## Bring your own clock

Anything that responds to **`monotonic_ns`** and **`wall_ns`** (integer nanoseconds) can stand in:

```ruby
TIMEx.configure { |c| c.clock = MySimulatedClock.new }
```

Or keep it scoped:

```ruby
TIMEx::Clock.with(MySimulatedClock.new) { ... }
```

Use that when you embed TIMEx inside a bigger simulator or deterministic replay tooling.
