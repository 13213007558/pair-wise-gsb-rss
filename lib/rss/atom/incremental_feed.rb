# frozen_string_literal: false

module RSS
  module Atom
    # Merges Atom entries and RFC 6721 deleted-entry events without I/O.
    module IncrementalFeed
      class << self
        # Merges the events in +feed+ into +state+.
        #
        # +state+ may be an Enumerable of entries, a Hash containing +:entries+
        # and +:deleted_entries+, or a previous Result.
        def merge(state, feed, *positional_policy,
                  same_timestamp: :keep_existing, &policy)
          same_timestamp = positional_policy.first unless positional_policy.empty?
          normalized_state = normalize_state(state)
          entries = normalized_state[:entries].dup
          deleted_entries = normalized_state[:deleted_entries].dup
          conflicts = []

          incoming_events(feed).each do |incoming|
            id = event_id(incoming)
            existing = entries[id] || deleted_entries[id]
            next if identical_event?(existing, incoming)

            if existing.nil?
              apply_event(entries, deleted_entries, incoming)
              next
            end

            decision = decide(existing, incoming, same_timestamp, policy)
            if decision == :incoming
              apply_event(entries, deleted_entries, incoming)
            elsif decision == :conflict
              conflicts << conflict(id, existing, incoming)
            end
          end

          Result.new(entries, deleted_entries, conflicts)
        end

        private
        def normalize_state(state)
          case state
          when Result
            {
              :entries => state.entries.dup,
              :deleted_entries => state.deleted_entries.dup,
            }
          when Hash
            normalize_hash_state(state)
          when nil
            {:entries => {}, :deleted_entries => {}}
          when Feed
            {
              :entries => events_by_id(state.entries, false),
              :deleted_entries => events_by_id(state.deleted_entries, true),
            }
          else
            normalize_entries(state)
          end
        end

        def normalize_hash_state(state)
          return index_events(state) unless
            state.key?(:entries) || state.key?("entries") ||
              state.key?(:deleted_entries) ||
              state.key?("deleted_entries")

          entries = state_values(state, :entries, "entries")
          deleted = state_values(state, :deleted_entries, "deleted_entries")
          index_events(entries).merge(index_events(deleted))
        end

        def state_values(state, symbol_key, string_key)
          value = if state.key?(symbol_key)
                   state[symbol_key]
                 else
                   state[string_key]
                 end
          normalize_collection(value || [])
        end

        def normalize_collection(events)
          return events.values if events.is_a?(Hash)
          events
        end

        def normalize_entries(entries)
          unless entries.respond_to?(:each)
            raise ArgumentError, "state must be an Enumerable, Hash, or Result"
          end
          index_events(entries)
        end

        def index_events(events)
          result = {:entries => {}, :deleted_entries => {}}
          events = events.each_value if events.is_a?(Hash)
          events.each do |event|
            id = event_id(event)
            if deleted_event?(event)
              result[:deleted_entries][id] = event
            else
              result[:entries][id] = event
            end
          end
          result
        end

        def events_by_id(events, deleted)
          events.each_with_object({}) do |event, indexed|
            indexed[event_id(event)] = event unless deleted_event?(event) != deleted
          end
        end

        def incoming_events(feed)
          unless feed.respond_to?(:entries) &&
              feed.respond_to?(:deleted_entries)
            raise ArgumentError, "feed must be an Atom feed"
          end
          feed.class.models.select do |tag, uri, _occurs, _getter, plural|
            [URI, TOMBSTONE_URI].include?(uri) &&
              ["entry", "deleted-entry"].include?(tag) && plural
          end.flat_map do |_tag, _uri, _occurs, getter, _plural|
            feed.public_send(getter).to_a
          end
        end

        def decide(existing, incoming, same_timestamp, policy)
          existing_time = event_time(existing)
          incoming_time = event_time(incoming)

          if existing_time.nil? || incoming_time.nil?
            :conflict
          elsif incoming_time > existing_time
            :incoming
          elsif incoming_time < existing_time
            :existing
          else
            resolve_same_timestamp(existing, incoming, same_timestamp, policy)
          end
        end

        def resolve_same_timestamp(existing, incoming, same_timestamp, policy)
          choice = if policy
                     policy.call(existing, incoming)
                   else
                     same_timestamp
                   end
          case choice
          when :existing, :keep_existing
            :existing
          when :incoming, :use_incoming, :replace
            :incoming
          when :conflict, :return_conflict
            :conflict
          else
            raise ArgumentError, "unsupported same timestamp policy: #{choice.inspect}"
          end
        end

        def conflict(id, existing, incoming)
          reason = if event_time(existing) && event_time(incoming)
                     :same_timestamp
                   else
                     :insufficient_timestamp_evidence
                   end
          Conflict.new(id, reason, existing, incoming)
        end

        def apply_event(entries, deleted_entries, event)
          id = event_id(event)
          if deleted_event?(event)
            entries.delete(id)
            deleted_entries[id] = event
          else
            deleted_entries.delete(id)
            entries[id] = event
          end
        end

        def identical_event?(existing, incoming)
          return false if existing.nil?
          event_type(existing) == event_type(incoming) &&
            event_id(existing) == event_id(incoming) &&
            event_time(existing) == event_time(incoming) &&
            existing.to_s == incoming.to_s
        end

        def deleted_event?(event)
          event.is_a?(Feed::DeletedEntry)
        end

        def event_type(event)
          deleted_event?(event) ? :deleted_entry : :entry
        end

        def event_id(event)
          id = deleted_event?(event) ? event.ref : event.id&.content
          if id.nil? || id.to_s.strip.empty?
            raise ArgumentError, "Atom events must have an id"
          end
          id
        end

        def event_time(event)
          if deleted_event?(event)
            event.when
          else
            event.updated&.content
          end
        end
      end

      Result = Struct.new(:entries, :deleted_entries, :conflicts) do
        def initialize(entries={}, deleted_entries={}, conflicts=[])
          super
        end

        def each_event(&block)
          entries.each_value(&block)
          deleted_entries.each_value(&block)
        end
      end

      Conflict = Struct.new(:id, :reason, :existing, :incoming) do
        def same_timestamp?
          reason == :same_timestamp
        end

        def insufficient_timestamp_evidence?
          reason == :insufficient_timestamp_evidence
        end
      end
    end
  end
end
