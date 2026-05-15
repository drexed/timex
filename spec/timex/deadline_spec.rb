# frozen_string_literal: true

RSpec.describe TIMEx::Deadline do
  around do |example|
    TIMEx::Test.with_virtual_clock { example.run }
  end

  describe ".in" do
    it "creates a deadline N seconds from now" do
      d = described_class.in(1.0)
      expect(d.remaining).to be_within(0.001).of(1.0)
    end

    it "treats nil, non-finite floats, and overflow products as infinite" do
      expect(described_class.in(nil)).to be_infinite
      expect(described_class.in(Float::INFINITY)).to be_infinite
      expect(described_class.in(Float::NAN)).to be_infinite
      expect(described_class.in(1e200)).to be_infinite
    end
  end

  describe ".at_wall" do
    let(:ns) { TIMEx::Clock::NS_PER_SECOND }
    let(:wall_origin) { 10_000 * ns }

    around do |example|
      clock = TIMEx::Clock::VirtualClock.new(monotonic_ns: 500 * ns, wall_ns: wall_origin)
      TIMEx::Clock.with(clock) { example.run }
    end

    it "tracks remaining wall delta and shrinks when the clock advances" do
      target_ns = wall_origin + (7 * ns)
      t = Time.at(target_ns / ns, target_ns % ns, :nanosecond)
      d = described_class.at_wall(t)
      expect(d.remaining).to be_within(1e-6).of(7.0)
      TIMEx::Clock.current.advance(3)
      expect(d.remaining).to be_within(1e-6).of(4.0)
    end

    it "is used by coerce(Time)" do
      target_ns = wall_origin + (2 * ns)
      t = Time.at(target_ns / ns, target_ns % ns, :nanosecond)
      d = described_class.coerce(t)
      expect(d.remaining).to be_within(1e-6).of(2.0)
    end
  end

  describe "#expired?" do
    it "is false when remaining > 0" do
      d = described_class.in(1.0)
      expect(d).not_to be_expired
    end

    it "is true once the clock advances past it" do
      d = described_class.in(1.0)
      TIMEx::Test.advance(2.0)
      expect(d).to be_expired
    end

    it "is suppressed inside #shield" do
      d = described_class.in(1.0)
      TIMEx::Test.advance(2.0)
      d.shield { expect(d).not_to be_expired }
      expect(d).to be_expired
    end
  end

  describe "#check!" do
    it "raises Expired once past deadline" do
      d = described_class.in(0.5)
      TIMEx::Test.advance(1.0)
      expect { d.check! }.to raise_error(TIMEx::Expired)
    end
  end

  describe "#min" do
    it "returns the tighter of two deadlines (associative)" do
      a = described_class.in(2.0)
      b = described_class.in(5.0)
      c = described_class.in(1.0)
      expect(a.min(b).min(c).remaining).to be_within(0.01).of(1.0)
      expect(c.min(a.min(b)).remaining).to be_within(0.01).of(1.0)
    end

    it "treats infinite as identity" do
      a = described_class.in(2.0)
      expect(a.min(described_class.infinite)).to eq(a)
    end
  end

  describe "header round-trip" do
    it "serializes and parses ms= form" do
      d = described_class.in(1.234)
      hdr = d.to_header
      expect(hdr).to match(/\Ams=\d+;depth=\d+\z/)
      d2 = described_class.from_header(hdr)
      expect(d2.remaining).to be_within(0.05).of(1.234)
    end

    it "increments depth on round-trip" do
      d = described_class.in(1.0)
      d2 = described_class.from_header(d.to_header)
      expect(d2.depth).to eq(1)
    end

    it "returns nil for malformed headers" do
      expect(described_class.from_header(nil)).to be_nil
      expect(described_class.from_header("")).to be_nil
      expect(described_class.from_header("garbage")).to be_a(described_class).or be_nil
    end

    it "returns nil for non-numeric ms values" do
      expect(described_class.from_header("ms=not-a-number")).to be_nil
    end

    it "rejects oversized header input" do
      expect(described_class.from_header("ms=1;" + ("x" * 300))).to be_nil
    end

    it "rejects oversized wall= timestamps (Rational DoS guard)" do
      pathological = "wall=" + ("9" * (described_class::MAX_ISO8601_BYTESIZE + 1))
      expect(described_class.from_header(pathological)).to be_nil
    end

    it "rejects out-of-range ms values (DoS protection)" do
      expect(described_class.from_header("ms=1e308")).to be_nil
      expect(described_class.from_header("ms=-5")).to be_nil
      expect(described_class.from_header("ms=#{described_class::MAX_MS_VALUE + 1}")).to be_nil
    end

    it "clamps untrusted depth at MAX_DEPTH" do
      d = described_class.from_header("ms=100;depth=99999999")
      expect(d.depth).to eq(described_class::MAX_DEPTH)
    end

    it "rejects origins containing reserved characters (header injection)" do
      d = described_class.in(5).with_meta(origin: "service-a;ms=999999")
      header = d.to_header
      expect(header).not_to include("ms=999999")
      parsed = described_class.from_header(header)
      expect(parsed.remaining_ms.round).to be_within(50).of(5000)
    end

    it "drops origin parts that don't match the allowed pattern" do
      d = described_class.from_header("ms=100;origin=ev!l")
      expect(d.origin).to be_nil
    end

    it "preserves origin/depth even when ms=inf (depth-limit bypass guard)" do
      d = described_class.from_header("ms=inf;depth=3;origin=svc-a")
      expect(d).to be_infinite
      expect(d.depth).to eq(3)
      expect(d.origin).to eq("svc-a")
      expect(d).not_to equal(described_class.infinite)
    end

    it "still returns the shared sentinel when ms=inf has no metadata" do
      d = described_class.from_header("ms=inf")
      expect(d).to equal(described_class.infinite)
    end

    it "includes origin and depth in to_header for infinite deadlines with metadata" do
      d = described_class.from_header("ms=inf;depth=2;origin=svc-a")
      hdr = d.to_header
      expect(hdr).to start_with("ms=inf")
      expect(hdr).to include("origin=svc-a")
      expect(hdr).to match(/depth=\d+/)
    end

    it "rejects explicitly negative depth" do
      expect(described_class.from_header("ms=100;depth=-1")).to be_nil
    end

    it "round-trips wall= form to a near-equivalent deadline" do
      d   = described_class.in(1.0)
      hdr = d.to_header(prefer: :wall)
      expect(hdr).to match(/\Awall=\d{4}-\d{2}-\d{2}T/)
      d2 = described_class.from_header(hdr)
      expect(d2.remaining).to be_within(0.05).of(1.0)
    end
  end

  describe "#==" do
    it "is true only when monotonic_ns, wall_ns, origin and depth all match" do
      a = described_class.in(1.0).with_meta(origin: "svc-a", depth: 1)
      b = described_class.new(monotonic_ns: a.monotonic_ns, wall_ns: a.wall_ns,
        origin: "svc-a", depth: 1)
      c = described_class.new(monotonic_ns: a.monotonic_ns, wall_ns: a.wall_ns,
        origin: "svc-b", depth: 1)
      d = described_class.new(monotonic_ns: a.monotonic_ns, wall_ns: a.wall_ns,
        origin: "svc-a", depth: 2)
      e = described_class.new(monotonic_ns: a.monotonic_ns, wall_ns: a.wall_ns + 1,
        origin: "svc-a", depth: 1)
      expect(a).to eq(b)
      expect(a).not_to eq(c)
      expect(a).not_to eq(d)
      expect(a).not_to eq(e)
      expect(a.hash).to eq(b.hash)
    end
  end

  describe "#same_instant?" do
    it "ignores propagation metadata" do
      a = described_class.in(1.0).with_meta(origin: "svc-a", depth: 1)
      b = described_class.new(monotonic_ns: a.monotonic_ns, origin: "svc-b", depth: 9)
      expect(a.same_instant?(b)).to be(true)
      expect(a).not_to eq(b)
    end
  end

  describe "#initial_ms / #expired_error" do
    it "captures the original budget at construction" do
      d = described_class.in(2.5)
      expect(d.initial_ms).to be_within(0.01).of(2500.0)
    end

    it "returns nil for the infinite sentinel" do
      expect(described_class.infinite.initial_ms).to be_nil
    end

    it "builds an Expired carrying budget and elapsed-past" do
      d = described_class.in(0.5)
      TIMEx::Test.advance(1.0)
      err = d.expired_error(strategy: :cooperative)
      expect(err).to be_a(TIMEx::Expired)
      expect(err.strategy).to eq(:cooperative)
      expect(err.deadline_ms).to eq(500)
      expect(err.elapsed_ms).to be >= 500
    end

    it "is reused by Deadline#check!" do
      d = described_class.in(0.25)
      TIMEx::Test.advance(0.5)
      expect { d.check!(strategy: :cooperative) }
        .to raise_error(TIMEx::Expired) { |e| expect(e.deadline_ms).to eq(250) }
    end
  end

  describe ".infinite" do
    it "is a frozen singleton across calls" do
      a = described_class.infinite
      b = described_class.infinite
      expect(a).to equal(b)
      expect(a).to be_frozen
    end
  end

  describe ".coerce" do
    it "passes through a Deadline" do
      d = described_class.in(1.0)
      expect(described_class.coerce(d)).to equal(d)
    end

    it "wraps a Numeric" do
      expect(described_class.coerce(0.5)).to be_a(described_class)
    end

    it "wraps nil as infinite" do
      expect(described_class.coerce(nil)).to be_infinite
    end

    it "wraps a Time as a wall-anchored deadline" do
      d = described_class.coerce(Time.now + 2)
      expect(d.remaining).to be_within(0.1).of(2.0)
    end

    it "hints when given a Symbol (likely a strategy mix-up)" do
      expect { described_class.coerce(:cooperative) }
        .to raise_error(ArgumentError, /strategy: :cooperative/)
    end
  end
end
