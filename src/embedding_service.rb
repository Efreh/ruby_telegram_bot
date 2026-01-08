require 'candle'
require 'pdf-reader'

class EmbeddingService
  CHUNK_SIZE = 300
  OVERLAP = 50

  def initialize
    @model = Candle::EmbeddingModel.from_pretrained(
      "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
      device: Candle::Device.best,
      model_type: "minilm"
    )
  end

  def embed(text)
    embedding_tensor = @model.embedding(text, pooling_method: "pooled_normalized")
    embedding_tensor.values
  end

  def parse_pdf(file_path)
    text = ""
    begin
      reader = PDF::Reader.new(file_path)

      reader.pages.each do |page|
        text += page.text + "\n"
      end
    rescue PDF::Reader::MalformedPDFError => e
      raise "PDF file is corrupt: #{e.message}"
    rescue PDF::Reader::EncryptedPDFError => e
      raise "PDF file with password"
    rescue => e
      raise "error write PDF: #{e.message}"
    end
    text
  end

  def chunk_text(text, chunk_size, overlap)
    chunks = []
    start = 0

    while start < text.length
      chunk = text[start, chunk_size]
      chunks << chunk.strip if chunk.strip.length > 0
      start += chunk_size - overlap
    end
    chunks
  end

  def process_and_save_document(file_path, document_id, file_name, db_manager)
    text = parse_pdf(file_path)

    raise "Document is empty" if text.strip.empty?

    chunks = chunk_text(text, CHUNK_SIZE, OVERLAP)

    raise "Not contain chunks" if chunks.empty?

    chunks.each_with_index do |chunk_text, index|
      embedding = embed(chunk_text)
      db_manager.save_chunk(document_id, index, chunk_text, embedding, file_name)
    end
    chunks.length
  end

end