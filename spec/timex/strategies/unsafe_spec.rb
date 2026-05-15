# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Unsafe do
  describe ".call" do
    context "when the block yields quickly" do
      it "returns the block value" do
        expect(described_class.call(deadline: 1.0) { :ok }).to eq(:ok)
      end
    end

    context "when the block blocks on sleep past the deadline" do
      it "raises TIMEx::Expired" do
        expect do
          described_class.call(deadline: 0.05) { sleep 5 }
        end.to raise_error(TIMEx::Expired)
      end
    end

    # Regression: the watcher must not raise into the target thread after the block
    # has already returned successfully.
    context "when the deadline is extremely tight" do
      it "still returns :ok without a delayed Expired" do
        100.times do
          expect(described_class.call(deadline: 0.005) { :ok }).to eq(:ok)
          sleep 0.01
        end
      end
    end
  end
end
