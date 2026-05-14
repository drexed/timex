# Faraday middleware

A Faraday middleware that reads the active `Deadline` off the request
options, sets per-request `open_timeout` / `timeout` from the
remaining budget, and propagates the deadline header downstream.

```ruby
require "faraday"
require "timex"

class TIMExFaraday < Faraday::Middleware
  def call(env)
    deadline = env.request.context&.dig(:timex_deadline)
    return @app.call(env) unless deadline

    remaining = deadline.remaining
    raise deadline.expired_error(strategy: :io, message: "faraday: budget exhausted") if remaining <= 0

    env.request.open_timeout = remaining
    env.request.timeout      = remaining
    TIMEx::Propagation::HttpHeader.inject(env.request_headers, deadline)

    @app.call(env)
  end
end

Faraday::Request.register_middleware(timex: TIMExFaraday)

CONN = Faraday.new("https://api.example.com") do |f|
  f.request  :timex
  f.request  :retry, max: 2, interval: 0.05, retry_statuses: [502, 503, 504]
  f.response :raise_error
  f.adapter  Faraday.default_adapter
end

def fetch_users(deadline:)
  CONN.get("/users", nil) { |req| req.options.context = { timex_deadline: deadline } }
end

TIMEx.deadline(2.0) { |d| fetch_users(deadline: d) }
```

Putting the middleware *before* `:retry` means each retry sees a
shrinking budget and the operation gives up as soon as the deadline
fires, instead of burning the full backoff schedule. The injected
`X-TIMEx-Deadline` header lets the downstream service apply the same
budget to its own work.

See [HTTP header propagation](../docs/propagation/http_header.md).
