# What the two RubyLLM transports share: one RubyLLM context per endpoint
# (timeout, retries, proxy from the endpoint and Ai::Transport::Http), error
# mapping onto Ai::Error, and converting messages both ways.
module Ai::Transport::RubyLlmAdapter
  ERRORS = {
    RubyLLM::UnauthorizedError => Ai::Error::Unauthorized,
    RubyLLM::ForbiddenError => Ai::Error::Unauthorized,
    RubyLLM::RateLimitError => Ai::Error::RateLimited,
    RubyLLM::ContextLengthExceededError => Ai::Error::ContextTooLong,
    RubyLLM::ServerError => Ai::Error::Upstream,
    RubyLLM::ServiceUnavailableError => Ai::Error::Upstream,
    RubyLLM::OverloadedError => Ai::Error::Upstream,
    RubyLLM::PaymentRequiredError => Ai::Error::Refused,
    RubyLLM::BadRequestError => Ai::Error::Refused,
    RubyLLM::CancelledError => Ai::Error::Cancelled
  }.freeze

  private
    def ruby_llm_context
      @ruby_llm_context ||= RubyLLM.context do |config|
        configure_provider(config)
        config.request_timeout = endpoint.timeout_seconds
        config.max_retries = endpoint.max_retries
        config.http_proxy = Ai::Transport::Http.proxy_for(endpoint.base_url)
        # RubyLLM otherwise uploads a large file to the provider's Files API
        # (Anthropic over 24 MB, the :openai provider over 50 MB), where it
        # stays until deleted, and posts to /v1/files on local servers too.
        config.auto_upload_large_files = false
      end
    end

    def ruby_llm_chat(model, provider:, protocol: nil)
      ruby_llm_context.chat(model: model.name, provider:, protocol:, assume_model_exists: true)
                      .with_headers(Ai::Transport::Http.headers(endpoint))
    end

    def mapping_errors
      yield
    rescue RubyLLM::Error, RubyLLM::CancelledError => e
      status = e.respond_to?(:response) ? e.response&.status : nil
      klass = ERRORS.find { |from, _| e.is_a?(from) }&.last ||
              (status ? Ai::Error.for_status(status, e.message) : Ai::Error::Refused)
      raise klass.new(e.message, status:)
    rescue Faraday::TimeoutError, ::Timeout::Error, Net::ReadTimeout, Net::OpenTimeout => e
      raise Ai::Error::Timeout, e.message
    rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED, SocketError => e
      raise Ai::Error::Unreachable, e.message
    end

    def usage_of(message)
      tokens = message.tokens
      usage_from(input: tokens.input, output: tokens.output, cache_read: tokens.cache_read, cache_write: tokens.cache_write)
    end

    def raw_id(message) = message.raw.respond_to?(:body) && message.raw.body.is_a?(Hash) ? message.raw.body["id"] : nil

    def ruby_llm_attachments(attachments)
      attachments.map { RubyLLM::Attachment.new(StringIO.new(_1.data), filename: _1.filename) }
    end

    def ruby_llm_messages(messages)
      messages.map do |message|
        case message.role
        when :tool then RubyLLM::Message.new(role: :tool, content: message.content, tool_call_id: message.tool_call_id)
        when :assistant
          state = message.provider_state.to_h
          RubyLLM::Message.new(role: :assistant, content: message.content.to_s, **state.except(:tool_calls),
                               tool_calls: state[:tool_calls] || ruby_llm_tool_calls(message.tool_calls))
        else RubyLLM::Message.new(role: message.role, content: message.content)
        end
      end
    end

    def ruby_llm_tool_calls(tool_calls)
      tool_calls.to_h { [ _1.id, RubyLLM::ToolCall.new(id: _1.id, name: _1.name, arguments: _1.arguments) ] }
    end

    # Sure owns the loop: the tool is declared to the model but never executed
    # by RubyLLM, because converse calls Chat#generate, not #ask/#complete.
    def ruby_llm_tools(specs)
      specs.map { |spec| DeclaredTool.new(spec) }
    end

    def converse_with(chat, request, &on_chunk)
      prepare_converse(chat, request)
      chat.with_tools(*ruby_llm_tools(request.tools)) if request.tools.any?
      chat.with_tool_options(choice: request.tool_choice) if request.tool_choice
      generate_turn(chat, &on_chunk)
    end

    def prepare_converse(chat, request)
      chat.with_instructions(request.instructions)
      chat.with_max_output_tokens(request.max_tokens) if request.max_tokens
      # OpenAI's `user` field (an agent keys its sessions on it). RubyLLM's
      # with_end_user sends safety_identifier to the :openai provider instead.
      options = endpoint.extra_body.merge(request.metadata[:end_user] ? { user: request.metadata[:end_user] } : {})
      chat.with_provider_options(options) if options.present?
      ruby_llm_messages(request.messages).each { chat.add_message(_1) }
    end

    def generate_turn(chat, &on_chunk)
      message = mapping_errors do
        chat.generate { |chunk| on_chunk&.call(chunk.content) if chunk.content.present? }
      end
      Ai::Transport::Base::Turn.new(text: message.content.to_s, tool_calls: sure_tool_calls(message), usage: usage_of(message),
                                    raw_id: raw_id(message), finish_reason: message.finish_reason, provider_state: provider_state(message))
    end

    def sure_tool_calls(message)
      message.tool_calls.to_h.values.map { Ai::Transport::Base::ToolCall.new(id: _1.id, name: _1.name, arguments: _1.arguments) }
    end

    def provider_state(message) = message.to_h.slice(:thinking, :thinking_signature, :raw_reasoning, :tool_calls).presence

    # RubyLLM's history back into Sure's messages, which Sure stores.
    def sure_messages(messages)
      messages.reject { _1.role == :system }.map do |message|
        case message.role
        when :assistant
          Ai::Transport::Base::Message.new(role: :assistant, content: message.content.to_s, tool_calls: sure_tool_calls(message),
                                           provider_state: provider_state(message))
        when :tool then Ai::Transport::Base::Message.new(role: :tool, content: message.content.to_s, tool_call_id: message.tool_call_id)
        else Ai::Transport::Base::Message.new(role: message.role, content: message.content.to_s)
        end
      end
    end

    class DeclaredTool < RubyLLM::Tool
      def initialize(spec)
        @spec = spec
        super()
      end

      def name = @spec.name
      def description = @spec.description
      def parameters_schema = @spec.schema
      def execute(**) = raise(Ai::Error::Refused, "Sure runs #{name}, not RubyLLM")
    end
end
