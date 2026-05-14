# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Subprocess do
  it "returns the block value from the child" do
    skip "fork unavailable" unless Process.respond_to?(:fork)

    expect(described_class.call(deadline: 5.0) { 21 + 21 }).to eq(42)
  end

  it "kills the child on deadline expiry" do
    skip "fork unavailable" unless Process.respond_to?(:fork)

    expect do
      described_class.call(deadline: 0.1) { sleep 30 }
    end.to raise_error(TIMEx::Expired)
  end

  it "propagates errors raised in the child" do
    skip "fork unavailable" unless Process.respond_to?(:fork)

    expect do
      described_class.call(deadline: 5.0) { raise "boom" }
    end.to raise_error(StandardError, /boom/)
  end

  # Caller deadline budget should not be blown by the strategy's own cleanup
  # (TERM + kill_after + KILL + waitpid). Reaping is detached.
  it "returns control to the caller within the deadline window on timeout" do
    skip "fork unavailable" unless Process.respond_to?(:fork)

    strategy = described_class.new(kill_after: 2.0)
    started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect do
      strategy.call(deadline: 0.05) { sleep 30 }
    end.to raise_error(TIMEx::Expired)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 1.0
  end

  it "rejects a negative kill_after at construction" do
    expect { described_class.new(kill_after: -1) }.to raise_error(ArgumentError, /kill_after/)
  end
end
