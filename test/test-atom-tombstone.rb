# frozen_string_literal: false
require "rexml/document"

require_relative "rss-testcase"

require "rss/atom"
require "rss/maker"

module RSS
  class TestAtomTombstone < TestCase
    def test_parse_deleted_entry_model_and_extensions
      feed = Parser.parse(deleted_feed_xml)
      deleted_entry = feed.deleted_entries.first

      assert_equal("urn:entry:1", deleted_entry.ref)
      assert_equal(Time.utc(2020, 1, 2, 3, 4, 5), deleted_entry.when)
      assert_equal("Bob", deleted_entry.by.name.content)
      assert_equal("Removed by editor", deleted_entry.comment.content)
      assert_equal("spam", deleted_entry.extension_attributes["ex:reason-code"])

      extension = deleted_entry.extensions.first
      assert_equal("http://example.com/tombstone-extensions", extension.uri)
      assert_equal("reason", extension.name)
      assert_equal("duplicate", extension["code"])
      assert_match(%r{<ex:reason code="duplicate"}, extension.to_s)
      assert_match(%r{<ex:actor>Editor</ex:actor>duplicate item}, extension.to_s)
    end

    def test_generate_and_round_trip_deleted_entry
      feed = Parser.parse(deleted_feed_xml)
      generated = feed.to_s

      assert_match(%r{xmlns:at="http://purl.org/atompub/tombstones/1.0"},
                   generated)
      assert_match(%r{<at:deleted-entry ref="urn:entry:1"}, generated)
      assert_match(%r{<at:by>}, generated)
      assert_match(%r{<at:comment>Removed by editor</at:comment>}, generated)
      assert_match(%r{<ex:reason code="duplicate"}, generated)

      rebuilt = Maker.make("atom") do |maker|
        feed.setup_maker(maker)
      end
      rebuilt_entry = rebuilt.deleted_entries.first

      assert_equal("urn:entry:1", rebuilt_entry.ref)
      assert_equal("Bob", rebuilt_entry.by.name.content)
      assert_equal("Removed by editor", rebuilt_entry.comment.content)
      assert_equal("duplicate", rebuilt_entry.extensions.first["code"])
      assert_equal("spam", rebuilt_entry.extension_attributes["ex:reason-code"])
    end

    def test_maker_creates_deleted_entry
      feed = Maker.make("atom") do |maker|
        maker.channel.id = "urn:feed"
        maker.channel.title = "Feed"
        maker.channel.updated = Time.utc(2020, 1, 1)
        maker.channel.author = "Alice"
        maker.channel.deleted_entries.new_deleted_entry do |deleted_entry|
          deleted_entry.ref = "urn:entry:2"
          deleted_entry.when = Time.utc(2020, 1, 2)
          deleted_entry.by.name = "Carol"
          deleted_entry.comment = "Gone"
        end
      end

      assert_equal(1, feed.deleted_entries.size)
      deleted_entry = feed.deleted_entries.first
      assert_equal("urn:entry:2", deleted_entry.ref)
      assert_equal("Carol", deleted_entry.by.name.content)
      assert_equal("Gone", deleted_entry.comment.content)
    end

    def test_unqualified_tombstone_children_are_unknown
      xml = <<~XML
        <feed xmlns="#{Atom::URI}" xmlns:at="#{Atom::TOMBSTONE_URI}">
          <id>urn:feed</id>
          <title>Feed</title>
          <updated>2020-01-01T00:00:00Z</updated>
          <author><name>Alice</name></author>
          <at:deleted-entry ref="urn:entry:1"
                            when="2020-01-02T03:04:05Z">
            <by><name>Bob</name></by>
          </at:deleted-entry>
        </feed>
      XML

      assert_nothing_raised do
        Parser.parse(xml, false)
      end
      assert_raise(NotExpectedTagError) do
        Parser.parse(xml, true, false)
      end
    end

    def test_merge_updates_deletes_and_rejects_stale_resurrection
      initial = Atom::IncrementalFeed.merge(nil, parse_feed(entry_feed_xml(
        "urn:entry:1", "Original", "2020-01-01T00:00:00Z"
      )))
      deleted = Atom::IncrementalFeed.merge(
        initial,
        parse_feed(deleted_event_xml("urn:entry:1", "2020-01-02T00:00:00Z"))
      )
      stale = Atom::IncrementalFeed.merge(
        deleted,
        parse_feed(entry_feed_xml(
          "urn:entry:1", "Stale cached copy", "2020-01-01T12:00:00Z"
        ))
      )
      updated = Atom::IncrementalFeed.merge(
        stale,
        parse_feed(entry_feed_xml(
          "urn:entry:1", "Real later update", "2020-01-03T00:00:00Z"
        ))
      )

      assert_equal([], initial.deleted_entries.keys)
      assert_equal(["urn:entry:1"], deleted.deleted_entries.keys)
      assert_equal(["urn:entry:1"], stale.deleted_entries.keys)
      assert_equal([], stale.entries.keys)
      assert_equal([], updated.deleted_entries.keys)
      assert_equal("Real later update",
                   updated.entries["urn:entry:1"].title.content)
    end

    def test_repeated_merge_is_idempotent
      initial = parse_feed(entry_feed_xml(
        "urn:entry:1", "Original", "2020-01-01T00:00:00Z"
      ))
      deletion_feed = parse_feed(deleted_event_xml(
        "urn:entry:1", "2020-01-02T00:00:00Z"
      ))

      once = Atom::IncrementalFeed.merge(initial, deletion_feed)
      twice = Atom::IncrementalFeed.merge(once, deletion_feed)

      assert_equal(once.entries.keys, twice.entries.keys)
      assert_equal(once.deleted_entries.keys, twice.deleted_entries.keys)
      assert_equal([], twice.conflicts)
    end

    def test_out_of_order_feeds_converge_without_resurrection
      feeds = [
        deleted_event_xml("urn:entry:1", "2020-01-02T00:00:00Z"),
        entry_feed_xml("urn:entry:1", "Later", "2020-01-03T00:00:00Z"),
        entry_feed_xml("urn:entry:1", "Earlier", "2020-01-01T00:00:00Z"),
      ].shuffle(random: Random.new(7))

      result = feeds.inject(nil) do |state, xml|
        Atom::IncrementalFeed.merge(state, parse_feed(xml))
      end

      assert_equal(["urn:entry:1"], result.entries.keys)
      assert_equal("Later", result.entries["urn:entry:1"].title.content)
    end

    def test_same_timestamp_policy
      existing = parse_feed(entry_feed_xml(
        "urn:entry:1", "Existing", "2020-01-01T00:00:00Z"
      ))
      incoming_feed = parse_feed(entry_feed_xml(
        "urn:entry:1", "Incoming", "2020-01-01T00:00:00Z"
      ))

      kept = Atom::IncrementalFeed.merge(existing, incoming_feed)
      replaced = Atom::IncrementalFeed.merge(
        existing, incoming_feed, same_timestamp: :incoming
      )
      conflicted = Atom::IncrementalFeed.merge(
        existing, incoming_feed, same_timestamp: :conflict
      )

      assert_equal("Existing", kept.entries["urn:entry:1"].title.content)
      assert_equal("Incoming",
                   replaced.entries["urn:entry:1"].title.content)
      assert_equal("Existing",
                   conflicted.entries["urn:entry:1"].title.content)
      assert_equal(:same_timestamp, conflicted.conflicts.first.reason)
    end

    def test_merge_does_not_mutate_input_state
      initial = Atom::IncrementalFeed.merge(nil, parse_feed(entry_feed_xml(
        "urn:entry:1", "Original", "2020-01-01T00:00:00Z"
      )))
      deletion_feed = parse_feed(deleted_event_xml(
        "urn:entry:1", "2020-01-02T00:00:00Z"
      ))
      original_entries = initial.entries.dup
      original_deleted = initial.deleted_entries.dup

      Atom::IncrementalFeed.merge(initial, deletion_feed)

      assert_equal(original_entries, initial.entries)
      assert_equal(original_deleted, initial.deleted_entries)
    end

    def test_module_entry_point
      existing = parse_feed(entry_feed_xml(
        "urn:entry:1", "Existing", "2020-01-01T00:00:00Z"
      ))
      incoming_feed = parse_feed(entry_feed_xml(
        "urn:entry:1", "Incoming", "2020-01-02T00:00:00Z"
      ))

      result = Atom.merge_incremental_feed(existing, incoming_feed)

      assert_equal("Incoming", result.entries["urn:entry:1"].title.content)
    end

    def test_state_may_be_id_indexed_hash_and_positional_policy
      existing_feed = parse_feed(entry_feed_xml(
        "urn:entry:1", "Existing", "2020-01-01T00:00:00Z"
      ))
      incoming_feed = parse_feed(entry_feed_xml(
        "urn:entry:1", "Incoming", "2020-01-01T00:00:00Z"
      ))

      result = Atom::IncrementalFeed.merge(
        {"urn:entry:1" => existing_feed.entry},
        incoming_feed,
        :incoming
      )

      assert_equal("Incoming", result.entries["urn:entry:1"].title.content)
    end

    def test_insufficient_timestamp_evidence_returns_conflict
      existing = parse_feed(entry_feed_xml(
        "urn:entry:1", "Existing", "2020-01-01T00:00:00Z"
      ))
      incoming_feed = parse_feed(entry_feed_xml(
        "urn:entry:1", "No timestamp"
      ))

      result = Atom::IncrementalFeed.merge(existing, incoming_feed)
      conflict = result.conflicts.first

      assert_equal("Existing", result.entries["urn:entry:1"].title.content)
      assert_equal("urn:entry:1", conflict.id)
      assert_equal(:insufficient_timestamp_evidence, conflict.reason)
      assert_equal("No timestamp", conflict.incoming.title.content)
    end

    private
    def parse_feed(xml)
      Parser.parse(xml, false)
    end

    def deleted_feed_xml
      <<~XML
        <feed xmlns="#{Atom::URI}"
              xmlns:at="#{Atom::TOMBSTONE_URI}"
              xmlns:ex="http://example.com/tombstone-extensions">
          <id>urn:feed</id>
          <title>Feed</title>
          <updated>2020-01-01T00:00:00Z</updated>
          <author><name>Alice</name></author>
          <at:deleted-entry ref="urn:entry:1"
                            when="2020-01-02T03:04:05Z"
                            ex:reason-code="spam">
            <at:by><name>Bob</name></at:by>
            <at:comment>Removed by editor</at:comment>
            <ex:reason code="duplicate">
              <ex:actor>Editor</ex:actor>duplicate item
            </ex:reason>
          </at:deleted-entry>
        </feed>
      XML
    end

    def entry_feed_xml(id, title, updated=nil)
      updated_xml = updated ? %(<updated>#{updated}</updated>) : ""
      <<~XML
        <feed xmlns="#{Atom::URI}">
          <id>urn:feed</id>
          <title>Feed</title>
          <updated>2020-01-01T00:00:00Z</updated>
          <author><name>Alice</name></author>
          <entry>
            <id>#{id}</id>
            <title>#{title}</title>
            #{updated_xml}
          </entry>
        </feed>
      XML
    end

    def deleted_event_xml(id, deleted_at)
      <<~XML
        <feed xmlns="#{Atom::URI}" xmlns:at="#{Atom::TOMBSTONE_URI}">
          <id>urn:feed</id>
          <title>Feed</title>
          <updated>2020-01-01T00:00:00Z</updated>
          <author><name>Alice</name></author>
          <at:deleted-entry ref="#{id}" when="#{deleted_at}"/>
        </feed>
      XML
    end
  end
end
