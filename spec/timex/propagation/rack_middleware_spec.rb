# frozen_string_literal: true

RSpec.describe TIMEx::Propagation::RackMiddleware do
  let(:inner_app) do
    lambda do |env|
      remaining = env["timex.deadline"]&.remaining_ms.to_s
      [200, { "content-type" => "text/plain" }, [remaining]]
    end
  end

  let(:env_with_deadline_header) { ->(value) { { "HTTP_X_TIMEX_DEADLINE" => value } } }

  describe "#call" do
    context "with a valid inbound deadline" do
      it "parses the header into env without echoing remaining by default" do
        app = described_class.new(inner_app)
        status, headers, _body = app.call(env_with_deadline_header.call(TIMEx::Deadline.in(2.0).to_header))
        expect(status).to eq(200)
        expect(headers).not_to include("x-timex-remaining-ms")
      end

      it "adds x-timex-remaining-ms when expose_remaining: true" do
        app = described_class.new(inner_app, expose_remaining: true)
        status, headers, _body = app.call(env_with_deadline_header.call(TIMEx::Deadline.in(2.0).to_header))
        expect(status).to eq(200)
        expect(headers).to include("x-timex-remaining-ms")
      end
    end

    context "when the inbound deadline is already exhausted" do
      it "returns 503 with expired-on-arrival" do
        app = described_class.new(inner_app)
        status, headers, _body = app.call(env_with_deadline_header.call("ms=0"))
        expect(status).to eq(503)
        expect(headers).to include("x-timex-outcome" => "expired-on-arrival")
      end
    end

    context "when the inbound header is malformed" do
      it "falls through to the inner app with a 200" do
        app = described_class.new(inner_app)
        status, _headers, _body = app.call(env_with_deadline_header.call("ms=1e308"))
        expect(status).to eq(200)
      end
    end

    context "with max_seconds" do
      it "clamps the parsed deadline before invoking the inner app" do
        app = described_class.new(inner_app, max_seconds: 1)
        _status, _headers, body = app.call(env_with_deadline_header.call(TIMEx::Deadline.in(60).to_header))
        expect(body.first.to_i).to be <= 1000
      end

      it "still enforces max_depth before clamping duration" do
        app = described_class.new(inner_app, max_seconds: 1, max_depth: 2)
        status, headers, _body = app.call(env_with_deadline_header.call("ms=60000;depth=10"))
        expect(status).to eq(503)
        expect(headers).to include("x-timex-outcome" => "max-depth-exceeded")
      end
    end

    context "with max_depth" do
      it "returns 503 when depth exceeds the configured cap" do
        app = described_class.new(inner_app, max_depth: 2)
        status, headers, _body = app.call(env_with_deadline_header.call("ms=100;depth=10"))
        expect(status).to eq(503)
        expect(headers).to include("x-timex-outcome" => "max-depth-exceeded")
      end
    end

    context "with default_seconds" do
      it "synthesizes a deadline when no header is present" do
        app = described_class.new(inner_app, default_seconds: 0.5)
        _status, _headers, body = app.call({})
        expect(body.first.to_i).to be <= 500
      end
    end

    it "rewrites HTTP_X_TIMEX_DEADLINE to the clamped wire form" do
      captured = nil
      passthrough = lambda do |env|
        captured = env["HTTP_X_TIMEX_DEADLINE"]
        [200, {}, []]
      end
      app = described_class.new(passthrough, max_seconds: 1)
      app.call(env_with_deadline_header.call(TIMEx::Deadline.in(60).to_header))
      expect(captured).to match(/\Ams=\d+/)
      expect(captured).to(satisfy { |s| TIMEx::Deadline.from_header(s).remaining <= 1.0 })
    end

    it "merges response headers without mutating frozen header hashes" do
      frozen_inner = ->(_env) { [200, { "content-type" => "text/plain" }.freeze, []] }
      app = described_class.new(frozen_inner, expose_remaining: true)
      status, headers, _body = app.call(env_with_deadline_header.call(TIMEx::Deadline.in(2.0).to_header))
      expect(status).to eq(200)
      expect(headers).to include("x-timex-remaining-ms")
    end

    context "with telemetry" do
      after { TIMEx::Telemetry.reset! }

      it "emits rack.deadline.rejected for expired-on-arrival" do
        events = []
        adapter = Class.new(TIMEx::Telemetry::Adapters::Base) do
          define_method(:emit) { |event:, payload:| events << [event, payload] }
        end.new
        TIMEx::Telemetry.adapter = adapter
        app = described_class.new(inner_app)
        app.call(env_with_deadline_header.call("ms=0"))
        expect(events.map(&:first)).to include("rack.deadline.rejected")
        expect(events.last[1][:reason]).to eq(:expired_on_arrival)
      end

      it "emits rack.deadline.rejected for max-depth-exceeded" do
        events = []
        adapter = Class.new(TIMEx::Telemetry::Adapters::Base) do
          define_method(:emit) { |event:, payload:| events << [event, payload] }
        end.new
        TIMEx::Telemetry.adapter = adapter
        app = described_class.new(inner_app, max_depth: 2)
        app.call(env_with_deadline_header.call("ms=100;depth=10"))
        expect(events.last[0]).to eq("rack.deadline.rejected")
        expect(events.last[1][:reason]).to eq(:max_depth_exceeded)
      end
    end
  end
end
