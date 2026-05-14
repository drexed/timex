# Migrating a legacy `Timeout.timeout` block

You inherited this:

```ruby
require "timeout"

def render_pdf(doc)
  Timeout.timeout(10) { ExternalRenderer.render(doc) }
end
```

## Step 1 — rename to `:unsafe` so the risk is obvious

Same `Thread#raise` mechanics, but the call site now advertises what
it's actually doing. Reviewers and `bin/timex-lint` notice.

```ruby
require "timex"

def render_pdf(doc)
  TIMEx.deadline(10, strategy: :unsafe) { ExternalRenderer.render(doc) }
end
```

## Step 2 — wrap with `TwoPhase` so the worker can't wedge

Cooperative first; only fall back to a subprocess kill when the
renderer ignores cancellation (rescue Exception, GVL-holding C ext).

```ruby
RENDER_PDF = TIMEx::Composers::TwoPhase.new(
  soft:          :cooperative,
  hard:          :subprocess,
  grace:         1.0,
  hard_deadline: 5.0,
  idempotent:    true # render writes to a temp path; re-running overwrites
).freeze

def render_pdf(doc)
  RENDER_PDF.call(deadline: 10) { ExternalRenderer.render(doc) }
end
```

Worst-case wall time is bounded at `10 + 1 + 5 = 16s`. The Sidekiq /
Puma worker slot is never held longer than that, even if the C
renderer has decided the GVL is its forever home.

## Step 3 — push the deadline into the renderer itself

Once `render` accepts a `Deadline`, the composer is just belt-and-
suspenders. Cooperation is always cheaper than escalation.

```ruby
def render_pdf(doc)
  TIMEx.deadline(10) { |d| ExternalRenderer.render(doc, deadline: d) }
end
```

See [TwoPhase](../docs/composers/two_phase.md) and
[Unsafe](../docs/strategies/unsafe.md).
