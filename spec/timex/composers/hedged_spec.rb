# frozen_string_literal: true

RSpec.describe TIMEx::Composers::Hedged do
  describe ".new" do
    context "without idempotent: true" do
      it "raises ArgumentError" do
        expect do
          described_class.new(after: 0.1, child: :cooperative)
        end.to raise_error(ArgumentError, /idempotent: true/)
      end
    end
  end

  describe "#call" do
    it "returns the first successful child result" do
      composer = described_class.new(after: 0.05, child: :cooperative, max: 3, idempotent: true)
      expect(composer.call(deadline: 1.0) { :winner }).to eq(:winner)
    end
  end

  describe "#await_outcome (regression)" do
    it "drains queued results when the deadline elapses during await" do
      composer = described_class.new(after: 0.001, child: :cooperative, max: 1, idempotent: true)
      deadline = TIMEx::Deadline.in(0.0001)
      queue = Queue.new
      queue << %i[ok late_winner]
      expect(composer.send(:await_outcome, queue, 1, deadline)).to eq(%i[ok late_winner])
    end
  end
end
