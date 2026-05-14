# frozen_string_literal: true

RSpec.describe TIMEx::Registry do
  it "registers all built-in strategies" do
    expect(described_class.known).to include(:cooperative, :io, :unsafe, :wakeup, :closeable, :subprocess)
  end

  it "raises StrategyNotFoundError for unknown names" do
    expect { described_class.fetch(:does_not_exist) }
      .to raise_error(TIMEx::StrategyNotFoundError)
  end

  it "uses default_selector when set" do
    described_class.default_selector { :unsafe }
    expect(described_class.select_default).to eq(TIMEx::Strategies::Unsafe)
  ensure
    described_class.default_selector { nil }
  end
end
