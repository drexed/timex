# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Cooperative do
  describe ".call" do
    context "when the block finishes before the deadline" do
      it "returns the block value" do
        expect(described_class.call(deadline: 1.0) { :ok }).to eq(:ok)
      end
    end

    context "when check! runs after the budget is exhausted" do
      it "raises TIMEx::Expired" do
        expect do
          described_class.call(deadline: 0.001) do |d|
            sleep 0.01
            d.check!
          end
        end.to raise_error(TIMEx::Expired)
      end
    end

    context "with on_timeout: :return_nil" do
      it "returns nil instead of raising" do
        result = described_class.call(deadline: 0.001, on_timeout: :return_nil) do |d|
          sleep 0.01
          d.check!
        end
        expect(result).to be_nil
      end
    end
  end
end
