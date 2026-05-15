# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Ractor do
  before { skip "Ractor not in this Ruby" unless defined?(Ractor) }

  describe ".call" do
    it "raises TIMEx::Error when the block captures non-shareable state" do
      local = Object.new
      expect do
        described_class.call(deadline: 2.0) { |_| local }
      end.to raise_error(TIMEx::Error, /shareable/)
    end
  end
end
