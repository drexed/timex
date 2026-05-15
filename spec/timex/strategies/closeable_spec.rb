# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Closeable do
  describe "#call" do
    it "closes the wrapped IO and raises TIMEx::Expired when the deadline hits" do
      reader, writer = IO.pipe
      strategy = described_class.new(resource: reader)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        strategy.call(deadline: 0.05) { |io, _d| io.read }
      end.to raise_error(TIMEx::Expired)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < 1.0
      expect(reader).to be_closed
    ensure
      writer.close unless writer.closed?
    end
  end

  describe ".call" do
    it "accepts resource: like other strategies" do
      reader, writer = IO.pipe
      expect do
        described_class.call(deadline: 0.05, resource: reader) { |io, _d| io.read }
      end.to raise_error(TIMEx::Expired)
    ensure
      writer.close unless writer.closed?
    end
  end
end
