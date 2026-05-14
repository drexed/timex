# Rack middleware

[Rack](https://rack.github.io/) is Ruby’s tiny contract between web servers and
apps: one `call(env)` method, one response tuple. **`TIMEx::Propagation::RackMiddleware`**
slides into that stack so every request can **carry a deadline in** and,
when you ask for it, **echo remaining time on the way out**—without each
controller re-parsing headers by hand.

**Mental model:** the middleware is the bouncer at the door. It reads the sticky
note on the request ([`X-TIMEx-Deadline`](http_header.md)), decides if you are
already too late to enter, and if not it hands the `Deadline` to the rest of your
app via `env`.

**Trust boundary:** the inbound header is untrusted on the public internet—pair
`max_seconds:` / `max_depth:` with network controls the way you would any other
user-supplied budget knob.

## Drop-in setup

```ruby
# config.ru
require "timex"
use TIMEx::Propagation::RackMiddleware,
    default_seconds: 30,
    max_seconds: 30,          # clamp untrusted inbound budgets (do this on public edges)
    max_depth: 8,             # reject runaway hop counts
    expose_remaining: true    # echo X-TIMEx-Remaining-Ms on success responses
run MyApp
```

**`default_seconds:`** — optional. When the client sends **no** header, TIMEx
creates a fresh budget of that many seconds so `env["timex.deadline"]` is still
set. Omit it if you only want deadlines when callers opt in.

**`header_case:`** — `:rack3` (default, lower-case response keys) or `:canonical`
(`X-TIMEx-…`) for older stacks that expect mixed-case headers.

**`clamp_infinite_to_default:`** — when `true` **and** `default_seconds` is set, an
inbound `ms=inf` header is replaced with the default budget instead of being honored.
Pair with `max_seconds:` on public edges so a misconfigured (or hostile) caller
cannot opt out of your timeout policy.

## What it does (step by step)

1. **Read** `X-TIMEx-Deadline` from the Rack env (Rack exposes it as
   `HTTP_X_TIMEX_DEADLINE`).
2. **Store** the resulting `Deadline` at **`env["timex.deadline"]`** when one
   exists—or build one from `default_seconds` when you configured that.
3. **Short-circuit** if the deadline is already expired: respond **`503 Service
   Unavailable`**, plain body, and header **`X-TIMEx-Outcome: expired-on-arrival`**
   so load balancers and clients can tell “late” from “bug.”
4. **Otherwise** run your app.
5. **Response headers** — enable **`expose_remaining: true`** to add
   **`X-TIMEx-Remaining-Ms`** (Rack 3 lower-case key by default) so clients see
   how much budget is left after your work. Outcome headers on **`503`** always
   include **`X-TIMEx-Outcome`** (or canonical casing—see below).

| Step | Plain English |
| --- | --- |
| Parse header | Turn the wire string into a real `Deadline` (or `nil` if missing / junk). |
| Attach to `env` | Controllers and downstream code read `request.env["timex.deadline"]` in Rails. |
| `503` on arrival | Do not burn CPU on a request the caller already abandoned. |
| Remaining on exit | Opt-in via **`expose_remaining:`**—off by default so you do not surprise caches. |

## Using the deadline downstream

Once the middleware ran, treat `env["timex.deadline"]` like any other
`Deadline`: tighten with **`min`**, call **`check!`** in loops you own, pass it
into HTTP clients with [`HttpHeader.inject`](http_header.md).

```ruby
class WidgetsController < ApplicationController
  def show
    deadline = request.env["timex.deadline"] || TIMEx::Deadline.in(2.0)

    TIMEx.deadline(deadline) do |d|
      @widget = Widget.find_with_deadline(params[:id], deadline: d.min(0.5))
    end
  end
end
```

The `|| TIMEx::Deadline.in(2.0)` line is a local safety net when no header and
no `default_seconds` were provided—tweak to match your product rules.

## Real-world: one deadline, every Rails layer

In a real Rails app the controller, model, and any inline jobs all want the
same budget without re-parsing headers. Stash it on **`Current`** in a
`before_action`, and every layer reads the same object:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :deadline
end

class ApplicationController < ActionController::Base
  before_action :attach_deadline

  private

  def attach_deadline
    Current.deadline = request.env["timex.deadline"] || TIMEx::Deadline.in(2.0)
  end
end

class Order < ApplicationRecord
  def self.for_dashboard
    TIMEx.deadline(Current.deadline) do |d|
      includes(:line_items).where(state: :open).find_each(batch_size: 100) { |o| d.check!; yield o }
    end
  end
end
```

The header set by an upstream gateway flows through the controller, into the
model loop, and out to any HTTP client via
[`HttpHeader.inject`](http_header.md)—one budget, no surprises.
