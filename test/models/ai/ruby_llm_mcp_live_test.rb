require_relative "spike_helper"

# Spike: RubyLLM 2.1's built-in MCP client against Sure's own MCP server
# (POST /mcp), in process through a custom transport, so no server runs.
#
# Plan: Sure is an MCP server, never a client (proposal 04, §20); a tool
# catalog shared by chat and MCP is out of scope (§20). For the plan: a
# client would send a family's data to servers an operator adds. Against
# it: RubyLLM's client needs no code beyond a class, picks the tools a
# chat sees (only), and here gives chat Sure's own tools through MCP, the
# shared catalog §20 leaves out.
class Ai::RubyLlmMcpLiveTest < ActionDispatch::IntegrationTest
  include AiSpikeHelper

  # A custom transport: each JSON-RPC message is a POST /mcp to this app.
  class SureTunnel
    attr_reader :versions

    def initialize(test, token)
      @test, @token, @versions = test, token, []
    end

    def request(message, version:, timeout: nil, headers: {})
      @versions << [ message[:method], version, message.dig(:params, :protocolVersion) ]
      @test.post "/mcp", params: message.to_json,
                         headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@token}", "MCP-Protocol-Version" => version }.merge(headers)
      @test.response.body.present? ? JSON.parse(@test.response.body) : {}
    end

    def notify(message, version:) = request(message, version:) && nil
    def cancel(_notification, version:) = nil
    def close = nil
  end

  # Revision 2026-07-28 first (server/discover); Sure's server doesn't know
  # it, so the client falls back to initialize with 2025-11-25, and Sure
  # settles on its own 2025-06-18.
  EXPECTED_HANDSHAKE = [ [ "server/discover", "2026-07-28", nil ], [ "initialize", nil, "2025-11-25" ],
                         [ "notifications/initialized", "2025-06-18", nil ], [ "tools/list", "2025-06-18", nil ] ].freeze

  class SureMcp < RubyLLM::MCP
    inputs :tunnel
    transport { tunnel }
    only :get_accounts, :get_categories
  end

  setup do
    @user = users(:family_admin)
    app = Doorkeeper::Application.create!(name: "spike", redirect_uri: "https://example.test/callback", scopes: "read_write", confidential: false)
    @token = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: @user.id, scopes: "read_write", expires_in: 1.hour).token # pipelock:ignore
    @tunnel = SureTunnel.new(self, @token)
  end

  test "RubyLLM's client connects to Sure's server, negotiates down, and sees only the tools it allows" do
    server = SureMcp.new(tunnel: @tunnel)

    assert_equal %w[get_accounts get_categories], server.tools.map(&:name).sort
    puts "\n  mcp: #{@tunnel.versions.inspect}" if ENV["SPIKE_PRINT"]
    assert_equal EXPECTED_HANDSHAKE, @tunnel.versions.first(EXPECTED_HANDSHAKE.size) if defined?(EXPECTED_HANDSHAKE)
    assert_operator Assistant.function_classes(@user).size, :>, 2, "Sure offers more; only keeps two"
    result = server.call("get_accounts")
    assert JSON.parse(result.text)["accounts"].any?, "Sure's get_accounts, called through MCP"
  end

  test "a chat on Gemini answers with Sure's tools, served over MCP (live)" do
    endpoint = Ai::Spike::Presets.gemini(api_key: ENV.fetch("SPIKE_GEMINI_API_KEY", "gemini-key"), max_retries: 0)
    chat = Ai::Transport.for(endpoint).send(:chat_for, Ai::Spike::Model.new(endpoint:, name: "gemini-3.5-flash-lite"))
    with_spike_cassette("features/mcp_chat") do
      @answer = chat.with_mcp(SureMcp.new(tunnel: @tunnel)).ask("How many accounts do I have? Look them up, then answer in one sentence.")
    end

    calls = @tunnel.versions.map(&:first)
    assert_includes calls, "tools/call", "the tool ran through Sure's /mcp"
    assert_match(/\d/, @answer.content)
    sent = request_bodies(%r{generativelanguage}).first["tools"].map { _1.dig("function", "name") }
    assert_equal %w[get_accounts get_categories], sent.sort
  end
end
