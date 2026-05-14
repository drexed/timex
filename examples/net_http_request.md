# Net::HTTP request with a deadline

`Net::HTTP` already speaks real socket timeouts. Configure those from
the remaining budget, then propagate the deadline header so the
downstream service shares the same clock.

```ruby
require "net/http"
require "timex"

def fetch(url, deadline:)
  uri  = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"

  remaining = deadline.remaining
  raise deadline.expired_error(strategy: :io, message: "net/http: budget exhausted") if remaining <= 0

  http.open_timeout  = remaining
  http.read_timeout  = remaining
  http.write_timeout = remaining

  req = Net::HTTP::Get.new(uri.request_uri)
  TIMEx::Propagation::HttpHeader.inject(req, deadline)

  http.start { |conn| conn.request(req) }
rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
  raise deadline.expired_error(strategy: :io, message: "net/http timed out")
end

TIMEx.deadline(2.0) { |d| fetch("https://api.example.com/users", deadline: d) }
```

The native `*_timeout` knobs are what actually stop the socket;
TIMEx caps how long Ruby waits and carries the budget across the
service boundary in the header. Translating `Net::*Timeout` into
`TIMEx::Expired` keeps your `rescue` site uniform — one exception
class, two failure modes.

See [Net::HTTP timeouts](../docs/getting_started.md) and
[HTTP header propagation](../docs/propagation/http_header.md).
