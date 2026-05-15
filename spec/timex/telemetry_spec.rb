# frozen_string_literal: true

RSpec.describe TIMEx::Telemetry do
  after { described_class.reset! }

  describe ".null_adapter?" do
    it "is true when the resolved adapter is Null" do
      expect(described_class.null_adapter?).to be(true)
    end

    it "is false when a custom adapter is set" do
      described_class.adapter = Class.new(TIMEx::Telemetry::Adapters::Base).new
      expect(described_class.null_adapter?).to be(false)
    end
  end

  describe ".instrument" do
    let(:adapter_class) do
      Class.new(TIMEx::Telemetry::Adapters::Base) do
        attr_reader :starts, :finishes

        def initialize
          super
          @starts = []
          @finishes = []
        end

        def start(event:, payload:)
          @starts << [event, payload.dup]
        end

        def finish(event:, payload:)
          @finishes << [event, payload.dup]
        end
      end
    end

    it "yields the payload hash and records ok outcome with elapsed_ms" do
      adapter = adapter_class.new
      described_class.adapter = adapter
      out = nil
      result = described_class.instrument(event: "spec.op", foo: 1) do |payload|
        out = payload
        :done
      end
      expect(result).to eq(:done)
      expect(out[:outcome]).to eq(:ok)
      expect(out[:elapsed_ms]).to be_a(Float)
      expect(adapter.finishes.last[1][:outcome]).to eq(:ok)
    end

    it "marks timeout outcome for Expired without setting error_class" do
      adapter = adapter_class.new
      described_class.adapter = adapter
      expired = TIMEx::Expired.new("boom", strategy: :cooperative)
      expect do
        described_class.instrument(event: "spec.timeout") { |_p| raise expired }
      end.to raise_error(TIMEx::Expired)
      expect(adapter.finishes.last[1][:outcome]).to eq(:timeout)
      expect(adapter.finishes.last[1]).not_to have_key(:error_class)
    end

    it "marks error outcome for StandardError" do
      adapter = adapter_class.new
      described_class.adapter = adapter
      expect do
        described_class.instrument(event: "spec.err") { |_p| raise "nope" }
      end.to raise_error(RuntimeError)
      expect(adapter.finishes.last[1][:outcome]).to eq(:error)
      expect(adapter.finishes.last[1][:error_class]).to eq("RuntimeError")
    end
  end

  describe ".strict" do
    it "re-raises adapter errors from start" do
      described_class.strict = true
      bad = Class.new(TIMEx::Telemetry::Adapters::Base) do
        def start(**)
          raise "adapter boom"
        end
      end.new
      described_class.adapter = bad
      expect do
        described_class.instrument(event: "x") { :nope }
      end.to raise_error(RuntimeError, "adapter boom")
    ensure
      described_class.strict = false
    end
  end

  describe ".emit" do
    it "invokes start and finish on a non-null adapter" do
      adapter = Class.new(TIMEx::Telemetry::Adapters::Base) do
        attr_reader :events

        def initialize
          super
          @events = []
        end

        def start(event:, payload:)
          @events << [:start, event, payload.dup]
        end

        def finish(event:, payload:)
          @events << [:finish, event, payload.dup]
        end
      end.new
      described_class.adapter = adapter
      described_class.emit(event: :one_shot, k: 1)
      expect(adapter.events.map(&:first)).to eq(%i[start finish])
      expect(adapter.events.first[1]).to eq(:one_shot)
    end
  end

  describe ".reset!" do
    it "clears explicit adapter and strict mode" do
      described_class.adapter = Class.new(TIMEx::Telemetry::Adapters::Base).new
      described_class.strict = true
      described_class.reset!
      expect(described_class.null_adapter?).to be(true)
      expect(described_class.strict).to be(false)
    end
  end
end
