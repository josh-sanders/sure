# The correlation id comes from the job's arguments (section 10), set once per
# job and read by every .ai event inside it.
module Ai::Correlation
  KEY = :ai_correlation_id

  module_function

  def with(id)
    previous = Thread.current[KEY]
    Thread.current[KEY] = id
    yield
  ensure
    Thread.current[KEY] = previous
  end

  def current = Thread.current[KEY]
end
