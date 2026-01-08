require 'faraday'
require 'json'

TEMPERATURE = 0.7
MAX_TOKENS = 500

class LocalLLMService
  attr_reader :model

  def initialize
    @client = Faraday.new('http://127.0.0.1:1234') unless nil
    @client.headers['Content-type'] = 'application/json'
    @model = get_available_model
  end

  def generate_response(text)
    request_body = {
      model: @model,
      messages: [
        { role: "user", content: text }
      ],
      max_tokens: MAX_TOKENS,
      temperature: TEMPERATURE
    }

    response = @client.post('/v1/chat/completions', request_body.to_json).body
    JSON.parse(response)['choices'][0]['message']['content']
  end

  def get_available_model
    begin
      response = @client.get('/v1/models')
      json_string = response.body
      JSON.parse(json_string)['data'][0]['id']
    rescue Faraday::Error => e
      puts e
      nil
    rescue JSON::ParserError => e
      puts e
      nil
    end
  end
end