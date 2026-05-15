# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Subprocess do
  describe ".call" do
    before { skip "fork unavailable" unless Process.respond_to?(:fork) }

    it "returns the child block value" do
      expect(described_class.call(deadline: 5.0) { 21 + 21 }).to eq(42)
    end

    it "terminates the child and raises TIMEx::Expired when it overruns" do
      expect do
        described_class.call(deadline: 0.1) { sleep 30 }
      end.to raise_error(TIMEx::Expired)
    end

    it "re-raises errors raised in the child" do
      expect do
        described_class.call(deadline: 5.0) { raise "boom" }
      end.to raise_error(StandardError, /boom/)
    end

    # Caller deadline must not be consumed by strategy cleanup (TERM, kill_after, KILL, waitpid).
    it "returns to the parent thread quickly after a child timeout" do
      strategy = described_class.new(kill_after: 2.0)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        strategy.call(deadline: 0.05) { sleep 30 }
      end.to raise_error(TIMEx::Expired)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < 1.0
    end
  end

  describe ".new" do
    it "rejects a negative kill_after" do
      expect { described_class.new(kill_after: -1) }.to raise_error(ArgumentError, /kill_after/)
    end
  end
end
