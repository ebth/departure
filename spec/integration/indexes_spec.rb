# frozen_string_literal: true

require 'spec_helper'

describe Departure, integration: true do
  class Comment < ActiveRecord::Base
  end

  let(:schema_migration) { ActiveRecord::Base.connection.schema_migration }

  let(:migration_fixtures) do
    ActiveRecord::MigrationContext.new([MIGRATION_FIXTURES], schema_migration).migrations
  end

  let(:migration_paths) { [MIGRATION_FIXTURES] }

  let(:direction) { :up }

  context 'managing indexes' do
    let(:version) { 2 }

    context 'adding indexes' do
      let(:direction) { :up }

      # TODO: Create it directly like this?
      before do
        ActiveRecord::Migrator.new(
          direction,
          migration_fixtures,
          schema_migration,
          1
        ).migrate
      end

      it 'executes the percona command' do
        ActiveRecord::Migrator.new(
          direction,
          migration_fixtures,
          schema_migration,
          version
        ).migrate

        expect(:comments).to have_index('index_comments_on_some_id_field')
      end

      it 'marks the migration as up' do
        ActiveRecord::Migrator.new(
          direction,
          migration_fixtures,
          schema_migration,
          version
        ).migrate

        expect(ActiveRecord::Migrator.current_version).to eq(version)
      end
    end

    context 'removing indexes' do
      let(:direction) { :down }

      before do
        ActiveRecord::Migrator.new(
          :up,
          migration_fixtures,
          schema_migration,
          1
        ).migrate

        ActiveRecord::Migrator.new(
          :up,
          migration_fixtures,
          schema_migration,
          version
        ).migrate
      end

      it 'executes the percona command' do
        ActiveRecord::Migrator.new(
          direction,
          migration_fixtures,
          schema_migration,
          version - 1
        ).migrate

        expect(:comments).not_to have_index('index_comments_on_some_id_field')
      end

      it 'marks the migration as down' do
        ActiveRecord::Migrator.new(
          direction,
          migration_fixtures,
          schema_migration,
          version - 1
        ).migrate

        expect(ActiveRecord::Migrator.current_version).to eq(1)
      end
    end

    context 'renaming indexes' do
      let(:direction) { :up }
      let(:version) { 13 }

      before do
        ActiveRecord::Migrator.new(:up, migration_fixtures, schema_migration, 2).migrate
      end

      it 'executes the percona command' do
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(direction, version)
        expect(:comments).to have_index('new_index_comments_on_some_id_field')
      end

      it 'marks the migration as down' do
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(direction, version)
        expect(ActiveRecord::Migrator.current_version).to eq(version)
      end
    end
  end

  context 'adding/removing unique indexes' do
    let(:version) { 3 }

    context 'adding indexes' do
      let(:direction) { :up }

      before do
        ActiveRecord::Migrator.new(:up, migration_fixtures, schema_migration, 1).migrate
      end

      it 'executes the percona command' do
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(direction, version)

        expect(unique_indexes_from(:comments))
            .to match_array(['index_comments_on_some_id_field'])
      end

      it 'marks the migration as up' do
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(direction, version)
        expect(ActiveRecord::Migrator.current_version).to eq(version)
      end
    end

    context 'removing indexes' do
      let(:direction) { :down }

      before do
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(:up, 1)
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(:up, version)
      end

      it 'executes the percona command' do
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(direction, version)

        expect(unique_indexes_from(:comments))
            .not_to match_array(['index_comments_on_some_id_field'])
      end

      it 'marks the migration as down' do
        ActiveRecord::MigrationContext.new(migration_paths, schema_migration).run(direction, version)
        expect(ActiveRecord::Migrator.current_version).to eq(1)
      end
    end
  end
end
