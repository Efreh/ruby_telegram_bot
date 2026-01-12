require 'candle'
require 'pdf-reader'
require_relative 'logger_setup'

class EmbeddingService
  CHUNK_SIZE = 1000
  OVERLAP = 200

  def initialize
    # PRODUCTION (1 core, 2GB RAM): Lightweight fast model ~200MB
    @model = Candle::EmbeddingModel.from_pretrained(
      "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
      device: Candle::Device.best,
      model_type: "minilm"
    )
    
    # Alternative lightweight option (English only):
    # @model = Candle::EmbeddingModel.from_pretrained(
    #   "sentence-transformers/all-MiniLM-L6-v2",
    #   device: Candle::Device.best,
    #   model_type: "minilm"
    # )
    
    # LOCAL DEV (12 cores, 32GB RAM): Better accuracy model ~2GB
    # @model = Candle::EmbeddingModel.from_pretrained(
    #   "intfloat/multilingual-e5-large",
    #   device: Candle::Device.best,
    #   model_type: "standard_bert"
    # )
    
    LOGGER.info "Embedding model loaded: paraphrase-multilingual-MiniLM-L12-v2"
  end

  def embed(text)
    embedding_tensor = @model.embedding(text, pooling_method: "pooled_normalized")
    embedding_tensor.values
  end

  def parse_pdf(file_path)
    reader = PDF::Reader.new(file_path)
    reader.pages.map(&:text).join("\n")
  rescue PDF::Reader::MalformedPDFError => e
    raise "PDF file is corrupt: #{e.message}"
  rescue PDF::Reader::EncryptedPDFError => e
    raise "PDF file is password protected"
  rescue StandardError => e
    raise "Error parsing PDF: #{e.message}"
  end

  def parse_txt(file_path)
    binary_data = File.binread(file_path)
    
    ['Windows-1251', 'UTF-8', 'CP866'].each do |encoding|
      begin
        text = binary_data.dup.force_encoding(encoding).encode('UTF-8', invalid: :replace, undef: :replace)
        return text if text.valid_encoding? && text.count('?').to_f / [text.length, 1].max <= 0.05
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        next
      end
    end
    
    binary_data.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
  rescue StandardError => e
    raise "Error reading TXT file: #{e.message}"
  end

  def chunk_text(text, chunk_size, overlap)
    chunks = []
    start = 0

    while start < text.length
      chunk = text[start, chunk_size]
      chunks << chunk.strip unless chunk.strip.empty?
      start += chunk_size - overlap
    end
    chunks
  end

  def process_and_save_document(file_path, document_id, file_name, db_manager, mime_type = 'application/pdf')
    start_time = Time.now
    LOGGER.info "Processing document: #{file_name} (#{mime_type})"
    
    text = case mime_type
           when 'application/pdf'
             parse_pdf(file_path)
           when 'text/plain'
             parse_txt(file_path)
           else
             raise "Unsupported file type: #{mime_type}"
           end

    raise "Document is empty" if text.strip.empty?

    chunks = chunk_text(text, CHUNK_SIZE, OVERLAP)

    raise "No chunks created" if chunks.empty?
    
    chunk_sizes = chunks.map(&:length)
    LOGGER.info "Created #{chunks.length} chunks (min: #{chunk_sizes.min}, max: #{chunk_sizes.max}, avg: #{chunk_sizes.sum / chunks.length})"

    chunks.each_with_index do |chunk_text, index|
      embedding = embed(chunk_text)
      db_manager.save_chunk(document_id, index, chunk_text, embedding, file_name)
    end
    
    processing_time = Time.now - start_time
    LOGGER.info "Document processed in #{processing_time.round(2)}s"
    
    chunks.length
  end

end