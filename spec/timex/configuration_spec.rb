# frozen_string_literal: true

RSpec.describe TIMEx::Configuration do
  subject(:config) { described_class.new }

  describe "validation" do
    context "when assigning default_strategy" do
      it "rejects non-strategy values" do
        expect { config.default_strategy = 123 }.to raise_error(TIMEx::ConfigurationError)
        config.default_strategy = :cooperative
        expect(config.default_strategy).to eq(:cooperative)
      end
    end

    context "when assigning default_on_timeout" do
      it "rejects unknown symbols but accepts :result and Procs" do
        expect { config.default_on_timeout = :bogus }.to raise_error(TIMEx::ConfigurationError)
        config.default_on_timeout = :result
        expect(config.default_on_timeout).to eq(:result)
        config.default_on_timeout = ->(_) {}
        expect(config.default_on_timeout).to be_a(Proc)
      end
    end

    context "when assigning auto_check_interval" do
      it "rejects non-positive values" do
        expect { config.auto_check_interval = 0 }.to raise_error(TIMEx::ConfigurationError)
        expect { config.auto_check_interval = -1 }.to raise_error(TIMEx::ConfigurationError)
        config.auto_check_interval = 500
        expect(config.auto_check_interval).to eq(500)
      end
    end

    context "when assigning auto_check_default" do
      it "rejects non-boolean values" do
        expect { config.auto_check_default = "yes" }.to raise_error(TIMEx::ConfigurationError)
        config.auto_check_default = true
        expect(config.auto_check_default).to be(true)
      end
    end

    context "when assigning telemetry_adapter" do
      it "rejects objects that do not implement :emit" do
        expect { config.telemetry_adapter = Object.new }.to raise_error(TIMEx::ConfigurationError)
        config.telemetry_adapter = nil
        expect(config.telemetry_adapter).to be_nil
      end
    end

    context "when assigning skew_tolerance_ms" do
      it "rejects negative values" do
        expect { config.skew_tolerance_ms = -1 }.to raise_error(TIMEx::ConfigurationError)
        config.skew_tolerance_ms = 100
        expect(config.skew_tolerance_ms).to eq(100)
      end
    end

    context "when assigning clock" do
      it "rejects objects missing the monotonic interface" do
        expect { config.clock = Object.new }.to raise_error(TIMEx::ConfigurationError)
      end
    end
  end

  describe ".configure" do
    context "when the block raises mid-mutation" do
      it "rolls back so TIMEx.config is unchanged" do
        original = TIMEx.config.default_strategy
        expect do
          TIMEx.configure do |c|
            c.skew_tolerance_ms = 50
            c.default_strategy = 123 # raises; swap must roll back
          end
        end.to raise_error(TIMEx::ConfigurationError)
        expect(TIMEx.config.default_strategy).to eq(original)
        expect(TIMEx.config.skew_tolerance_ms).to eq(TIMEx::Deadline::DEFAULT_SKEW_TOLERANCE_MS)
      end
    end

    context "when configure is nested" do
      it "does not hold the mutex across the inner block (avoids deadlock)" do
        TIMEx.configure do |c|
          c.skew_tolerance_ms = 100
          TIMEx.configure { |inner| inner.auto_check_default = true }
        end
        expect(TIMEx.config.skew_tolerance_ms).to eq(100)
        expect(TIMEx.config.auto_check_default).to be(true)
      end
    end
  end
end
