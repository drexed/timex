# frozen_string_literal: true

RSpec.describe TIMEx::Propagation::HttpHeader do
  it "round-trips a Deadline through Rack env" do
    d = TIMEx::Deadline.in(1.5)
    env = { "HTTP_X_TIMEX_DEADLINE" => d.to_header }
    parsed = described_class.from_rack_env(env)
    expect(parsed.remaining).to be_within(0.05).of(1.5)
  end

  it "injects into a header hash" do
    headers = {}
    described_class.inject(headers, TIMEx::Deadline.in(1.0))
    expect(headers).to include(TIMEx::Propagation::HttpHeader::HEADER_NAME)
  end

  it "parses a case-insensitive deadline header key" do
    headers = { "x-timex-deadline" => TIMEx::Deadline.in(1.0).to_header }
    parsed = described_class.from_headers(headers)
    expect(parsed.remaining).to be_within(0.05).of(1.0)
  end

  it "returns nil for nil headers" do
    expect(described_class.from_headers(nil)).to be_nil
  end
end
