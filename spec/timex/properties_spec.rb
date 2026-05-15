# frozen_string_literal: true

# Property-style checks for Deadline algebra and header round-trips. Intentionally
# dependency-free (no Rantly/PropCheck); iteration counts are fixed for stability.
RSpec.describe "TIMEx algebra (properties)", type: :integration do
  let(:light_property_iterations) { 30 }
  let(:standard_property_iterations) { 50 }
  let(:stress_property_iterations) { 100 }

  around do |example|
    TIMEx::Test.with_virtual_clock { example.run }
  end

  describe "Deadline.min" do
    it "is associative across random triples" do
      stress_property_iterations.times do
        a, b, c = Array.new(3) { TIMEx::Deadline.in(rand(0.001..10.0)) }
        left  = a.min(b).min(c).remaining
        right = a.min(b.min(c)).remaining
        expect(left).to be_within(1e-9).of(right)
      end
    end

    it "is commutative across random pairs" do
      stress_property_iterations.times do
        a = TIMEx::Deadline.in(rand(0.001..10.0))
        b = TIMEx::Deadline.in(rand(0.001..10.0))
        expect(a.min(b).remaining).to be_within(1e-9).of(b.min(a).remaining)
      end
    end

    it "treats the infinite sentinel as identity" do
      standard_property_iterations.times do
        a = TIMEx::Deadline.in(rand(0.001..10.0))
        expect(a.min(TIMEx::Deadline.infinite)).to eq(a)
        expect(TIMEx::Deadline.infinite.min(a)).to eq(a)
      end
    end
  end

  describe "nested deadlines" do
    it "never yields an inner budget larger than the outer wall" do
      standard_property_iterations.times do
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
    it "always runs the block to completion even when the deadline is past" do
      light_property_iterations.times do
        d = TIMEx::Deadline.in(rand(0.001..0.05))
        TIMEx::Test.advance(0.1)
        completed = false
        d.shield { completed = true }
        expect(completed).to be(true)
      end
    end
  end

  describe "header round-trip" do
    it "keeps remaining within rounding noise for random budgets" do
      light_property_iterations.times do
        secs = rand(0.001..30.0)
        d = TIMEx::Deadline.in(secs)
        d2 = TIMEx::Deadline.from_header(d.to_header)
        expect(d2.remaining).to be_within(0.05).of(secs)
      end
    end
  end
end
