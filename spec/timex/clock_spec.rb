# frozen_string_literal: true

RSpec.describe TIMEx::Clock do
  it "returns monotonically increasing nanoseconds" do
    a = described_class.monotonic_ns
    sleep 0.001
    expect(described_class.monotonic_ns).to be > a
  end

  describe "VirtualClock" do
    it "advances on demand without sleeping" do
      vc = described_class::VirtualClock.new(monotonic_ns: 0)
      vc.advance(2.5)
      expect(vc.monotonic_ns).to eq(2_500_000_000)
    end
  end

  it "swaps the active clock with .with" do
    vc = described_class::VirtualClock.new(monotonic_ns: 1_000)
    described_class.with(vc) do
      expect(described_class.monotonic_ns).to eq(1_000)
    end
    expect(described_class.monotonic_ns).not_to eq(1_000)
  end
end
