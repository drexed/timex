# CLI long-running command

A subcommand that streams work with a `--timeout` flag, honors
`Ctrl-C`, and escalates to a hard kill if the cooperative loop refuses
to stop.

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "timex"

options = { timeout: 30.0 }
OptionParser.new do |opts|
  opts.on("--timeout SECONDS", Float) { |v| options[:timeout] = v }
end.parse!(ARGV)

cancelled = false
Signal.trap("INT")  { cancelled = true }
Signal.trap("TERM") { cancelled = true }

backstop = TIMEx::Composers::TwoPhase.new(
  soft:          :cooperative,
  hard:          :unsafe,
  grace:         1.0,
  hard_deadline: 2.0,
  idempotent:    true # re-processing a row is a no-op upsert
)

begin
  backstop.call(deadline: options[:timeout]) do |deadline|
    Importer.each_row do |row|
      raise Interrupt if cancelled
      deadline.check!
      Importer.process(row, deadline: deadline.min(0.5))
    end
  end
rescue Interrupt
  warn "cancelled by user"; exit 130
rescue TIMEx::Expired => e
  warn "timeout after #{e.elapsed_ms}ms (budget #{e.deadline_ms}ms)"; exit 124
end
```

`SIGINT` flips the cooperative bit between rows; `--timeout` is the
soft budget. After `remaining + grace` the hard phase may `Thread#kill`
the soft worker and re-run the block under `:unsafe` — that's why the
row processor has to be safe to repeat.

See [TwoPhase](../docs/composers/two_phase.md).
