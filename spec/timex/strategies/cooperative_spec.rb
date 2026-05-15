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

    context "with on_timeout: :raise_standard" do
      it "raises TimeoutError with Expired on #original" do
        err = nil
        begin
          described_class.call(deadline: 0.001, on_timeout: :raise_standard) do |d|
            sleep 0.01
            d.check!
          end
        rescue TIMEx::TimeoutError => e
          err = e
        end
        expect(err).to be_a(TIMEx::TimeoutError)
        expect(err.original).to be_a(TIMEx::Expired)
      end
    end

    context "with on_timeout: :result" do
      it "returns a timeout Result" do
        result = described_class.call(deadline: 0.001, on_timeout: :result) do |d|
          sleep 0.01
          d.check!
        end
        expect(result).to be_a(TIMEx::Result).and(have_attributes(outcome: :timeout))
      end
    end

    context "with an unknown on_timeout symbol after expiry" do
      it "raises ArgumentError from timeout dispatch" do
        expect do
          described_class.call(deadline: 0.001, on_timeout: :not_a_mode) do |d|
            sleep 0.01
            d.check!
          end
        end.to raise_error(ArgumentError, /unknown on_timeout/)
      end
    end
  end
end
