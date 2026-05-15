# frozen_string_literal: true

RSpec.describe TIMEx::Composers::TwoPhase do
  describe "#call" do
    context "when the cooperative phase succeeds" do
      it "returns the block value without touching the hard strategy" do
        composer = described_class.new(soft: :cooperative, hard: :unsafe, grace: 0.5, idempotent: true)
        expect(composer.call(deadline: 1.0) { :ok }).to eq(:ok)
      end
    end

    context "when the soft strategy cannot preempt (sleep)" do
      it "hands off to the hard strategy after grace" do
        composer = described_class.new(soft: :cooperative, hard: :unsafe, grace: 1.0, idempotent: true)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect do
          composer.call(deadline: 0.05) { sleep 30 }
        end.to raise_error(TIMEx::Expired)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(elapsed).to be < 5.0
      end
    end

    context "when the parent deadline is tighter than hard_deadline" do
      it "clamps the hard phase so the outer budget is respected" do
        composer = described_class.new(
          soft: :cooperative,
          hard: :unsafe,
          grace: 0.05,
          hard_deadline: 5.0,
          idempotent: true
        )
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect do
          composer.call(deadline: 0.05) { sleep 10 }
        end.to raise_error(TIMEx::Expired)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(elapsed).to be < 1.0
      end
    end
  end

  describe ".new" do
    it "requires idempotent: true" do
      expect { described_class.new(soft: :cooperative, hard: :unsafe) }
        .to raise_error(ArgumentError, /idempotent/)
    end

    it "rejects a negative grace" do
      expect do
        described_class.new(soft: :cooperative, hard: :unsafe, grace: -1, idempotent: true)
      end.to raise_error(ArgumentError, /grace/)
    end

    it "rejects a non-positive hard_deadline" do
      expect do
        described_class.new(soft: :cooperative, hard: :unsafe, hard_deadline: 0, idempotent: true)
      end.to raise_error(ArgumentError, /hard_deadline/)
    end
  end
end
