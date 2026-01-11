require 'dotenv'
require 'telegram/bot'
require 'tempfile'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require_relative 'logger_setup'
require_relative 'llm_out_service'
require_relative 'llm_local_service'
require_relative 'database_manager'
require_relative 'embedding_service'

Dotenv.load

TOKEN = ENV['BOT_TOKEN']

def create_faraday_client
  Faraday.new do |f|
    f.request :retry, max: 2, interval: 0.2, backoff_factor: 2
    f.options.timeout = 15
    f.options.open_timeout = 10
    f.adapter :net_http_persistent, pool_size: 10, idle_timeout: 60
  end
end

def handle_message(bot, message, llm_service, db_manager, embedding_service, http_client)
  if message.photo
    send_response(bot, message.chat.id, "It is a photo!")
  elsif message.video
    send_response(bot, message.chat.id, "It is a video!")
  elsif message.document
    handle_document(bot, message, embedding_service, db_manager, http_client)
  elsif message.text
    handle_text_command(bot, message, llm_service, embedding_service, db_manager)
  end
end

def handle_document(bot, message, embedding_service, db_manager, http_client)
  document = message.document

  unless ['application/pdf', 'text/plain'].include?(document.mime_type)
    send_response(bot, message.chat.id, "Supports only PDF and TXT documents. Your file: #{document.mime_type}")
    return
  end

  LOGGER.info "Document upload started: #{document.file_name} (#{document.mime_type}) by user #{message.from.username || message.from.id}"
  send_response(bot, message.chat.id, "Processing document...")

  temp_file = nil
  begin
    file_url = "https://api.telegram.org/file/bot#{TOKEN}/#{bot.api.get_file(file_id: document.file_id).file_path}"
    response = http_client.get(file_url)
    
    file_extension = document.mime_type == 'application/pdf' ? '.pdf' : '.txt'
    temp_file = Tempfile.new(['document', file_extension])
    File.binwrite(temp_file.path, response.body)

    document_id = "doc_#{message.chat.id}_#{Time.now.to_i}"
    chunks_count = embedding_service.process_and_save_document(
      temp_file.path,
      document_id,
      document.file_name,
      db_manager,
      document.mime_type
    )

    send_response(bot, message.chat.id, "Document processed! Saved #{chunks_count} fragments.")
  rescue StandardError => e
    LOGGER.error "Error processing document #{document.file_name}: #{e.message}"
    send_response(bot, message.chat.id, "Error processing document: #{e.message}")
  ensure
    temp_file&.unlink
  end
end

def handle_text_command(bot, message, llm_service, embedding_service, db_manager)
  case message.text
  when '/start'
    send_response(bot, message.chat.id, "Hello, #{message.from.first_name}!\n\nUse /help to see all available commands.")
  when '/help', '/menu'
    handle_help(bot, message)
  when '/end'
    send_response(bot, message.chat.id, "Bye, #{message.from.first_name}!")
  when '/list_docs'
    handle_list_docs(bot, message, db_manager)
  when /^\/delete_doc\s+(.+)$/
    handle_delete_doc(bot, message, $1, db_manager)
  when /^\/confirm_delete\s+(.+)$/
    confirm_delete_doc(bot, message, $1, db_manager)
  when '/clear_all'
    handle_clear_all(bot, message)
  when '/confirm_clear_all'
    confirm_clear_all(bot, message, db_manager)
  when '/stats'
    handle_stats(bot, message, db_manager)
  when /^\/question2\s+(.+)$/
    handle_question(bot, message, $1, llm_service, embedding_service, db_manager)
  else
    send_response(bot, message.chat.id, "I don't understand you =(\n\nUse /help to see available commands.")
  end
end

def handle_question(bot, message, question, llm_service, embedding_service, db_manager)
  LOGGER.info "Query from user #{message.from.username || message.from.id}: #{question[0..50]}..."
  
  query_embedding = embedding_service.embed(question)
  similar_chunks = db_manager.find_similar_chunks(query_embedding, 3, min_similarity: 0.65)

  response = if similar_chunks.empty?
               "No documents found to answer this question."
             else
               generate_response_with_sources(llm_service, question, similar_chunks)
             end

  send_response(bot, message.chat.id, response)
end

def generate_response_with_sources(llm_service, question, similar_chunks)
  response = llm_service.generate_rag_response(question, similar_chunks)
  
  sources = similar_chunks.map { |c| c[:file_name] }.uniq.compact.join(", ")
  response += "\n\n📄 Sources: #{sources}" unless sources.empty?
  
  response
end

def handle_list_docs(bot, message, db_manager)
  LOGGER.info "List documents requested by user #{message.from.username || message.from.id}"
  
  docs = db_manager.list_documents
  
  if docs.empty?
    send_response(bot, message.chat.id, "📚 No documents loaded yet.\nUpload a PDF or TXT file to get started.")
    return
  end
  
  response = "📚 Loaded documents (#{docs.length}):\n\n"
  docs.each_with_index do |doc, idx|
    timestamp = doc[:last_update] ? Time.parse(doc[:last_update]).strftime('%Y-%m-%d %H:%M') : 'unknown'
    response += "#{idx + 1}. #{doc[:file_name]} - #{doc[:chunk_count]} chunks (#{timestamp})\n"
  end
  
  total_chunks = docs.sum { |d| d[:chunk_count] }
  response += "\nTotal: #{total_chunks} chunks\n"
  response += "Use /delete_doc <filename> to remove"
  
  send_response(bot, message.chat.id, response)
end

def handle_delete_doc(bot, message, file_name, db_manager)
  LOGGER.info "Delete document requested: #{file_name} by user #{message.from.username || message.from.id}"
  
  docs = db_manager.list_documents
  doc = docs.find { |d| d[:file_name] == file_name }
  
  if doc.nil?
    send_response(bot, message.chat.id, "❌ Document '#{file_name}' not found.\nUse /list_docs to see available documents.")
    return
  end
  
  response = "⚠️ Delete #{file_name} (#{doc[:chunk_count]} chunks)?\n"
  response += "Reply with /confirm_delete #{file_name}"
  
  send_response(bot, message.chat.id, response)
end

def confirm_delete_doc(bot, message, file_name, db_manager)
  LOGGER.info "Confirming delete: #{file_name} by user #{message.from.username || message.from.id}"
  
  deleted_count = db_manager.delete_document(file_name)
  
  if deleted_count > 0
    send_response(bot, message.chat.id, "✅ Deleted #{file_name} (#{deleted_count} chunks removed)")
  else
    send_response(bot, message.chat.id, "❌ Document not found or already deleted")
  end
end

def handle_clear_all(bot, message)
  LOGGER.info "Clear all requested by user #{message.from.username || message.from.id}"
  
  response = "⚠️ This will delete ALL documents!\n"
  response += "Reply with /confirm_clear_all to proceed"
  
  send_response(bot, message.chat.id, response)
end

def confirm_clear_all(bot, message, db_manager)
  LOGGER.info "Confirming clear all by user #{message.from.username || message.from.id}"
  
  deleted_count = db_manager.clear_all_documents
  
  send_response(bot, message.chat.id, "✅ Cleared all documents (#{deleted_count} chunks removed)")
end

def handle_stats(bot, message, db_manager)
  LOGGER.info "Stats requested by user #{message.from.username || message.from.id}"
  
  stats = db_manager.get_stats
  
  response = "📊 Database Statistics:\n\n"
  response += "- Total documents: #{stats[:total_documents]}\n"
  response += "- Total chunks: #{stats[:total_chunks]}\n"
  response += "- Database size: #{stats[:db_size_mb]} MB\n"
  
  if stats[:last_update]
    last_update = Time.parse(stats[:last_update]).strftime('%Y-%m-%d %H:%M')
    response += "- Last update: #{last_update}"
  end
  
  send_response(bot, message.chat.id, response)
end

def handle_help(bot, message)
  LOGGER.info "Help requested by user #{message.from.username || message.from.id}"
  
  help_text = <<~HELP
    📚 RAG Bot Commands:

    📄 Document Management:
    • Upload PDF or TXT file - Just send a document
    • /list_docs - Show all loaded documents
    • /delete_doc <filename> - Delete specific document
    • /stats - Show database statistics
    • /clear_all - Clear all documents (with confirmation)

    💬 Query Commands:
    • /question2 <your question> - Ask questions about loaded documents

    ℹ️ Info Commands:
    • /help or /menu - Show this help message
    • /start - Start the bot
    • /end - End session

    💡 Tip: Press "/" to see all commands in Telegram menu!
  HELP
  
  send_response(bot, message.chat.id, help_text)
end

def setup_bot_commands(bot)
  commands = [
    { command: 'start', description: 'Start the bot' },
    { command: 'help', description: 'Show all available commands' },
    { command: 'question2', description: 'Ask a question about documents' },
    { command: 'list_docs', description: 'List all loaded documents' },
    { command: 'delete_doc', description: 'Delete a document by filename' },
    { command: 'stats', description: 'Show database statistics' },
    { command: 'clear_all', description: 'Clear all documents' }
  ]
  
  bot.api.set_my_commands(commands: commands)
  LOGGER.info "Bot commands menu configured"
rescue Telegram::Bot::Exceptions::ResponseError => e
  LOGGER.warn "Failed to set bot commands: #{e.message}"
end

def send_response(bot, chat_id, text)
  bot.api.send_message(chat_id: chat_id, text: text)
rescue Telegram::Bot::Exceptions::ResponseError => e
  LOGGER.error "Error sending message: #{e.message}"
end

Telegram::Bot::Client.run(TOKEN) do |bot|
  LOGGER.info "Bot started successfully"
  
  # Setup Bot Commands Menu (appears when user presses "/")
  setup_bot_commands(bot)
  
  llm_service = LocalLLMRubyService.new
  db_manager = DatabaseManager.new
  embedding_service = EmbeddingService.new
  http_client = create_faraday_client

  bot.listen do |message|
    next unless message.is_a?(Telegram::Bot::Types::Message)

    handle_message(bot, message, llm_service, db_manager, embedding_service, http_client)
  end
end