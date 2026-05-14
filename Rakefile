# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

desc "Generate YARD API documentation"
task :yard do
  require "yard"
  require "fileutils"

  YARD::CLI::Yardoc.run(*File.readlines(".yardopts", chomp: true).reject(&:empty?))

  api_dir = "docs/api"

  # Remove unwanted files
  FileUtils.rm_f("#{api_dir}/Timex_.html")

  # Make TIMEx.html the default index
  FileUtils.cp("#{api_dir}/TIMEx.html", "#{api_dir}/index.html") if File.exist?("#{api_dir}/TIMEx.html")
end

task default: %i[spec rubocop]
