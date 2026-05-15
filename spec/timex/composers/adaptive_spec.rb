# frozen_string_literal: true

RSpec.describe TIMEx::Composers::Adaptive do
  describe "#call" do
    context "with no history" do
      it "still executes the child using the ceiling budget" do
        composer = described_class.new(child: :cooperative, ceiling_ms: 500)
        expect(composer.call { :ok }).to eq(:ok)
      end
    end

    context "with an InMemoryStore history" do
      it "records samples so estimate_ms becomes numeric" do
        store = described_class::InMemoryStore.new
        composer = described_class.new(child: :cooperative, history: store)
        3.times { composer.call { :ok } }
        expect(store.estimate_ms).to be_a(Numeric)
      end

      it "penalizes the estimator on timeout even when on_timeout is :return_nil" do
        store = described_class::InMemoryStore.new
        composer = described_class.new(
          child: :cooperative,
          history: store,
          floor_ms: 1,
          ceiling_ms: 1
        )
        result = composer.call(on_timeout: :return_nil) do |d|
          sleep 0.05
          d.check!
          :nope
        end
        expect(result).to be_nil
        expect(store.estimate_ms).to be >= 1.0
      end

      it "returns a timeout Result when on_timeout is :result" do
        composer = described_class.new(child: :cooperative, floor_ms: 1, ceiling_ms: 1)
        result = composer.call(on_timeout: :result) do |d|
          sleep 0.05
          d.check!
          :nope
        end
        expect(result).to be_a(TIMEx::Result).and(be_timeout)
      end

      it "caps recorded timeout latency at ceiling_ms so estimates stay bounded" do
        store = described_class::InMemoryStore.new
        composer = described_class.new(
          child: :cooperative,
          history: store,
          floor_ms: 1,
          ceiling_ms: 25,
          multiplier: 1.5
        )
        5.times do
          composer.call(on_timeout: :return_nil) do |d|
            sleep 0.05
            d.check!
          end
        end
        # Estimator uses max(p99, ewma * 3); samples are capped at ceiling_ms (25),
        # so the tail cannot snowball from wall-clock elapsed_ms alone.
        expect(store.estimate_ms).to be <= 75.0
      end
    end
  end

  describe "validation" do
    it "rejects a non-positive multiplier" do
      expect { described_class.new(child: :cooperative, multiplier: 0) }
        .to raise_error(ArgumentError, /multiplier/)
    end

    it "rejects ceiling_ms below floor_ms" do
      expect { described_class.new(child: :cooperative, floor_ms: 100, ceiling_ms: 50) }
        .to raise_error(ArgumentError, /ceiling_ms/)
    end
  end

  describe TIMEx::Composers::Adaptive::InMemoryStore do
    it "tracks an upper bound near the empirical p99 for a uniform sample" do
      store = described_class.new(window: 10_000, alpha: 0.99)
      samples = (1..1000).to_a.shuffle
      samples.each { |s| store.record(s.to_f) }
      expect(store.estimate_ms).to be >= 900.0
    end

    it "respects the EWMA * multiplier floor" do
      store = described_class.new(window: 10_000, alpha: 0.5)
      100.times { store.record(10.0) }
      expect(store.estimate_ms).to be >= 30.0
    end

    it "decays old samples once the ring buffer window is exceeded" do
      store = described_class.new(window: 50)
      50.times { store.record(1000.0) }
      50.times { store.record(1.0) }
      expect(store.estimate_ms).to be < 100.0
    end
  end
end
