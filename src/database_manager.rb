require 'sqlite3'
require 'fileutils'
require_relative 'logger_setup'

class DatabaseManager
  def initialize(db_path = 'data/documents.db')
    @db_path = db_path
    ensure_directory_exist
    @db = SQLite3::Database.new(@db_path)
    @db.results_as_hash = true
    create_tables
  end

  def save_chunk(document_id, chunk_index, chunk_text, embedding, file_name = nil)
    raise ArgumentError, "Embedding cannot be empty" if embedding.nil? || embedding.empty?

    embedding_blob = embedding.pack('f*')
    embedding_dim = embedding.length

    @db.execute(
      "INSERT OR REPLACE INTO document_chunks
     (document_id, file_name, chunk_index, chunk_text, embedding, embedding_dim)
     VALUES (?, ?, ?, ?, ?, ?)",
      [document_id, file_name, chunk_index, chunk_text, embedding_blob, embedding_dim]
    )

    @db.last_insert_row_id
  end

  def find_similar_chunks(query_embedding, top_k = 3, min_similarity: 0.65)
    start_time = Time.now
    
    # Step 1: Get only embeddings and ids (without chunk_text for performance)
    query = "SELECT id, document_id, file_name, embedding FROM document_chunks"
    rows = @db.execute(query)
    
    LOGGER.debug "Loaded #{rows.length} chunks for similarity search"
    
    # Step 2: Calculate similarity for all vectors
    results = rows.map do |row|
      stored_embedding = row['embedding'].unpack('f*')
      similarity = cosine_similarity(query_embedding, stored_embedding)
      
      {
        id: row['id'],
        document_id: row['document_id'],
        file_name: row['file_name'],
        similarity: similarity
      }
    end
    
    # Step 3: Filter by min_similarity
    filtered = results.select { |r| r[:similarity] >= min_similarity }
    
    # Step 4: Sort and take top_k
    top_results = filtered.sort_by { |r| -r[:similarity] }.take(top_k)
    
    # Step 5: Load full data (with chunk_text) only for top_k
    if top_results.empty?
      search_time = Time.now - start_time
      LOGGER.info "No chunks found above similarity threshold #{min_similarity} (searched in #{search_time.round(3)}s)"
      return []
    end
    
    ids = top_results.map { |r| r[:id] }
    placeholders = ids.map { '?' }.join(',')
    full_query = "SELECT id, document_id, file_name, chunk_text FROM document_chunks WHERE id IN (#{placeholders})"
    full_rows = @db.execute(full_query, ids)
    
    # Merge full data with similarity scores
    final_results = top_results.map do |result|
      full_row = full_rows.find { |r| r['id'] == result[:id] }
      result.merge(chunk_text: full_row['chunk_text'])
    end
    
    search_time = Time.now - start_time
    similarities = final_results.map { |r| r[:similarity].round(3) }
    LOGGER.info "Found #{final_results.length} relevant chunks (similarities: #{similarities.inspect}) in #{search_time.round(3)}s"
    LOGGER.debug "Filtered #{rows.length - filtered.length} chunks below threshold #{min_similarity}"
    
    final_results
  end

  def list_documents
    query = <<-SQL
      SELECT 
        document_id,
        file_name,
        COUNT(*) as chunk_count,
        MAX(created_at) as last_update
      FROM document_chunks
      GROUP BY document_id, file_name
      ORDER BY last_update DESC
    SQL
    
    rows = @db.execute(query)
    LOGGER.debug "Listed #{rows.length} documents"
    
    rows.map do |row|
      {
        document_id: row['document_id'],
        file_name: row['file_name'],
        chunk_count: row['chunk_count'],
        last_update: row['last_update']
      }
    end
  end

  def delete_document(file_name)
    query = "DELETE FROM document_chunks WHERE file_name = ?"
    @db.execute(query, [file_name])
    deleted_count = @db.changes
    LOGGER.info "Deleted document: #{file_name} (#{deleted_count} chunks removed)"
    deleted_count
  end

  def clear_all_documents
    @db.execute("DELETE FROM document_chunks")
    deleted_count = @db.changes
    LOGGER.info "Cleared all documents (#{deleted_count} chunks removed)"
    deleted_count
  end

  def get_stats
    total_docs = @db.execute("SELECT COUNT(DISTINCT document_id) as count FROM document_chunks")[0]['count']
    total_chunks = @db.execute("SELECT COUNT(*) as count FROM document_chunks")[0]['count']
    
    db_size_bytes = File.size(@db_path) if File.exist?(@db_path)
    db_size_mb = db_size_bytes ? (db_size_bytes / 1024.0 / 1024.0).round(2) : 0
    
    last_update = @db.execute("SELECT MAX(created_at) as last FROM document_chunks")[0]['last']
    
    stats = {
      total_documents: total_docs,
      total_chunks: total_chunks,
      db_size_mb: db_size_mb,
      last_update: last_update
    }
    
    LOGGER.debug "Database stats: #{stats.inspect}"
    stats
  end

  private

  def cosine_similarity(vec_a, vec_b)
    dot_product = vec_a.zip(vec_b).map { |a, b| a * b }.sum
    norm_a = Math.sqrt(vec_a.map { |x| x ** 2 }.sum)
    norm_b = Math.sqrt(vec_b.map { |x| x ** 2 }.sum)

    return 0.0 if norm_a == 0.0 || norm_b == 0.0

    dot_product / (norm_a * norm_b)
  end

  def ensure_directory_exist
    dir = File.dirname(@db_path)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
  end

  def create_tables
    @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS document_chunks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id TEXT NOT NULL,
            file_name TEXT,
            chunk_index INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            embedding BLOB,
            embedding_dim INTEGER,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (document_id, chunk_index)
        )
    SQL

    @db.execute <<-SQL
        CREATE INDEX IF NOT EXISTS idx_document_id
        ON document_chunks(document_id)
    SQL
    
    @db.execute <<-SQL
        CREATE INDEX IF NOT EXISTS idx_file_name
        ON document_chunks(file_name)
    SQL
    
    @db.execute <<-SQL
        CREATE INDEX IF NOT EXISTS idx_created_at
        ON document_chunks(created_at)
    SQL
  end
end