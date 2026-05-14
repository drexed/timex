# frozen_string_literal: true

ENV["TZ"] = "Etc/UTC"

require "bundler/setup"
require "rspec"

require "timex"

RSpec.configure do |config|
  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on Module and main
  config.disable_monkey_patching!

  config.define_derived_metadata do |meta|
    meta[:aggregate_failures] = true
  end

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before do
    TIMEx.reset_configuration!
  end
end
