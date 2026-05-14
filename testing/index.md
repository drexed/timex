# Testing

Slow specs make everyone grumpy. TIMEx ships a **virtual clock** so you can pretend time passed instantly instead of calling `sleep` and watching CI turn gray.

## TL;DR

```ruby
require "timex"

RSpec.describe MyService do
  around { |ex| TIMEx::Test.with_virtual_clock { ex.run } }

  it "honors the deadline" do
    d = TIMEx::Deadline.in(1.0)
    TIMEx::Test.advance(2.0)
    expect(d).to be_expired
  end

  it "does not raise inside the budget" do
    expect {
      TIMEx.deadline(1.0) { |d| TIMEx::Test.advance(0.5); :ok }
    }.not_to raise_error
  end
end
```

Wrap the example (or suite) in **`TIMEx::Test.with_virtual_clock`**, then **`TIMEx::Test.advance(seconds)`** whenever you want “time went by” without the CPU napping. **`TIMEx::Test.freeze_time`** is an alias of `with_virtual_clock` for specs that read more naturally that way.

## How the virtual clock helps (plain English)

- Deadlines created under the virtual clock read from the fake timeline, not from `Time.now` every tick.
- **`advance`** moves that timeline forward; **`be_expired`** and friends line up with what juniors expect: “we jumped past the budget, so yes, expired.”

Use it for cooperative code paths, `TIMEx.deadline` blocks, and anything driven by `Deadline` math.

## When you still need real wall clock

Some strategies talk to the OS timer directly:

- `Subprocess`
- `Wakeup`
- `Closeable`
- `Unsafe`

The virtual clock cannot fast-forward the kernel. For those, keep timeouts tiny (think tens of milliseconds) so specs stay quick and deterministic enough.

## Telemetry in specs

Want to prove a timeout fired without spelunking log files? Point TIMEx at a tiny adapter that remembers what it saw:

```ruby
class CollectingAdapter < TIMEx::Telemetry::Adapters::Base
  attr_reader :events

  def initialize
    super()
    @events = []
  end

  def finish(event:, payload:)
    @events << [event, payload]
  end
end

collector = CollectingAdapter.new
TIMEx.configure { |c| c.telemetry_adapter = collector }

TIMEx.deadline(0.001, on_timeout: :return_nil) { |d| sleep 0.05; d.check! }
expect(collector.events).not_to be_empty
```

(You can also use Logger + `StringIO` if you prefer reading strings—see [Telemetry](https://drexed.github.io/timex/telemetry/index.md) for adapter shapes.)

Remember **`TIMEx.reset_configuration!`** in an `around` hook so one example does not leak adapters into the next—same idea as [Configuration](https://drexed.github.io/timex/configuration/index.md).

## Real-world: lock down the “90-second prod import” regression

Ops paged you twice this month: a CSV import that should cap at 60 s occasionally took 90 s in prod and a downstream worker died. The fix was a missing `check!`—write the spec so the **next** missing `check!` fails CI instead of pager duty, all in microseconds of wall time:

```ruby
RSpec.describe ImportJob do
  let(:collector) do
    Class.new(TIMEx::Telemetry::Adapters::Base) do
      attr_reader :events
      def initialize = (super(); @events = [])
      def finish(event:, payload:) = @events << [event, payload]
    end.new
  end

  around do |ex|
    TIMEx::Test.with_virtual_clock do
      TIMEx.configure { |c| c.telemetry_adapter = collector }
      ex.run
      TIMEx.reset_configuration!
    end
  end

  it "stops the import at the 60s budget instead of hanging" do
    expect {
      TIMEx.deadline(60.0) do |d|
        100.times { d.check!; TIMEx::Test.advance(1.0) }
      end
    }.to raise_error(TIMEx::Expired)

    expect(collector.events.last.last).to include(outcome: :timeout, strategy: :cooperative)
  end
end
```

The spec runs in roughly the time it takes to allocate the objects—no `sleep`, no flake risk—and it asserts both the behavior and the telemetry the on-call dashboard depends on.
