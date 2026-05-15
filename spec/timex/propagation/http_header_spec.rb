# frozen_string_literal: true

RSpec.describe TIMEx::Propagation::HttpHeader do
  describe ".from_rack_env" do
    it "parses HTTP_X_TIMEX_DEADLINE into a Deadline" do
      deadline = TIMEx::Deadline.in(1.5)
      env = { "HTTP_X_TIMEX_DEADLINE" => deadline.to_header }
      parsed = described_class.from_rack_env(env)
      expect(parsed.remaining).to be_within(0.05).of(1.5)
    end
  end

  describe ".inject" do
    it "writes the canonical header name and wire value" do
      headers = {}
      described_class.inject(headers, TIMEx::Deadline.in(1.0))
      expect(headers).to include(TIMEx::Propagation::HttpHeader::HEADER_NAME)
    end
  end

  describe ".from_headers" do
    it "matches the header key case-insensitively" do
      headers = { "x-timex-deadline" => TIMEx::Deadline.in(1.0).to_header }
      parsed = described_class.from_headers(headers)
      expect(parsed.remaining).to be_within(0.05).of(1.0)
    end

    context "when headers is nil" do
      it "returns nil" do
        expect(described_class.from_headers(nil)).to be_nil
      end
    end
  end
end
