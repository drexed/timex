# frozen_string_literal: true

require "socket"

RSpec.describe TIMEx::Strategies::IO do
  describe ".read" do
    it "raises Expired when nothing arrives in time" do
      r, w = IO.pipe
      expect do
        described_class.read(r, 16, deadline: 0.05)
      end.to raise_error(TIMEx::Expired)
    ensure
      r.close
      w.close
    end

    it "returns data that arrives before deadline" do
      r, w = IO.pipe
      Thread.new do
        sleep 0.01
        w.write("hi")
        w.close
      end
      expect(described_class.read(r, 16, deadline: 1.0)).to eq("hi")
    ensure
      r.close
    end
  end

  describe ".write" do
    it "writes the entire buffer" do
      r, w = IO.pipe
      thread = Thread.new { r.read }
      bytes = described_class.write(w, "hello", deadline: 1.0)
      w.close
      expect(thread.value).to eq("hello")
      expect(bytes).to eq(5)
    ensure
      r.close unless r.closed?
    end
  end
end
