# frozen_string_literal: true

RSpec.describe TIMEx::Registry do
  describe ".known" do
    it "includes every built-in strategy key" do
      expect(described_class.known).to include(
        :cooperative,
        :io,
        :unsafe,
        :wakeup,
        :closeable,
        :subprocess
      )
    end

    it "includes :ractor when Ruby registers it" do
      expect(described_class.known).to include(:ractor) if defined?(Ractor)
    end
  end

  describe ".register" do
    it "rejects objects that do not respond to :call" do
      expect { described_class.register(:timex_registry_spec_bad, Object.new) }
        .to raise_error(ArgumentError, /must respond to :call/)
    end

    it "stores a callable under a symbol for fetch" do
      callable = proc { :registered_ok }
      described_class.register(:timex_registry_spec_echo, callable)
      expect(described_class.fetch(:timex_registry_spec_echo)).to be(callable)
    end
  end

  describe ".resolve" do
    it "returns nil for nil" do
      expect(described_class.resolve(nil)).to be_nil
    end

    it "returns the same callable for non-Symbol values" do
      c = proc {}
      expect(described_class.resolve(c)).to be(c)
    end

    it "fetches by Symbol" do
      expect(described_class.resolve(:cooperative)).to eq(TIMEx::Strategies::Cooperative)
    end
  end

  describe ".fetch" do
    context "when the name is not registered" do
      it "raises StrategyNotFoundError" do
        expect { described_class.fetch(:does_not_exist) }
          .to raise_error(TIMEx::StrategyNotFoundError)
      end
    end
  end

  describe ".select_default" do
    context "when default_selector returns a registered name" do
      after { described_class.default_selector { nil } }

      it "returns that strategy class" do
        described_class.default_selector { :unsafe }
        expect(described_class.select_default).to eq(TIMEx::Strategies::Unsafe)
      end
    end
  end
end
