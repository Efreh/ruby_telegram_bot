require 'candle'

class LocalLLMRubyService
  def initialize
    @llm = Candle::LLM.from_pretrained("deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B", device: Candle::Device.best)
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