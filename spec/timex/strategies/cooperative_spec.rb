# frozen_string_literal: true

RSpec.describe TIMEx::Strategies::Cooperative do
  it "returns the block value when within deadline" do
    expect(described_class.call(deadline: 1.0) { :ok }).to eq(:ok)
  end

  it "raises Expired when check! fires" do
    expect do
      described_class.call(deadline: 0.001) do |d|
        sleep 0.01
        d.check!
      end
    end.to raise_error(TIMEx::Expired)
  end

  it "respects on_timeout: :return_nil" do
    result = described_class.call(deadline: 0.001, on_timeout: :return_nil) do |d|
      sleep 0.01
      d.check!
    end
    expect(result).to be_nil
  end
end
