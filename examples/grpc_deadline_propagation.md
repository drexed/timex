# gRPC deadline propagation

gRPC ships its own deadline header (`grpc-timeout`). Convert it into a
`TIMEx::Deadline` on the way in so the rest of the service speaks one
language, and forward the remaining budget on outbound calls.

```ruby
require "grpc"
require "timex"

class WidgetService < Widgets::Service
  LOCAL_SLA = 0.8 # seconds

  def show(req, call)
    inbound = call.deadline ? TIMEx::Deadline.at_wall(call.deadline) : nil
    deadline = (inbound || TIMEx::Deadline.in(LOCAL_SLA)).min(LOCAL_SLA)

    TIMEx.deadline(deadline) do |d|
      widget = Widget.find_with_deadline(req.id, deadline: d.min(0.4))
      Inventory::Stub.new(host: ENV.fetch("INVENTORY_HOST"))
                     .check(req, deadline: Time.now + d.remaining)
      WidgetResponse.new(widget: widget)
    end
  rescue TIMEx::Expired
    raise GRPC::DeadlineExceeded
  end
end
```

`call.deadline` is a wall-clock `Time`; `at_wall` re-anchors it on the
server's monotonic clock so NTP adjustments can't move the goalposts.
`min(LOCAL_SLA)` keeps a chatty client from forcing this service past
its own latency budget, and the outbound stub gets the still-shrinking
remainder via gRPC's native `deadline:` argument.

See [Deadline](../docs/basics/deadline.md) for `at_wall` / `min`.
