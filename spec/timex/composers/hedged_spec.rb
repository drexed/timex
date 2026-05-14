# frozen_string_literal: true

RSpec.describe TIMEx::Composers::Hedged do
  it "requires idempotent: true" do
    expect do
      described_class.new(after: 0.1, child: :cooperative)
    end.to raise_error(ArgumentError)
  end

  it "returns the first successful result" do
    composer = described_class.new(after: 0.05, child: :cooperative, max: 3, idempotent: true)
    result = composer.call(deadline: 1.0) { :winner }
    expect(result).to eq(:winner)
  end

  # Regression: when the await pop returns nil (deadline elapsed), still drain
  # the queue for any late-arriving result before declaring :timeout.
  it "drains queued results when the deadline elapses during await" do
    composer = described_class.new(after: 0.001, child: :cooperative, max: 1, idempotent: true)
    deadline = TIMEx::Deadline.in(0.0001)
    queue    = Queue.new
    queue << %i[ok late_winner]
    expect(composer.send(:await_outcome, queue, 1, deadline)).to eq(%i[ok late_winner])
  end
end
