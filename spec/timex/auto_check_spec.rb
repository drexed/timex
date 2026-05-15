# frozen_string_literal: true

RSpec.describe TIMEx::AutoCheck do
  describe ".run" do
    it "raises TIMEx::Expired in a tight Ruby loop once the deadline passes" do
      expect do
        described_class.run(TIMEx::Deadline.in(0.05), interval: 50) { loop { 1 + 1 } }
      end.to raise_error(TIMEx::Expired)
    end

    it "does not inject checks while the thread is inside Deadline#shield" do
      deadline = TIMEx::Deadline.in(0.05)
      sleep 0.06
      shield_completed = false
      begin
        described_class.run(deadline, interval: 50) do
          deadline.shield do
            1_000.times { 1 + 1 }
            shield_completed = true
          end
        end
      rescue TIMEx::Expired
        # May fire after the shield exits; the invariant is shield work finished first.
      end
      expect(shield_completed).to be(true)
    end
  end
end
