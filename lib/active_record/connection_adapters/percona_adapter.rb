# frozen_string_literal: true

require 'active_record/connection_adapters/abstract_mysql_adapter'
require 'active_record/connection_adapters/statement_pool'
require 'active_record/connection_adapters/mysql2_adapter'
require 'departure'
require 'forwardable'

module ActiveRecord
  module ConnectionHandling
    # Establishes a connection to the database that's used by all Active
    # Record objects.
    def percona_connection(config)
      config[:username] = 'root' if config[:username].nil?
      mysql2_connection = mysql2_connection(config)

      connection_details = Departure::ConnectionDetails.new(config)
      verbose = ActiveRecord::Migration.verbose
      sanitizers = [
        Departure::LogSanitizers::PasswordSanitizer.new(connection_details)
      ]
      percona_logger = Departure::LoggerFactory.build(sanitizers: sanitizers, verbose: verbose)
      cli_generator = Departure::CliGenerator.new(connection_details)

      runner = Departure::Runner.new(
        percona_logger,
        cli_generator,
        mysql2_connection
      )

      connection_options = { mysql_adapter: mysql2_connection }

      ConnectionAdapters::DepartureAdapter.new(
        runner,
        logger,
        connection_options,
        config
      )
    end
  end

  module ConnectionAdapters
    class DepartureAdapter < AbstractMysqlAdapter
      class Column < ActiveRecord::ConnectionAdapters::MySQL::Column
        def adapter
          DepartureAdapter
        end
      end

      class SchemaCreation < ActiveRecord::ConnectionAdapters::MySQL::SchemaCreation
        def visit_DropForeignKey(name) # rubocop:disable Naming/MethodName
          fk_name =
            if name =~ /^__(.+)/
              Regexp.last_match(1)
            else
              "_#{name}"
            end

          "DROP FOREIGN KEY #{fk_name}"
        end
      end

      extend Forwardable

      include ForAlterStatements unless method_defined?(:change_column_for_alter)

      ADAPTER_NAME = 'Percona'

      def_delegators :mysql_adapter, :last_inserted_id, :each_hash, :set_field_encoding

      def initialize(connection, _logger, connection_options, _config)
        @mysql_adapter = connection_options[:mysql_adapter]
        super
        @prepared_statements = false
      end

      def exec_delete(sql, name, binds = [])
        if without_prepared_statement?(binds)
          @lock.synchronize do
            execute_and_free(sql, name) { @connection.affected_rows }
          end
        else
          exec_stmt_and_free(sql, name, binds, &:affected_rows)
        end
      end
      alias exec_update exec_delete

      def exec_query(sql, name = 'SQL', binds = [], prepare: false)
        if without_prepared_statement?(binds)
          execute_and_free(sql, name) do |result|
            if result
              ActiveRecord::Result.new(result.fields, result.to_a)
            else
              ActiveRecord::Result.new([], [])
            end
          end
        else
          exec_stmt_and_free(sql, name, binds, cache_stmt: prepare) do |_, result|
            if result
              ActiveRecord::Result.new(result.fields, result.to_a)
            else
              ActiveRecord::Result.new([], [])
            end
          end
        end
      end

      # Executes a SELECT query and returns an array of rows. Each row is an
      # array of field values.

      def select_rows(arel, name = nil, binds = [])
        select_all(arel, name, binds).rows
      end

      # Executes a SELECT query and returns an array of record hashes with the
      # column names as keys and column values as values.
      def select(sql, name = nil, binds = [])
        exec_query(sql, name, binds)
      end

      # Returns true, as this adapter supports migrations
      def supports_migrations?
        true
      end

      # rubocop:disable Metrics/ParameterLists
      def new_column(field, default, type_metadata, null, table_name, default_function, collation, comment)
        Column.new(field, default, type_metadata, null, table_name, default_function, collation, comment)
      end
      # rubocop:enable Metrics/ParameterLists

      # Adds a new index to the table
      #
      # @param table_name [String, Symbol]
      # @param column_name [String, Symbol]
      # @param options [Hash] optional
      def add_index(table_name, column_name, options = {})
        index_name, index_type, index_columns, index_options = add_index_options(table_name, column_name, options)
        execute "ALTER TABLE #{quote_table_name(table_name)} ADD #{index_type} INDEX #{quote_column_name(index_name)} (#{index_columns})#{index_options}" # rubocop:disable Metrics/LineLength
      end

      # Remove the given index from the table.
      #
      # @param table_name [String, Symbol]
      # @param options [Hash] optional
      def remove_index(table_name, options = {})
        index_name = index_name_for_remove(table_name, options)
        execute "ALTER TABLE #{quote_table_name(table_name)} DROP INDEX #{quote_column_name(index_name)}"
      end

      def schema_creation
        SchemaCreation.new(self)
      end

      def change_table(table_name, _options = {})
        recorder = ActiveRecord::Migration::CommandRecorder.new(self)
        yield update_table_definition(table_name, recorder)
        bulk_change_table(table_name, recorder.commands)
      end

      # Returns the MySQL error number from the exception. The
      # AbstractMysqlAdapter requires it to be implemented
      def error_number(_exception); end

      def get_full_version
        mysql_adapter.raw_connection.server_info[:version]
      end

      def full_version
        schema_cache.database_version.full_version_string
      end

      def exec_stmt_and_free(sql, name, binds, cache_stmt: false)
        if preventing_writes? && write_query?(sql)
          raise ActiveRecord::ReadOnlyError, "Write query attempted while in readonly mode: #{sql}"
        end

        materialize_transactions

        type_casted_binds = type_casted_binds(binds)

        log(sql, name, binds, type_casted_binds) do
          stmt = if cache_stmt
                   @statements[sql] ||= @connection.prepare(sql)
                 else
                   @connection.prepare(sql)
                 end

          begin
            result = ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
              stmt.execute(*type_casted_binds)
            end
          rescue Mysql2::Error => e
            if cache_stmt
              @statements.delete(sql)
            else
              stmt.close
            end
            raise e
          end

          ret = yield stmt, result
          result&.free
          stmt.close unless cache_stmt
          ret
        end
      end

      private

      attr_reader :mysql_adapter
    end
  end
end
