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
