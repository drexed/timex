# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Wakeup do
  it "wakes a blocked select after the deadline" do
    wake = described_class.new(0.05)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    wake.read_io.wait_readable(5.0)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expect(wake.fired?).to be(true)
    expect(elapsed).to be < 1.0
  ensure
    wake.close
  end

  it "supports manual cancel!" do
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

  it "raises on reuse after close" do
    wake = described_class.new
    wake.close
    expect { wake.arm(0.1) }.to raise_error(TIMEx::Error, /single-use/)
    expect { wake.read_io }.to raise_error(TIMEx::Error, /single-use/)
  end
end
