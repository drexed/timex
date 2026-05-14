# frozen_string_literal: true

RSpec.describe TIMEx::Propagation::RackMiddleware do
  let(:inner) do
    ->(env) { [200, { "content-type" => "text/plain" }, [env["timex.deadline"]&.remaining_ms.to_s]] }
  end

  def env_for(value)
    { "HTTP_X_TIMEX_DEADLINE" => value }
  end

  describe "#call" do
    it "parses inbound deadline into env" do
      app = described_class.new(inner)
      status, headers, _body = app.call(env_for(TIMEx::Deadline.in(2.0).to_header))
      expect(status).to eq(200)
      expect(headers).not_to include("x-timex-remaining-ms")
    end

    it "exposes x-timex-remaining-ms when expose_remaining: true" do
      app = described_class.new(inner, expose_remaining: true)
      status, headers, _body = app.call(env_for(TIMEx::Deadline.in(2.0).to_header))
      expect(status).to eq(200)
      expect(headers).to include("x-timex-remaining-ms")
    end

    it "returns 503 when deadline already expired" do
      app = described_class.new(inner)
      status, headers, _body = app.call(env_for("ms=0"))
      expect(status).to eq(503)
      expect(headers).to include("x-timex-outcome" => "expired-on-arrival")
    end

    it "swallows malformed inbound headers without crashing" do
      app = described_class.new(inner)
      status, _headers, _body = app.call(env_for("ms=1e308"))
      expect(status).to eq(200)
    end

    it "clamps inbound deadline to max_seconds" do
      app = described_class.new(inner, max_seconds: 1)
      env = env_for(TIMEx::Deadline.in(60).to_header)
      _, _, body = app.call(env)
      expect(body.first.to_i).to be <= 1000
    end

    it "rejects requests exceeding max_depth" do
      app = described_class.new(inner, max_depth: 2)
      env = env_for("ms=100;depth=10")
      status, headers, _body = app.call(env)
      expect(status).to eq(503)
      expect(headers).to include("x-timex-outcome" => "max-depth-exceeded")
    end

    it "enforces max_depth on the inbound deadline before max_seconds clamp" do
      app = described_class.new(inner, max_seconds: 1, max_depth: 2)
      status, headers, _body = app.call(env_for("ms=60000;depth=10"))
      expect(status).to eq(503)
      expect(headers).to include("x-timex-outcome" => "max-depth-exceeded")
    end

    it "applies default_seconds when no header is present" do
      app = described_class.new(inner, default_seconds: 0.5)
      _, _, body = app.call({})
      expect(body.first.to_i).to be <= 500
    end

    it "rewrites raw HTTP_X_TIMEX_DEADLINE to the clamped value" do
      seen = nil
      passthrough = lambda do |env|
        seen = env["HTTP_X_TIMEX_DEADLINE"]
        [200, {}, []]
      end
      app = described_class.new(passthrough, max_seconds: 1)
      app.call(env_for(TIMEx::Deadline.in(60).to_header))
      expect(seen).to match(/\Ams=\d+/)
      expect(seen).to(satisfy { |s| TIMEx::Deadline.from_header(s).remaining <= 1.0 })
    end

    it "supports frozen response header hashes when exposing remaining" do
      frozen_inner = ->(_env) { [200, { "content-type" => "text/plain" }.freeze, []] }
      app = described_class.new(frozen_inner, expose_remaining: true)
      status, headers, _body = app.call(env_for(TIMEx::Deadline.in(2.0).to_header))
      expect(status).to eq(200)
      expect(headers).to include("x-timex-remaining-ms")
    end

    it "emits telemetry on expired-on-arrival" do
      events  = []
      adapter = Class.new(TIMEx::Telemetry::Adapters::Base) do
        define_method(:emit) { |event:, payload:| events << [event, payload] }
      end.new
      TIMEx::Telemetry.adapter = adapter
      app = described_class.new(inner)
      app.call(env_for("ms=0"))
      expect(events.map(&:first)).to include("rack.deadline.rejected")
      expect(events.last[1][:reason]).to eq(:expired_on_arrival)
    ensure
      TIMEx::Telemetry.reset!
    end

    it "emits telemetry on max-depth-exceeded" do
      events  = []
      adapter = Class.new(TIMEx::Telemetry::Adapters::Base) do
        define_method(:emit) { |event:, payload:| events << [event, payload] }
      end.new
      TIMEx::Telemetry.adapter = adapter
      app = described_class.new(inner, max_depth: 2)
      app.call(env_for("ms=100;depth=10"))
      expect(events.last[0]).to eq("rack.deadline.rejected")
      expect(events.last[1][:reason]).to eq(:max_depth_exceeded)
    ensure
      TIMEx::Telemetry.reset!
    end
  end
end
