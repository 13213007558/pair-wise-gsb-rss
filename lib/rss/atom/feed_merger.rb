# frozen_string_literal: false

module RSS
  module Atom
    class FeedMerger
      SAME_TIME_POLICIES = [:keep_existing, :take_incoming, :conflict].freeze

      Conflict = Struct.new(:id, :existing, :incoming, :reason,
                            keyword_init: true)

      attr_reader :same_time_policy

      def initialize(same_time_policy: :conflict)
        unless SAME_TIME_POLICIES.include?(same_time_policy)
          raise ArgumentError,
                "unknown same-time policy: #{same_time_policy.inspect}"
        end
        @same_time_policy = same_time_policy
      end

      def merge(state, feed)
        merged = self.class.empty_state
        copy_state(state, merged)
        merge!(merged, feed)
      end

      def merge!(state, feed)
        prepare_state(state)
        result = Result.new(state, [])
        ordered_events(feed).each {|event| merge_event(result, event)}
        result
      end

      def self.empty_state
        {"entries" => {}, "deleted_entries" => {}}
      end

      def self.merge(state, feed, **options)
        new(**options).merge(state, feed)
      end

      def self.merge!(state, feed, **options)
        new(**options).merge!(state, feed)
      end

      private
      def prepare_state(state)
        state["entries"] ||= {}
        state["deleted_entries"] ||= {}
      end

      def copy_state(source, target)
        (source || {}).each do |key, value|
          target[key] = value.is_a?(Hash) ? value.dup : value
        end
        prepare_state(target)
      end

      def ordered_events(feed)
        feed.entries.to_a + feed.deleted_entries.to_a
      end

      def merge_event(result, event)
        tombstone?(event) ? merge_deleted_entry(result, event) :
          merge_entry(result, event)
      end

      def merge_entry(result, entry)
        id = entry.id.content
        tombstone = result.state["deleted_entries"][id]
        current = result.state["entries"][id]
        if tombstone
          apply_pair(result, id, tombstone, entry,
                     "equal deletion and entry timestamps")
        elsif current.nil?
          result.state["entries"][id] = entry
        else
          apply_pair(result, id, current, entry,
                     "equal entry timestamps")
        end
      end

      def merge_deleted_entry(result, tombstone)
        id = tombstone.ref
        current = result.state["entries"][id]
        previous = result.state["deleted_entries"][id]
        if current
          apply_pair(result, id, current, tombstone,
                     "equal entry and deletion timestamps")
        elsif previous.nil?
          result.state["deleted_entries"][id] = tombstone
        else
          apply_pair(result, id, previous, tombstone,
                     "equal deletion timestamps")
        end
      end

      def apply_pair(result, id, existing, incoming, equal_reason)
        comparison = compare_events(incoming, existing)
        case comparison
        when :after
          replace_state(result, id, existing, incoming)
        when :unknown
          add_conflict(result, id, existing, incoming,
                       "insufficient timestamp evidence")
        when :equal
          if same_event?(existing, incoming)
            replace_state(result, id, existing, incoming)
          else
            add_conflict(result, id, existing, incoming, equal_reason)
          end
        end
      end

      def replace_state(result, id, existing, incoming)
        state_for(result, existing).delete(id)
        state_for(result, incoming)[id] = incoming
      end

      def state_for(result, event)
        tombstone?(event) ? result.state["deleted_entries"] :
          result.state["entries"]
      end

      def add_conflict(result, id, existing, incoming, reason)
        conflict = Conflict.new(id: id, existing: existing,
                                incoming: incoming, reason: reason)
        unless result.conflicts.any? {|other| same_conflict?(other, conflict)}
          result.conflicts << conflict
        end
        return unless same_time_policy == :take_incoming
        result.state["entries"].delete(id)
        result.state["deleted_entries"].delete(id)
        state_for(result, incoming)[id] = incoming
      end

      def compare_events(incoming, existing)
        incoming_time = event_time(incoming)
        existing_time = event_time(existing)
        return :unknown if incoming_time.nil? or existing_time.nil?
        return :after if incoming_time > existing_time
        return :before if incoming_time < existing_time
        :equal
      end

      def event_time(event)
        tombstone?(event) ? event.when : event.updated&.content
      end

      def tombstone?(event)
        event.is_a?(Feed::TombstoneEntry)
      end

      def same_conflict?(first, second)
        first.id == second.id and
          first.reason == second.reason and
          same_event?(first.existing, second.existing) and
          same_event?(first.incoming, second.incoming)
      end

      def same_event?(first, second)
        return false unless tombstone?(first) == tombstone?(second)
        tombstone?(first) ? same_tombstone?(first, second) :
          same_entry?(first, second)
      end

      def same_tombstone?(first, second)
        first.ref == second.ref and
          first.when == second.when
      end

      def same_entry?(first, second)
        first.id.content == second.id.content and
          first.updated&.content == second.updated&.content
      end

      class Result
        attr_reader :state, :conflicts

        def initialize(state, conflicts)
          @state = state
          @conflicts = conflicts
        end

        def entries
          state.fetch("entries")
        end

        def deleted_entries
          state.fetch("deleted_entries")
        end
      end
    end
  end
end
