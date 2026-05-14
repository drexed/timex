# frozen_string_literal: true

# Hand-rolled property tests covering the algebra around Deadline and
# composer nesting. Kept dep-free (no rantly/PropCheck).
RSpec.describe "TIMEx algebra (properties)", type: :integration do
  around do |example|
    TIMEx::Test.with_virtual_clock { example.run }
  end

  describe "Deadline.min" do
    it "is associative across random triples" do
      100.times do
        a, b, c = Array.new(3) { TIMEx::Deadline.in(rand(0.001..10.0)) }
        left  = a.min(b).min(c).remaining
        right = a.min(b.min(c)).remaining
        expect(left).to be_within(1e-9).of(right)
      end
    end

    it "is commutative across random pairs" do
      100.times do
        a = TIMEx::Deadline.in(rand(0.001..10.0))
        b = TIMEx::Deadline.in(rand(0.001..10.0))
        expect(a.min(b).remaining).to be_within(1e-9).of(b.min(a).remaining)
      end
    end

    it "treats infinite as identity" do
      50.times do
        a = TIMEx::Deadline.in(rand(0.001..10.0))
        expect(a.min(TIMEx::Deadline.infinite)).to eq(a)
        expect(TIMEx::Deadline.infinite.min(a)).to eq(a)
      end
    end
  end

  describe "nested deadlines" do
    it "the inner deadline never exceeds the outer" do
      50.times do
        outer_secs = rand(1.0..10.0)
        inner_secs = rand(0.001..(outer_secs * 2))
        outer = TIMEx::Deadline.in(outer_secs)
        inner = TIMEx::Deadline.in(inner_secs)
        effective = outer.min(inner)
        expect(effective.remaining).to be <= outer.remaining + 1e-6
      end
    end
  end

  describe "Deadline#shield" do
    it "always allows a block to complete even if the deadline has passed" do
      30.times do
        d = TIMEx::Deadline.in(rand(0.001..0.05))
        TIMEx::Test.advance(0.1)
        completed = false
        d.shield { completed = true }
        expect(completed).to be(true)
      end
    end
  end

  describe "header round-trip" do
    it "preserves remaining within rounding for many random budgets" do
      30.times do
        secs = rand(0.001..30.0)
        d = TIMEx::Deadline.in(secs)
        d2 = TIMEx::Deadline.from_header(d.to_header)
        expect(d2.remaining).to be_within(0.05).of(secs)
      end
    end
  end
end
