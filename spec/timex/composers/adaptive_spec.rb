# frozen_string_literal: true

RSpec.describe TIMEx::Composers::Adaptive do
  it "uses ceiling when no history" do
    composer = described_class.new(child: :cooperative, ceiling_ms: 500)
    expect(composer.call { :ok }).to eq(:ok)
  end

  it "records latency for future estimates" do
    store = described_class::InMemoryStore.new
    composer = described_class.new(child: :cooperative, history: store)
    3.times { composer.call { :ok } }
    expect(store.estimate_ms).to be_a(Numeric)
  end

  it "penalizes the estimator on timeout even with on_timeout: :return_nil" do
    store    = described_class::InMemoryStore.new
    composer = described_class.new(child: :cooperative, history: store,
      floor_ms: 1, ceiling_ms: 1)
    result = composer.call(on_timeout: :return_nil) do |d|
      sleep 0.05
      d.check!
      :nope
    end
    expect(result).to be_nil
    expect(store.estimate_ms).to be >= 1.0
  end

  it "applies on_timeout: :result for timeouts" do
    composer = described_class.new(child: :cooperative, floor_ms: 1, ceiling_ms: 1)
    result = composer.call(on_timeout: :result) do |d|
      sleep 0.05
      d.check!
      :nope
    end
    expect(result).to be_a(TIMEx::Result)
    expect(result).to be_timeout
  end

  it "caps the timeout-recorded penalty at ceiling_ms so the estimator can't run away" do
    store    = described_class::InMemoryStore.new
    composer = described_class.new(child: :cooperative, history: store,
      floor_ms: 1, ceiling_ms: 25, multiplier: 1.5)
    5.times do
      composer.call(on_timeout: :return_nil) do |d|
        sleep 0.05
        d.check!
      end
    end
    # Estimator uses `max(p99, ewma * 3)`; with recorded samples capped at
    # ceiling_ms (25) the estimate is bounded at `ceiling_ms * 3` (75)
    # regardless of how many timeouts occur — previously a wall-clock
    # `elapsed_ms` could be hundreds of ms per timeout and snowball.
    expect(store.estimate_ms).to be <= 75.0
  end

  describe "validation" do
    it "rejects non-positive multiplier" do
      expect { described_class.new(child: :cooperative, multiplier: 0) }
        .to raise_error(ArgumentError, /multiplier/)
    end

    it "rejects ceiling_ms < floor_ms" do
      expect { described_class.new(child: :cooperative, floor_ms: 100, ceiling_ms: 50) }
        .to raise_error(ArgumentError, /ceiling_ms/)
    end
  end

  describe described_class::InMemoryStore do
    it "tracks an upper bound near the true p99 for a uniform distribution" do
      store = described_class.new(window: 10_000, alpha: 0.99)
      samples = (1..1000).to_a.shuffle
      samples.each { |s| store.record(s.to_f) }
      # estimate = max(p99_estimate, ewma * 3). True p99 = 990; with high
      # alpha the EWMA tracks the most recent sample so the floor isn't
      # crazy high. Estimate must at least cover real p99 within slack.
      expect(store.estimate_ms).to be >= 900.0
    end

    it "is monotonic w.r.t. EWMA floor" do
      store = described_class.new(window: 10_000, alpha: 0.5)
      100.times { store.record(10.0) }
      # estimate >= ewma * 3 = 30
      expect(store.estimate_ms).to be >= 30.0
    end

    it "resets state when window is exceeded so old slow samples decay" do
      store = described_class.new(window: 50)
      50.times { store.record(1000.0) }
      50.times { store.record(1.0) }
      expect(store.estimate_ms).to be < 100.0
    end
  end
end
