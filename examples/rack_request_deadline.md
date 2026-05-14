# Rack request deadline

`RackMiddleware` parses inbound `X-TIMEx-Deadline`, short-circuits
requests that arrived already-expired, and (optionally) echoes the
remaining budget back on success. Stash the parsed deadline on
`Current` so every layer reads the same object without re-parsing.

```ruby
# config.ru
require "timex"
require_relative "config/environment"

use TIMEx::Propagation::RackMiddleware,
    default_seconds:          30,    # apply when no header was sent
    max_seconds:              30,    # clamp untrusted inbound budgets
    max_depth:                8,     # reject runaway hop counts
    clamp_infinite_to_default: true, # never honor ms=inf from outside
    expose_remaining:         true   # X-TIMEx-Remaining-Ms on success

run Rails.application
```

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :deadline
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action { Current.deadline = request.env["timex.deadline"] || TIMEx::Deadline.in(2.0) }
end

# app/controllers/widgets_controller.rb
class WidgetsController < ApplicationController
  def show
    TIMEx.deadline(Current.deadline) do |d|
      @widget = Widget.find_with_deadline(params[:id], deadline: d.min(0.5))
    end
  end
end
```

The middleware returns `503` with `X-TIMEx-Outcome: expired-on-arrival`
when the caller's budget is already burned — load balancers can
distinguish "client gave up" from "server bug" without scanning logs.
`max_seconds` / `clamp_infinite_to_default` make the inbound header
policy-bounded on the public edge; trusted internal edges can drop
those.

See [Rack middleware](../docs/propagation/rack.md).
