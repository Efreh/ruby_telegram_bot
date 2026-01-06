require 'dotenv'
require 'telegram/bot'
require 'logger'
require_relative 'localLLMService'
require_relative 'localLLMRubyService'

Dotenv.load

token = ENV['BOT_TOKEN']

Telegram::Bot::Client.run(token) do |bot|
  llm_service = LocalLLMService.new

  llm_service_candle = LocalLLMRubyService.new

  bot.listen do |message|
    case message
    when Telegram::Bot::Types::Message
      if message.photo
        bot.api.send_message(chat_id: message.chat.id, text: "It is a photo!")
      elsif message.video
        bot.api.send_message(chat_id: message.chat.id, text: "It is a video!")
      elsif message.document
        bot.api.send_message(chat_id: message.chat.id, text: "It is a document!")
      elsif case message.text
            when '/start'
              bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}!")
            when '/end'
              bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}!")
            when '/models'
              bot.api.send_message(chat_id: message.chat.id, text: "Current models : #{llm_service.model}!")
            when /^\/question\s+(.+)$/
              response = llm_service.generate_response(question = $1)
              bot.api.send_message(chat_id: message.chat.id, text: response)
            when /^\/question2\s+(.+)$/
              response = llm_service_candle.generate_response(question = $1)
              bot.api.send_message(chat_id: message.chat.id, text: response)
            else
              bot.api.send_message(chat_id: message.chat.id, text: "I don't understand you =(")
            end
      end
    end
  end
end