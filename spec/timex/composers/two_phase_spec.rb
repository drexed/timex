# frozen_string_literal: true

RSpec.describe TIMEx::Composers::TwoPhase do
  it "returns the block value when soft phase succeeds" do
    composer = described_class.new(soft: :cooperative, hard: :unsafe, grace: 0.5, idempotent: true)
    expect(composer.call(deadline: 1.0) { :ok }).to eq(:ok)
  end

  it "escalates to hard strategy when soft is ignored" do
    # Soft (cooperative) cannot interrupt sleep; hard (unsafe) can.
    composer = described_class.new(soft: :cooperative, hard: :unsafe, grace: 1.0, idempotent: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      composer.call(deadline: 0.05) { sleep 30 }
    rescue TIMEx::Expired
      # expected
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 5.0
  end

  it "rejects construction without an idempotency acknowledgement" do
    expect { described_class.new(soft: :cooperative, hard: :unsafe) }
      .to raise_error(ArgumentError, /idempotent/)
  end

  it "rejects negative grace and non-positive hard_deadline" do
    expect do
      described_class.new(soft: :cooperative, hard: :unsafe, grace: -1, idempotent: true)
    end.to raise_error(ArgumentError, /grace/)

    expect do
      described_class.new(soft: :cooperative, hard: :unsafe, hard_deadline: 0, idempotent: true)
    end.to raise_error(ArgumentError, /hard_deadline/)
  end

  it "clamps the hard-phase budget to the parent deadline" do
    # Parent deadline 50ms; if the hard budget (5s) were not clamped, the
    # block could run for the full 5s. Capping at the parent ensures we
    # respect the caller's contract.
    composer = described_class.new(soft: :cooperative, hard: :unsafe,
      grace: 0.05, hard_deadline: 5.0, idempotent: true)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      composer.call(deadline: 0.05) { sleep 10 }
    rescue TIMEx::Expired
      # expected
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(elapsed).to be < 1.0
  end
end
