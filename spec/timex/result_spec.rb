# frozen_string_literal: true

RSpec.describe TIMEx::Result do
  describe "#value!" do
    it "returns the value when ok" do
      expect(described_class.ok(42).value!).to eq(42)
    end

    it "raises the captured error when error" do
      err = RuntimeError.new("boom")
      expect { described_class.error(err).value! }.to raise_error(err)
    end

    it "raises Expired when timeout" do
      result = described_class.timeout(strategy: :cooperative, elapsed_ms: 5.0)
      expect { result.value! }.to raise_error(TIMEx::Expired)
    end

    it "re-raises the original Expired carried via .timeout(expired:)" do
      original = TIMEx::Expired.new("IO read deadline expired", strategy: :io,
        deadline_ms: 250, elapsed_ms: 251)
      result = described_class.timeout(strategy: :io, expired: original)
      expect { result.value! }.to raise_error(original)
      expect(result.deadline_ms).to eq(250)
      expect(result.elapsed_ms).to eq(251)
    end
  end

  describe ".error" do
    it "rejects non-Exception arguments" do
      expect { described_class.error("oops") }.to raise_error(ArgumentError, /Exception/)
      expect { described_class.error(nil) }.to raise_error(ArgumentError, /Exception/)
    end
  end

  describe "#value_or" do
    it "returns the value when ok" do
      expect(described_class.ok(42).value_or(:fallback)).to eq(42)
    end

    it "returns the default for non-ok results" do
      expect(described_class.timeout(strategy: :cooperative).value_or(:fallback)).to eq(:fallback)
    end

    it "yields with the result when a block is given" do
      result = described_class.error(RuntimeError.new("x"))
      expect(result.value_or { |r| r.error.message }).to eq("x")
    end
  end

  describe "pattern-matching" do
    it "supports deconstruction" do
      result = described_class.ok(1)
      case result
      in [:ok, value, _]
        expect(value).to eq(1)
      end
    end

    it "supports keyword deconstruction" do
      result = described_class.ok(1, strategy: :cooperative)
      case result
      in { outcome: :ok, value:, strategy: }
        expect(value).to eq(1)
        expect(strategy).to eq(:cooperative)
      end
    end
  end
end
