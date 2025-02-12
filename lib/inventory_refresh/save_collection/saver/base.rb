require "inventory_refresh/application_record_iterator"
require "inventory_refresh/logging"
require "inventory_refresh/save_collection/saver/sql_helper"
require "active_support/core_ext/module/delegation"

module InventoryRefresh::SaveCollection
  module Saver
    class Base
      include InventoryRefresh::Logging
      include InventoryRefresh::SaveCollection::Saver::SqlHelper

      # @param inventory_collection [InventoryRefresh::InventoryCollection] InventoryCollection object we will be saving
      def initialize(inventory_collection)
        @inventory_collection = inventory_collection
        # TODO(lsmola) do I need to reload every time? Also it should be enough to clear the associations.
        inventory_collection.parent&.reload
        @association = inventory_collection.db_collection_for_comparison

        # Private attrs
        @model_class            = inventory_collection.model_class
        @table_name             = @model_class.table_name
        @q_table_name           = get_connection.quote_table_name(@table_name)
        @primary_key            = @model_class.primary_key
        @arel_primary_key       = @model_class.arel_table[@primary_key]
        @unique_index_keys      = inventory_collection.unique_index_keys
        @unique_index_keys_to_s = inventory_collection.manager_ref_to_cols.map(&:to_s)
        @select_keys            = [@primary_key] + @unique_index_keys_to_s + internal_columns.map(&:to_s)
        @unique_db_primary_keys = Set.new
        @unique_db_indexes      = Set.new

        # Right now ApplicationRecordIterator in association is used for targeted refresh. Given the small amount of
        # records flowing through there, we probably don't need to optimize that association to fetch a pure SQL.
        @pure_sql_records_fetching = !inventory_collection.use_ar_object? && !@association.kind_of?(InventoryRefresh::ApplicationRecordIterator)

        @batch_size_for_persisting = inventory_collection.batch_size_pure_sql

        @batch_size          = @pure_sql_records_fetching ? @batch_size_for_persisting : inventory_collection.batch_size
        @record_key_method   = @pure_sql_records_fetching ? :pure_sql_record_key : :ar_record_key
        @select_keys_indexes = @select_keys.each_with_object({}).with_index { |(key, obj), index| obj[key.to_s] = index }
        @pg_types            = @model_class.attribute_names.each_with_object({}) do |key, obj|
          obj[key.to_sym] = inventory_collection.model_class.columns_hash[key]
                                                .try(:sql_type_metadata)
                                                .try(:instance_values)
                                                .try(:[], "sql_type")
        end

        @serializable_keys = {}
        @deserializable_keys = {}
        @model_class.attribute_names.each do |key|
          attribute_type = @model_class.type_for_attribute(key.to_s)
          pg_type        = @pg_types[key.to_sym]

          if inventory_collection.use_ar_object?
            # When using AR object, lets make sure we type.serialize(value) every value, so we have a slow but always
            # working way driven by a configuration
            @serializable_keys[key.to_sym] = attribute_type
            @deserializable_keys[key.to_sym] = attribute_type
          elsif attribute_type.respond_to?(:coder) ||
                attribute_type.type == :int4range ||
                attribute_type.type == :jsonb ||
                pg_type == "text[]" ||
                pg_type == "character varying[]"
            # Identify columns that needs to be encoded by type.serialize(value), it's a costy operations so lets do
            # do it only for columns we need it for.
            # TODO: should these set @deserializable_keys too?
            @serializable_keys[key.to_sym] = attribute_type
          elsif attribute_type.type == :decimal
            # Postgres formats decimal columns with fixed number of digits e.g. '0.100'
            # Need to parse and let Ruby format the value to have a comparable string.
            @serializable_keys[key.to_sym] = attribute_type
            @deserializable_keys[key.to_sym] = attribute_type
          end
        end
      end

      # Saves the InventoryCollection
      def save_inventory_collection!
        # If we have a targeted InventoryCollection that wouldn't do anything, quickly skip it
        return if inventory_collection.noop?

        # Delete_complement strategy using :all_manager_uuids attribute
        delete_complement unless inventory_collection.delete_complement_noop?

        # Create/Update/Archive/Delete records based on InventoryCollection data and scope
        save!(association) unless inventory_collection.saving_noop?
      end

      protected

      attr_reader :inventory_collection, :association

      delegate :build_stringified_reference,
               :build_stringified_reference_for_record,
               :resource_version_column,
               :internal_columns,
               :to => :inventory_collection

      # Applies serialize method for each relevant attribute, which will cast the value to the right type.
      #
      # @param all_attribute_keys [Symbol] attribute keys we want to process
      # @param attributes [Hash] attributes hash
      # @return [Hash] modified hash from parameter attributes with casted values
      def values_for_database!(all_attribute_keys, attributes)
        all_attribute_keys.each do |key|
          next unless attributes.key?(key)

          if (type = serializable_keys[key])
            attributes[key] = type.serialize(attributes[key])
          end
        end
        attributes
      end

      def transform_to_hash!(all_attribute_keys, hash)
        if inventory_collection.use_ar_object?
          record = inventory_collection.model_class.new(hash)
          values_for_database!(all_attribute_keys,
                               record.attributes.slice(*record.changed_attributes.keys).symbolize_keys)
        elsif serializable_keys?
          values_for_database!(all_attribute_keys,
                               hash)
        else
          hash
        end
      end

      private

      attr_reader :unique_index_keys, :unique_index_keys_to_s, :select_keys, :unique_db_primary_keys, :unique_db_indexes,
                  :primary_key, :arel_primary_key, :record_key_method, :pure_sql_records_fetching, :select_keys_indexes,
                  :batch_size, :batch_size_for_persisting, :model_class, :serializable_keys, :deserializable_keys, :pg_types, :table_name,
                  :q_table_name

      delegate :supports_column?, :to => :inventory_collection

      # Saves the InventoryCollection
      #
      # @param association [Symbol] An existing association on manager
      def save!(association)
        attributes_index        = {}
        inventory_objects_index = {}
        inventory_collection.each do |inventory_object|
          attributes = inventory_object.attributes(inventory_collection)
          index      = build_stringified_reference(attributes, unique_index_keys)

          attributes_index[index]        = attributes
          inventory_objects_index[index] = inventory_object
        end

        logger.debug("Processing #{inventory_collection} of size #{inventory_collection.size}...")
        # Records that are in the DB, we will be updating or deleting them.
        ActiveRecord::Base.transaction do
          association.find_each do |record|
            index = build_stringified_reference_for_record(record, unique_index_keys)

            next unless assert_distinct_relation(record.id)
            next unless assert_unique_record(record, index)

            inventory_object = inventory_objects_index.delete(index)
            hash             = attributes_index.delete(index)

            if inventory_object.nil?
              # Record was found in the DB but not sent for saving, that means it doesn't exist anymore and we should
              # delete it from the DB.
              delete_record!(record) if inventory_collection.delete_allowed?
            elsif assert_referential_integrity(hash)
              # Record was found in the DB and sent for saving, we will be updating the DB.
              update_record!(record, hash, inventory_object)
            end
          end
        end

        inventory_collection.custom_reconnect_block&.call(inventory_collection, inventory_objects_index, attributes_index)

        # Records that were not found in the DB but sent for saving, we will be creating these in the DB.
        if inventory_collection.create_allowed?
          ActiveRecord::Base.transaction do
            inventory_objects_index.each do |index, inventory_object|
              hash = attributes_index.delete(index)

              create_record!(hash, inventory_object) if assert_referential_integrity(hash)
            end
          end
        end
        logger.debug("Processing #{inventory_collection}, "\
                     "created=#{inventory_collection.created_records.count}, "\
                     "updated=#{inventory_collection.updated_records.count}, "\
                     "deleted=#{inventory_collection.deleted_records.count}...Complete")
      rescue => e
        logger.error("Error when saving #{inventory_collection} with #{inventory_collection_details}. Message: #{e.message}")
        raise e
      end

      # @return [String] a string for logging purposes
      def inventory_collection_details
        "strategy: #{inventory_collection.strategy}, saver_strategy: #{inventory_collection.saver_strategy}, targeted: #{inventory_collection.targeted?}"
      end

      # @param record [ApplicationRecord] ApplicationRecord object
      # @param key [Symbol] A key that is an attribute of the AR object
      # @return [Object] Value of attribute name :key on the :record
      def record_key(record, key)
        record.public_send(key)
      end

      # Deletes a complement of referenced data
      def delete_complement
        raise(":delete_complement method is supported only for :saver_strategy => [:batch, :concurrent_safe_batch]")
      end

      # Deletes/soft-deletes a given record
      #
      # @param [ApplicationRecord] record we want to delete
      def delete_record!(record)
        record.public_send(inventory_collection.delete_method)
        inventory_collection.store_deleted_records(record)
      end

      # @return [TrueClass] always return true, this method is redefined in default saver
      def assert_unique_record(_record, _index)
        # TODO(lsmola) can go away once we indexed our DB with unique indexes
        true
      end

      # Check if relation provided is distinct, i.e. the relation should not return the same primary key value twice.
      #
      # @param primary_key_value [Bigint] primary key value
      # @raise [Exception] if env is not production and relation is not distinct
      # @return [Boolean] false if env is production and relation is not distinct
      def assert_distinct_relation(primary_key_value)
        if unique_db_primary_keys.include?(primary_key_value) # Include on Set is O(1)
          # Change the InventoryCollection's :association or :arel parameter to return distinct results. The :through
          # relations can return the same record multiple times. We don't want to do SELECT DISTINCT by default, since
          # it can be very slow.
          if inventory_collection.assert_graph_integrity
            raise("Please update :association or :arel for #{inventory_collection} to return a DISTINCT result. ")
          else
            logger.warn("Please update :association or :arel for #{inventory_collection} to return a DISTINCT result. "\
                        " The duplicate value is being ignored.")
            return false
          end
        else
          unique_db_primary_keys << primary_key_value
        end
        true
      end

      # Check that the needed foreign key leads to real value. This check simulates NOT NULL and FOREIGN KEY constraints
      # we should have in the DB. The needed foreign keys are identified as fixed_foreign_keys, which are the foreign
      # keys needed for saving of the record.
      #
      # @param hash [Hash] data we want to save
      # @raise [Exception] if env is not production and a foreign_key is missing
      # @return [Boolean] false if env is production and a foreign_key is missing
      def assert_referential_integrity(hash)
        inventory_collection.fixed_foreign_keys.each do |x|
          next unless hash[x].nil?

          subject = "#{hash} of #{inventory_collection} because of missing foreign key #{x} for "\
                    "#{inventory_collection.parent.class.name}:"\
                    "#{inventory_collection.parent.try(:id)}"
          if inventory_collection.assert_graph_integrity
            raise("Referential integrity check violated for #{subject}")
          else
            logger.warn("Referential integrity check violated, ignoring #{subject}")
            return false
          end
        end
        true
      end

      # @return [Time] A rails friendly time getting config from ActiveRecord::Base.default_timezone (can be :local
      #         or :utc)
      def time_now
        if ActiveRecord::Base.default_timezone == :utc
          Time.now.utc
        else
          Time.zone.now
        end
      end

      # Enriches data hash with timestamp columns
      #
      # @param hash [Hash] data hash
      # @param update_time [Time] data hash
      def assign_attributes_for_update!(hash, update_time)
        hash[:type]         = model_class.name if supports_sti? && hash[:type].nil?
        hash[:updated_on]   = update_time if supports_column?(:updated_on)
        hash[:updated_at]   = update_time if supports_column?(:updated_at)
      end

      # Enriches data hash with timestamp and type columns
      #
      # @param hash [Hash] data hash
      # @param create_time [Time] data hash
      def assign_attributes_for_create!(hash, create_time)
        hash[:created_on]   = create_time if supports_column?(:created_on)
        hash[:created_at]   = create_time if supports_column?(:created_at)
        assign_attributes_for_update!(hash, create_time)
      end

      def internal_columns
        @internal_columns ||= inventory_collection.internal_columns
      end

      # Finds an index that fits the list of columns (keys) the best
      #
      # @param keys [Array<Symbol>]
      # @raise [Exception] if the unique index for the columns was not found
      # @return [ActiveRecord::ConnectionAdapters::IndexDefinition] unique index fitting the keys
      def unique_index_for(keys)
        inventory_collection.unique_index_for(keys)
      end

      # @return [Array<Symbol>] all columns that are part of the best fit unique index
      def unique_index_columns
        @unique_index_columns ||= inventory_collection.unique_index_columns
      end

      # @return [Array<String>] all columns that are part of the best fit unique index
      def unique_index_columns_to_s
        return @unique_index_columns_to_s if @unique_index_columns_to_s

        @unique_index_columns_to_s = unique_index_columns.map(&:to_s)
      end

      # @return [Boolean] true if the model_class supports STI
      def supports_sti?
        @supports_sti_cache ||= inventory_collection.supports_sti?
      end

      # @return [Boolean] true if any serializable keys are present
      def serializable_keys?
        @serializable_keys_bool_cache ||= serializable_keys.present?
      end

      # @return [Boolean] true if the keys we are saving have resource_timestamp column
      def supports_remote_data_timestamp?(all_attribute_keys)
        all_attribute_keys.include?(:resource_timestamp) # include? on Set is O(1)
      end

      # @return [Boolean] true if the keys we are saving have resource_counter column
      def supports_remote_data_version?(all_attribute_keys)
        all_attribute_keys.include?(:resource_counter) # include? on Set is O(1)
      end

      # @return [Boolean] true if the keys we are saving have resource_version column, which solves for a quick check
      #                   if the record was modified
      def supports_resource_version?(all_attribute_keys)
        all_attribute_keys.include?(resource_version_column) # include? on Set is O(1)
      end
    end
  end
end
