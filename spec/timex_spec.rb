# frozen_string_literal: true

RSpec.describe TIMEx do
  describe "VERSION" do
    it "is a non-empty string" do
      expect(TIMEx::VERSION).to be_a(String).and(satisfy { |s| !s.empty? })
    end
  end

  describe ".call / .deadline" do
    it "returns the block value when within budget" do
      expect(described_class.call(1.0) { 42 }).to eq(42)
      expect(described_class.deadline(1.0) { :ok }).to eq(:ok)
    end

    it "raises Expired by default when the deadline elapses (cooperative)" do
      expect do
        described_class.call(0.0001) do |d|
          sleep 0.05
          d.check!
        end
      end.to raise_error(TIMEx::Expired)
    end

    it "supports on_timeout: :return_nil" do
      result = described_class.call(0.0001, on_timeout: :return_nil) do |d|
        sleep 0.01
        d.check!
      end
      expect(result).to be_nil
    end

    it "supports on_timeout: :result" do
      result = described_class.call(0.0001, on_timeout: :result) do |d|
        sleep 0.01
        d.check!
      end
      expect(result).to be_a(TIMEx::Result).and(have_attributes(outcome: :timeout))
    end

    it "accepts an explicit Deadline" do
      d = TIMEx::Deadline.in(2.0)
      expect(described_class.deadline(d) { :ok }).to eq(:ok)
    end

    it "raises ArgumentError for a non-callable strategy" do
      expect { described_class.call(1.0, strategy: Object.new) { :nope } }
        .to raise_error(ArgumentError, /must be a Symbol, Class, or instance/)
    end

    it "auto_check inserts cancellation in tight loops" do
      described_class.configure { |c| c.auto_check_interval = 10 }
      expect do
        described_class.call(0.05, auto_check: true) do
          loop { 1 + 1 }
        end
      end.to raise_error(TIMEx::Expired)
    end
  end

  describe ".configure" do
    it "yields the configuration and changes defaults" do
      described_class.configure { |c| c.default_on_timeout = :return_nil }
      result = described_class.call(0.0001) do |d|
        sleep 0.01
        d.check!
      end
      expect(result).to be_nil
    end
  end
end
