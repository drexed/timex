# frozen_string_literal: true

RSpec.describe TIMEx::Configuration do
  describe "validation" do
    it "rejects non-symbol/strategy default_strategy" do
      cfg = described_class.new
      expect { cfg.default_strategy = 123 }.to raise_error(TIMEx::ConfigurationError)
      cfg.default_strategy = :cooperative
      expect(cfg.default_strategy).to eq(:cooperative)
    end

    it "rejects unknown default_on_timeout symbols" do
      cfg = described_class.new
      expect { cfg.default_on_timeout = :bogus }.to raise_error(TIMEx::ConfigurationError)
      cfg.default_on_timeout = :result
      expect(cfg.default_on_timeout).to eq(:result)
      cfg.default_on_timeout = ->(_) {}
      expect(cfg.default_on_timeout).to be_a(Proc)
    end

    it "rejects non-positive auto_check_interval" do
      cfg = described_class.new
      expect { cfg.auto_check_interval = 0 }.to raise_error(TIMEx::ConfigurationError)
      expect { cfg.auto_check_interval = -1 }.to raise_error(TIMEx::ConfigurationError)
      cfg.auto_check_interval = 500
      expect(cfg.auto_check_interval).to eq(500)
    end

    it "rejects non-boolean auto_check_default" do
      cfg = described_class.new
      expect { cfg.auto_check_default = "yes" }.to raise_error(TIMEx::ConfigurationError)
      cfg.auto_check_default = true
      expect(cfg.auto_check_default).to be(true)
    end

    it "rejects telemetry_adapter without :emit" do
      cfg = described_class.new
      expect { cfg.telemetry_adapter = Object.new }.to raise_error(TIMEx::ConfigurationError)
      cfg.telemetry_adapter = nil
      expect(cfg.telemetry_adapter).to be_nil
    end

    it "rejects negative skew_tolerance_ms" do
      cfg = described_class.new
      expect { cfg.skew_tolerance_ms = -1 }.to raise_error(TIMEx::ConfigurationError)
      cfg.skew_tolerance_ms = 100
      expect(cfg.skew_tolerance_ms).to eq(100)
    end

    it "rejects a clock missing required methods" do
      cfg = described_class.new
      expect { cfg.clock = Object.new }.to raise_error(TIMEx::ConfigurationError)
    end
  end

  describe ".configure" do
    it "swaps configuration atomically so failures don't leave a half-written instance" do
      original = TIMEx.config.default_strategy
      expect do
        TIMEx.configure do |c|
          c.skew_tolerance_ms = 50
          c.default_strategy = 123 # raises, transaction must roll back
        end
      end.to raise_error(TIMEx::ConfigurationError)
      expect(TIMEx.config.default_strategy).to eq(original)
      expect(TIMEx.config.skew_tolerance_ms).to eq(TIMEx::Deadline::DEFAULT_SKEW_TOLERANCE_MS)
    end

    it "does not hold the config mutex while yielding (recursive configure is safe)" do
      # Previously the block ran inside the mutex, so a nested `configure` from
      # a telemetry adapter init or other callback would deadlock.
      TIMEx.configure do |c|
        c.skew_tolerance_ms = 100
        TIMEx.configure { |inner| inner.auto_check_default = true }
      end
      expect(TIMEx.config.skew_tolerance_ms).to eq(100)
      expect(TIMEx.config.auto_check_default).to be(true)
    end
  end
end
