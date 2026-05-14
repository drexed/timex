# frozen_string_literal: true

# Rails generator namespace is +Timex+ (not +TIMEx+) to follow Rails::Generators
# naming conventions and avoid constant clashes with the +TIMEx+ library module.
module Timex
  # Copies the TIMEx initializer template into the host application.
  #
  # @see Rails::Generators::Base
  class InstallGenerator < Rails::Generators::Base

    source_root File.expand_path("templates", __dir__)

    desc "Creates TIMEx initializer with global configuration settings"

    # @return [void]
    def copy_initializer_file
      copy_file("install.rb", "config/initializers/timex.rb")
    end

  end
end
