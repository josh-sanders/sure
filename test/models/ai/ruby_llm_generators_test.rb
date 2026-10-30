require "test_helper"
require "rails/generators"

# Spike: RubyLLM's Rails generators for agents, tools and schemas, run into a
# temporary folder. They scaffold a RubyLLM-shaped app: an agent bound to an
# acts_as_chat Chat (Sure's Chat isn't one), ERB instructions in the
# app/prompts folder the plan gives its .md prompts (§8.3), and tool
# partials with raw Tailwind palette classes, which Sure's design-system
# rules forbid, rendering a messages/error partial Sure doesn't have.
class Ai::RubyLlmGeneratorsTest < ActiveSupport::TestCase
  def generate(generator, name)
    Dir.mktmpdir do |dir|
      Rails::Generators.invoke(generator, [ name, "--quiet" ], destination_root: dir)
      yield Dir[File.join(dir, "**/*")].select { File.file?(_1) }.to_h { [ _1.delete_prefix("#{dir}/"), File.read(_1) ] }
    end
  end

  test "the agent generator binds the agent to Chat and writes ERB instructions under app/prompts" do
    generate("ruby_llm:agent", "Support") do |files|
      assert_equal [ "app/agents/support_agent.rb", "app/prompts/support_agent/instructions.txt.erb" ], files.keys.sort
      assert_match "chat_model Chat", files["app/agents/support_agent.rb"]
      assert_not ::Chat.respond_to?(:acts_as_chat_options) && ::Chat.reflect_on_association(:ruby_llm_model), "Sure's Chat isn't an acts_as_chat model"
    end
  end

  test "the tool generator writes view partials with raw Tailwind palette classes" do
    generate("ruby_llm:tool", "Weather") do |files|
      assert_equal %w[app/tools/weather_tool.rb app/views/messages/tool_calls/_weather.html.erb app/views/messages/tool_results/_weather.html.erb], files.keys.sort
      partials = files.values_at("app/views/messages/tool_calls/_weather.html.erb", "app/views/messages/tool_results/_weather.html.erb").join
      assert_match(/bg-gray-50|text-gray-700/, partials, "AGENTS.md: functional tokens only, no raw palette classes")
      assert_match 'render "messages/error"', partials
      assert_empty Dir[Rails.root.join("app/views/messages/_error*")], "a partial Sure doesn't have"
    end
  end

  test "the schema generator writes an empty Schematist schema" do
    generate("ruby_llm:schema", "Product") do |files|
      assert_equal({ "app/schemas/product_schema.rb" => "class ProductSchema < Schematist::Schema\nend\n" }, files)
    end
  end
end
