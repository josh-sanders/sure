module Ai::Transport
  def self.for(endpoint, hand_written: false)
    namespace = hand_written ? Ai::Transport::HandWritten : Ai::Transport
    case endpoint.protocol
    when :compatible then namespace::Compatible.new(endpoint)
    when :anthropic then namespace::Anthropic.new(endpoint)
    else raise ArgumentError, "unknown protocol #{endpoint.protocol}"
    end
  end
end
