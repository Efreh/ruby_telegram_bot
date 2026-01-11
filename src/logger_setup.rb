require 'logger'

module AppLogger
  def self.setup
    logger = Logger.new($stdout)
    logger.level = ENV['LOG_LEVEL']&.upcase == 'DEBUG' ? Logger::DEBUG : Logger::INFO
    logger.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
    end
    logger
  end
end

LOGGER = AppLogger.setup
