# frozen_string_literal: true

module DatabaseRewinder
  VERSION = Gem.loaded_specs['database_rewinder'].version.to_s

  class << self
    # Set your DB configuration here if you'd like to use something else than the AR configuration
    attr_writer :database_configuration

    def init
      @cleaners, @table_names_cache, @clean_all, @only, @except, @database_configuration = [], {}, false
    end

    def database_configuration
      @database_configuration || ActiveRecord::Base.configurations
    end

    def create_cleaner(connection_name)
      config = get_config_from(connection_name) or raise %Q[Database configuration named "#{connection_name}" is not configured.]

      Cleaner.new(config: config, connection_name: connection_name, only: @only, except: @except).tap {|c| @cleaners << c}
    end

    def create_cleaners(connection_name)
      configs = get_configs_from(connection_name)
      raise %Q[Database configuration named "#{connection_name}" is not configured.] if configs.empty?

      configs.each do |config|
        Cleaner.new(config: config, connection_name: connection_name, only: @only, except: @except).tap {|c| @cleaners << c}
      end
    end

    def [](connection)
      @cleaners.detect {|c| c.connection_name == connection} || create_cleaner(connection)
    end

    def all=(v)
      @clean_all = v
    end

    def cleaners
      create_cleaner 'test' if @cleaners.empty?
      @cleaners
    end

    def record_inserted_table(connection, sql)
      config = connection.instance_variable_get(:'@config')
      database = config[:database]
      #NOTE What's the best way to get the app dir besides Rails.root? I know Dir.pwd here might not be the right solution, but it should work in most cases...
      root_dir = defined?(Rails) && Rails.respond_to?(:root) ? Rails.root : Dir.pwd
      cleaner = cleaners.detect do |c|
        if (config[:adapter] == 'sqlite3') && (config[:database] != ':memory:')
          File.expand_path(c.db, root_dir) == File.expand_path(database, root_dir)
        else
          c.db == database
        end
      end or return

      sql.split(';').each do |statement|
        match = statement.match(/\A\s*INSERT(?:\s+IGNORE)?(?:\s+INTO)?\s+(?:\.*[`"]?([^.\s`"(]+)[`"]?)*/i)
        next unless match

        table = match[1]
        if table
          cleaner.inserted_tables << table unless cleaner.inserted_tables.include? table
          cleaner.pool ||= connection.pool
        end
      end
    end

    def clean(multiple: true)
      if @clean_all
        clean_all multiple: multiple
      else
        cleaners.each {|c| c.clean multiple: multiple}
      end
    end

    def clean_all(multiple: true)
      cleaners.each {|c| c.clean_all multiple: multiple}
    end

    # cache AR connection.tables
    def all_table_names(connection)
      cache_key = get_cache_key(connection.pool)
      #NOTE connection.tables warns on AR 5 with some adapters
      tables = ActiveSupport::Deprecation.silence { connection.tables }
      @table_names_cache[cache_key] ||= tables.reject do |t|
        (t == ActiveRecord::SchemaMigration.table_name) ||
        (ActiveRecord::Base.respond_to?(:internal_metadata_table_name) && (t == ActiveRecord::Base.internal_metadata_table_name))
      end
    end

    def get_config_from(connection_name)
      if Gem::Version.new(Rails.version) >= Gem::Version.new("6.0.0")
        database_configuration.configs_for(env_name: connection_name).first.configuration_hash
      else
        database_configuration[connection_name]
      end
    end

    def get_configs_from(connection_name)
      database_configuration.configs_for(env_name: connection_name).map(&:configuration_hash)
    end

    def get_cache_key(connection_pool)
      if connection_pool.respond_to?(:db_config) # ActiveRecord >= 6.1
        if Gem::Version.new(Rails.version) >= Gem::Version.new("6.0.0")
          connection_pool.db_config.configuration_hash
        else
          connection_pool.db_config.config
        end
      else
        connection_pool.spec.config
      end
    end
  end

  private_class_method :get_config_from, :get_cache_key
end

begin
  require 'rails'
  require_relative 'database_rewinder/railtie'
rescue LoadError
  DatabaseRewinder.init
  require_relative 'database_rewinder/active_record_monkey'
  require_relative 'database_rewinder/cleaner'
end
