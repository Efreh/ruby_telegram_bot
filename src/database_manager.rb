require 'sqlite3'
require 'fileutils'

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

  private

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
  end
end