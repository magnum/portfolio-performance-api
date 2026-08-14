# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test

namespace :proto do
  desc "Regenerate Ruby protobuf bindings from proto/client.proto"
  task :generate do
    sh "protoc --proto_path=proto --proto_path=/opt/homebrew/include --ruby_out=lib/portfolio_performance_api/proto proto/client.proto"
  end
end
