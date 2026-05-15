# frozen_string_literal: true

RSpec.describe TIMEx::Clock do
  describe ".monotonic_ns" do
    it "increases across wall time" do
      before_ns = described_class.monotonic_ns
      sleep 0.001
      expect(described_class.monotonic_ns).to be > before_ns
    end
  end

  describe ".with" do
    it "scopes monotonic reads to the given clock for the duration of the block" do
      virtual = described_class::VirtualClock.new(monotonic_ns: 1_000)
      described_class.with(virtual) do
        expect(described_class.monotonic_ns).to eq(1_000)
      end
      expect(described_class.monotonic_ns).not_to eq(1_000)
    end
  end

  describe "VirtualClock" do
    describe "#advance" do
      it "adds seconds to the stored monotonic counter without sleeping" do
        clock = described_class::VirtualClock.new(monotonic_ns: 0)
        clock.advance(2.5)
        expect(clock.monotonic_ns).to eq(2_500_000_000)
      end
    end
  end
end
