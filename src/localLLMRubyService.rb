require 'candle'

class LocalLLMRubyService
  def initialize
    @llm = Candle::LLM.from_pretrained("Qwen/Qwen2.5-1.5B-Instruct-GGUF",
                                       device: Candle::Device.best,
                                       gguf_file: "qwen2.5-1.5b-instruct-q2_k.gguf")
  end

  def generate_response(text)
    begin
      request_body = [{ role: "user", content: text }]
      @llm.chat(request_body)
    rescue Exception => e
      e
    end
  end
end