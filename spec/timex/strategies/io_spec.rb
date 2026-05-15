# frozen_string_literal: true

require "socket"

RSpec.describe TIMEx::Strategies::IO do
  describe ".read" do
    context "when the pipe stays empty" do
      it "raises TIMEx::Expired" do
        reader, writer = IO.pipe
        expect do
          described_class.read(reader, 16, deadline: 0.05)
        end.to raise_error(TIMEx::Expired)
      ensure
        reader.close
        writer.close
      end
    end

    context "when bytes arrive before the deadline" do
      it "returns the decoded chunk" do
        reader, writer = IO.pipe
        thread = Thread.new do
          sleep 0.01
          writer.write("hi")
          writer.close
        end
        expect(described_class.read(reader, 16, deadline: 1.0)).to eq("hi")
      ensure
        thread.join(2)
        reader.close unless reader.closed?
      end
    end
  end

  describe ".write" do
    it "writes the full buffer and returns the byte count" do
      reader, writer = IO.pipe
      thread = Thread.new { reader.read }
      bytes = described_class.write(writer, "hello", deadline: 1.0)
      writer.close
      expect(thread.value).to eq("hello")
      expect(bytes).to eq(5)
    ensure
      thread&.join(2)
      reader.close unless reader.closed?
    end
  end
end
