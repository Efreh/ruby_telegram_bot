require 'dotenv'
require 'telegram/bot'
require 'logger'
require 'tempfile'
require 'faraday'
require_relative 'llm_out_service'
require_relative 'llm_local_service'
require_relative 'database_manager'
require_relative 'embedding_service'

Dotenv.load

token = ENV['BOT_TOKEN']

Telegram::Bot::Client.run(token) do |bot|
  # llm_service = LocalLLMService.new

  llm_service_candle = LocalLLMRubyService.new

  db_manager = DatabaseManager.new
  embedding_service = EmbeddingService.new

  bot.listen do |message|
    case message
    when Telegram::Bot::Types::Message
      if message.photo
        bot.api.send_message(chat_id: message.chat.id, text: "It is a photo!")
      elsif message.video
        bot.api.send_message(chat_id: message.chat.id, text: "It is a video!")

      elsif (document = message.document)

        unless document.mime_type == 'application/pdf'
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Supports only PDF documents. Your file: #{document.mime_type}"
          )
          next
        end

        bot.api.send_message(chat_id: message.chat.id, text: "Process document...")

        temp_file = nil
        begin
          file_id = document.file_id
          file = bot.api.get_file(file_id: file_id)
          
          # Download file via Faraday
          file_url = "https://api.telegram.org/file/bot#{token}/#{file.file_path}"
          response = Faraday.get(file_url)
          
          temp_file = Tempfile.new(['document', '.pdf'])
          File.binwrite(temp_file.path, response.body)

          document_id = "doc_#{message.chat.id}_#{Time.now.to_i}"
          chunks_count = embedding_service.process_and_save_document(
            temp_file.path,
            document_id,
            document.file_name,
            db_manager
          )

          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Document is processed! Saved #{chunks_count} fragments."
          )
        rescue => e
          bot.api.send_message(
            chat_id: message.chat.id,
            text: "Error in process document: #{e.message}"
          )
        ensure
          temp_file&.unlink
        end

      elsif case message.text
            when '/start'
              bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}!")
            when '/end'
              bot.api.send_message(chat_id: message.chat.id, text: "Bye, #{message.from.first_name}!")
              # when '/models'
              # bot.api.send_message(chat_id: message.chat.id, text: "Current models : #{llm_service.model}!")
              # when /^\/question\s+(.+)$/
              # response = llm_service.generate_response(question = $1)
              # bot.api.send_message(chat_id: message.chat.id, text: response)
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