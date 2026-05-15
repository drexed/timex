# frozen_string_literal: true

RSpec.describe TIMEx::Result do
  describe "#value!" do
    context "with an ok result" do
      it "returns the wrapped value" do
        expect(described_class.ok(42).value!).to eq(42)
      end
    end

    context "with an error result" do
      it "raises the captured exception instance" do
        err = RuntimeError.new("boom")
        expect { described_class.error(err).value! }.to raise_error(err)
      end
    end

    context "with a synthetic timeout result" do
      it "raises TIMEx::Expired" do
        result = described_class.timeout(strategy: :cooperative, elapsed_ms: 5.0)
        expect { result.value! }.to raise_error(TIMEx::Expired)
      end
    end

    context "with a timeout result built from a prior Expired" do
      it "re-raises that exception and preserves deadline metadata" do
        original = TIMEx::Expired.new(
          "IO read deadline expired",
          strategy: :io,
          deadline_ms: 250,
          elapsed_ms: 251
        )
        result = described_class.timeout(strategy: :io, expired: original)
        expect { result.value! }.to raise_error(original)
        expect(result.deadline_ms).to eq(250)
        expect(result.elapsed_ms).to eq(251)
      end
    end
  end

  describe ".error" do
    context "when the argument is not an Exception" do
      it "raises ArgumentError" do
        expect { described_class.error("oops") }.to raise_error(ArgumentError, /Exception/)
        expect { described_class.error(nil) }.to raise_error(ArgumentError, /Exception/)
      end
    end
  end

  describe "#value_or" do
    context "with an ok result" do
      it "returns the wrapped value and ignores the default" do
        expect(described_class.ok(42).value_or(:fallback)).to eq(42)
      end
    end

    context "with a non-ok result and no block" do
      it "returns the fallback" do
        result = described_class.timeout(strategy: :cooperative)
        expect(result.value_or(:fallback)).to eq(:fallback)
      end
    end

    context "with a block" do
      it "yields the result to the block" do
        result = described_class.error(RuntimeError.new("x"))
        expect(result.value_or { |r| r.error.message }).to eq("x")
      end
    end
  end

  describe "pattern matching" do
    it "supports array deconstruction" do
      result = described_class.ok(1)
      case result
      in [:ok, value, _]
        expect(value).to eq(1)
      end
    end

    it "supports hash deconstruction" do
      result = described_class.ok(1, strategy: :cooperative)
      case result
      in { outcome: :ok, value:, strategy: }
        expect(value).to eq(1)
        expect(strategy).to eq(:cooperative)
      end
    end
  end
end
