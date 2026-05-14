# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Closeable do
  it "closes the resource when the deadline expires and raises Expired" do
    r, w = IO.pipe
    strategy = described_class.new(resource: r)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect do
      strategy.call(deadline: 0.05) { |io, _d| io.read }
    end.to raise_error(TIMEx::Expired)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 1.0
    expect(r).to be_closed
  ensure
    w.close unless w.closed?
  end

  it "is constructible via Base.call with resource: keyword" do
    r, w = IO.pipe
    expect do
      described_class.call(deadline: 0.05, resource: r) { |io, _d| io.read }
    end.to raise_error(TIMEx::Expired)
  ensure
    w.close unless w.closed?
  end
end
