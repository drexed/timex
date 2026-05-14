# frozen_string_literal: true

RSpec.describe TIMEx::CancellationToken do
  it "starts uncancelled" do
    expect(described_class.new).not_to be_cancelled
  end

  it "fires registered observers on cancel" do
    t = described_class.new
    fired = []
    t.on_cancel { |reason| fired << reason }
    t.cancel(reason: :timeout)
    expect(fired).to eq([:timeout])
    expect(t).to be_cancelled
  end

  it "fires observers added after cancellation immediately" do
    t = described_class.new
    t.cancel(reason: :late)
    fired = []
    t.on_cancel { |reason| fired << reason }
    expect(fired).to eq([:late])
  end

  it "is idempotent" do
    t = described_class.new
    expect(t.cancel(reason: :a)).to be true
    expect(t.cancel(reason: :b)).to be false
    expect(t.reason).to eq(:a)
  end
end
