require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require 'json'

class LocalLLMService
  TEMPERATURE = 0.7
  MAX_TOKENS = 500

  attr_reader :model

  def initialize
    @client = Faraday.new('http://127.0.0.1:1234') do |f|
      f.request :retry, max: 2, interval: 0.2, backoff_factor: 2
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter :net_http_persistent, pool_size: 10, idle_timeout: 60
    end
    @client.headers['Content-Type'] = 'application/json'
    @model = get_available_model
  end

  def generate_response(text)
    return "Model not available" unless @model

    request_body = {
      model: @model,
      messages: [{ role: "user", content: text }],
      max_tokens: MAX_TOKENS,
      temperature: TEMPERATURE
    }

    response = @client.post('/v1/chat/completions', request_body.to_json)
    JSON.parse(response.body).dig('choices', 0, 'message', 'content') || "No response"
  rescue Faraday::Error, JSON::ParserError => e
    "Error generating response: #{e.message}"
  end

  private

  def get_available_model
    response = @client.get('/v1/models')
    JSON.parse(response.body).dig('data', 0, 'id')
  rescue Faraday::Error, JSON::ParserError
    nil
  end
end