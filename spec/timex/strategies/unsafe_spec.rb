# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Unsafe do
  it "interrupts a sleeping block" do
    expect do
      described_class.call(deadline: 0.05) { sleep 5 }
    end.to raise_error(TIMEx::Expired)
  end

  it "returns the block value when within deadline" do
    expect(described_class.call(deadline: 1.0) { :ok }).to eq(:ok)
  end

  # Race regression: the watcher must not raise into the target thread after
  # the block has already returned successfully.
  it "does not raise into the caller after the block returns" do
    100.times do
      result = described_class.call(deadline: 0.005) { :ok }
      expect(result).to eq(:ok)
      sleep 0.01 # give a stray watcher time to fire
    end
  end
end
