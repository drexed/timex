# frozen_string_literal: true

RSpec.describe TIMEx::AutoCheck do
  it "interrupts a tight Ruby loop" do
    raised = nil
    begin
      described_class.run(TIMEx::Deadline.in(0.05), interval: 50) do
        loop { 1 + 1 }
      end
    rescue TIMEx::Expired => e
      raised = e
    end
    expect(raised).to be_a(TIMEx::Expired)
  end

  it "does not fire while inside Deadline#shield" do
    d = TIMEx::Deadline.in(0.05)
    sleep 0.06
    inside_shield_completed = false
    begin
      described_class.run(d, interval: 50) do
        d.shield do
          1_000.times { 1 + 1 }
          inside_shield_completed = true
        end
      end
    rescue TIMEx::Expired
      # may fire after shield exits; that's fine
    end
    expect(inside_shield_completed).to be(true)
  end
end
