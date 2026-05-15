# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Wakeup do
  describe "#read_io" do
    context "when armed with a short deadline" do
      it "unblocks wait_readable around the budget" do
        wake = described_class.new(0.05)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        wake.read_io.wait_readable(5.0)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(wake.fired?).to be(true)
        expect(elapsed).to be < 1.0
      ensure
        wake.close
      end
    end

    context "when cancel! fires from another thread" do
      it "unblocks wait_readable" do
        wake = described_class.new
        Thread.new do
          sleep 0.01
          wake.cancel!(reason: :stop)
        end
        wake.read_io.wait_readable(1.0)
        expect(wake.fired?).to be(true)
      ensure
        wake.close
      end
    end
  end

  describe "#close" do
    it "makes subsequent arm/read_io raise" do
      wake = described_class.new
      wake.close
      expect { wake.arm(0.1) }.to raise_error(TIMEx::Error, /single-use/)
      expect { wake.read_io }.to raise_error(TIMEx::Error, /single-use/)
    end
  end
end
