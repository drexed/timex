# frozen_string_literal: true

RSpec.describe TIMEx do
  describe "VERSION" do
    it "is a non-empty string" do
      expect(TIMEx::VERSION).to be_a(String).and(satisfy { |s| !s.empty? })
    end
  end

  describe ".call" do
    context "when the block stays within the deadline" do
      it "returns the block value" do
        expect(described_class.call(1.0) { 42 }).to eq(42)
      end
    end

    context "when the cooperative deadline elapses before check!" do
      it "raises TIMEx::Expired by default" do
        expect do
          described_class.call(0.0001) do |d|
            sleep 0.05
            d.check!
          end
        end.to raise_error(TIMEx::Expired)
      end
    end

    context "with on_timeout: :return_nil" do
      it "returns nil instead of raising" do
        result = described_class.call(0.0001, on_timeout: :return_nil) do |d|
          sleep 0.01
          d.check!
        end
        expect(result).to be_nil
      end
    end

    context "with on_timeout: :result" do
      it "returns a timeout Result" do
        result = described_class.call(0.0001, on_timeout: :result) do |d|
          sleep 0.01
          d.check!
        end
        expect(result).to be_a(TIMEx::Result).and(have_attributes(outcome: :timeout))
      end
    end

    context "when given a Deadline instance" do
      it "honors it" do
        expect(described_class.deadline(TIMEx::Deadline.in(2.0)) { :ok }).to eq(:ok)
      end
    end

    context "with a non-callable strategy" do
      it "raises ArgumentError" do
        expect { described_class.call(1.0, strategy: Object.new) { :nope } }
          .to raise_error(ArgumentError, /must be a Symbol, Class, or instance/)
      end
    end

    context "with auto_check: true and a tight loop" do
      before { described_class.configure { |c| c.auto_check_interval = 10 } }

      it "raises TIMEx::Expired without cooperative check! calls" do
        expect do
          described_class.call(0.05, auto_check: true) { loop { 1 + 1 } }
        end.to raise_error(TIMEx::Expired)
      end
    end
  end

  describe ".deadline" do
    context "when the block stays within the deadline" do
      it "returns the block value" do
        expect(described_class.deadline(1.0) { :ok }).to eq(:ok)
      end
    end

    context "when given a Deadline instance" do
      it "honors it" do
        expect(described_class.deadline(TIMEx::Deadline.in(2.0)) { :ok }).to eq(:ok)
      end
    end
  end

  describe ".configure" do
    it "yields TIMEx::Configuration and applies persisted defaults" do
      described_class.configure { |c| c.default_on_timeout = :return_nil }
      result = described_class.call(0.0001) do |d|
        sleep 0.01
        d.check!
      end
      expect(result).to be_nil
    end
  end
end
