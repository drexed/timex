# frozen_string_literal: true

RSpec.describe TIMEx::CancellationToken do
  describe "#initialize" do
    it "starts uncancelled" do
      expect(described_class.new).not_to be_cancelled
    end
  end

  describe "#on_cancel / #cancel" do
    it "invokes observers with the reason when cancelled" do
      token = described_class.new
      fired = []
      token.on_cancel { |reason| fired << reason }
      token.cancel(reason: :timeout)
      expect(fired).to eq([:timeout])
      expect(token).to be_cancelled
    end

    context "when the token is already cancelled" do
      it "runs new observers immediately with the original reason" do
        token = described_class.new
        token.cancel(reason: :late)
        fired = []
        token.on_cancel { |reason| fired << reason }
        expect(fired).to eq([:late])
      end
    end

    it "is idempotent for cancel" do
      token = described_class.new
      expect(token.cancel(reason: :a)).to be(true)
      expect(token.cancel(reason: :b)).to be(false)
      expect(token.reason).to eq(:a)
    end
  end
end
