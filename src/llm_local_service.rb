require 'candle'
require_relative 'logger_setup'

class LocalLLMRubyService
  def initialize
    # PRODUCTION: 1 core, 2GB RAM - lightweight model
     @llm = Candle::LLM.from_pretrained(
       "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
       device: Candle::Device.best,
       gguf_file: "qwen2.5-0.5b-instruct-q4_k_m.gguf"  # ~300 MB
     )
    
    # LOCAL DEV: 12 cores, 32GB RAM
    #@llm = Candle::LLM.from_pretrained(
    #  "Qwen/Qwen2.5-7B-Instruct-GGUF",
    #  device: Candle::Device.best,
    #  gguf_file: "qwen2.5-7b-instruct-q2_k.gguf"  # ~3 GB
    #)
    
    # Alternative: Qwen 7B Q4_K_M - better quality (~4.5GB)
    # @llm = Candle::LLM.from_pretrained(
    #   "Qwen/Qwen2.5-7B-Instruct-GGUF",
    #   device: Candle::Device.best,
    #   gguf_file: "qwen2.5-7b-instruct-q4_k_m.gguf"  # ~4.5 GB
    # )
    
    LOGGER.info "LLM model loaded: Qwen 7B Q2_K"
  end

  def generate_response(text)
    request_body = [{ role: "user", content: text }]
    @llm.chat(request_body)
  rescue StandardError => e
    "Error: #{e.message}"
  end

  def generate_rag_response(question, context_chunks)
    return "No relevant documents found" if context_chunks.empty?

    LOGGER.debug "Generating RAG response with #{context_chunks.length} chunks"
    
    context = context_chunks.map.with_index do |chunk, idx|
      "[Fragment #{idx + 1}]\n#{chunk[:chunk_text]}\n"
    end.join("\n")

    system_instruction = <<~PROMPT
      You are an assistant that answers STRICTLY based on the provided context.
      
      RULES:
      1. Use ONLY information from the context below
      2. If there's no answer in the context — say "There is no information on this question in the documents"
      3. DO NOT make up facts and DO NOT use general knowledge
      4. Answer briefly and to the point
    PROMPT

    user_message = <<~PROMPT
      CONTEXT:
      #{context}
      
      QUESTION: #{question}
    PROMPT

    request_body = [
      { role: "system", content: system_instruction },
      { role: "user", content: user_message }
    ]
    config = Candle::GenerationConfig.balanced(max_length: 2000)
    
    start_time = Time.now
    response = @llm.chat(request_body, config: config)
    generation_time = Time.now - start_time
    
    LOGGER.debug "LLM response generated in #{generation_time.round(2)}s"
    response
  rescue StandardError => e
    LOGGER.error "Error generating response: #{e.message}"
    "Error generating response: #{e.message}"
  end
end