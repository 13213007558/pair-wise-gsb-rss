# frozen_string_literal: false
require_relative "rss-testcase"

require "rss/atom"
require "rss/maker"

module RSS
  class TestAtomTombstone < TestCase
    TOMBSTONE_URI = Atom::TOMBSTONE_URI
    ATOM_URI = Atom::URI

    def test_feed_deleted_entry_model
      feed = Parser.parse(make_feed(<<-EOX))
<at:deleted-entry ref="urn:uuid:deleted"
                 when="2026-01-02T03:04:05Z"
                 xml:lang="en"
                 ex:reason="spam"
                 xmlns:ex="http://example.com/ext">
  <at:by>
    <name>Editor</name>
    <uri>mailto:editor@example.test</uri>
    <email>editor@example.test</email>
  </at:by>
  <at:comment>Removed by policy.</at:comment>
  <ex:detail>kept</ex:detail>
</at:deleted-entry>
EOX

      assert_equal(1, feed.deleted_entries.size)
      tombstone = feed.deleted_entries.first
      assert_equal("urn:uuid:deleted", tombstone.ref)
      assert_equal(Time.iso8601("2026-01-02T03:04:05Z"),
                   tombstone.when)
      assert_equal("Editor", tombstone.by.name.content)
      assert_equal("mailto:editor@example.test",
                   tombstone.by.uri.content)
      assert_equal("editor@example.test",
                   tombstone.by.email.content)
      assert_equal("Removed by policy.", tombstone.comment.content)
      assert_equal("spam", tombstone.extension_attributes["ex:reason"])
      extension = tombstone.extensions.first
      assert_equal("detail", extension.name)
      assert_equal("http://example.com/ext", extension.uri)
      assert_equal("kept", extension.children.first)

      output = feed.to_s
      assert_include(output,
                     %Q{xmlns:at="#{TOMBSTONE_URI}"})
      assert_include(output, "<at:deleted-entry")
      assert_include(output,
                     "Editor</name>")
      assert_include(output, "<at:comment lang=\"en\">Removed by policy.")
      assert_include(output,
                     %Q{ex:reason=\"spam\"})
      assert_include(output, "<ex:detail")
    end

    def test_standalone_deleted_entry_round_trip
      xml = <<-EOX
<deleted-entry xmlns="#{TOMBSTONE_URI}"
              xmlns:atom="#{ATOM_URI}"
              ref="urn:uuid:standalone"
              when="2026-01-02T03:04:05Z">
  <by><atom:name>Editor</atom:name></by>
  <comment>Gone</comment>
</deleted-entry>
EOX
      tombstone = Parser.parse(xml)
      assert_kind_of(Atom::DeletedEntry, tombstone)
      assert_equal("urn:uuid:standalone", tombstone.ref)
      assert_equal("Editor", tombstone.by.name.content)
      assert_equal("Gone", tombstone.comment.content)
      assert_include(tombstone.to_s, "<deleted-entry")
    end

    def test_maker_generates_tombstone
      feed = Maker.make("atom") do |maker|
        setup_minimal_atom_feed(maker)
        maker.channel.deleted_entries.new_deleted_entry do |tombstone|
          tombstone.ref = "urn:uuid:deleted"
          tombstone.when = "2026-01-02T03:04:05Z"
          tombstone.comment = "Gone"
          tombstone.by do |by|
            by.name = "Editor"
          end
        end
      end

      parsed = Parser.parse(feed.to_s)
      assert_equal(1, parsed.deleted_entries.size)
      assert_equal("urn:uuid:deleted",
                   parsed.deleted_entries.first.ref)
      assert_equal("Gone",
                   parsed.deleted_entries.first.comment.content)
      assert_equal("Editor",
                   parsed.deleted_entries.first.by.name.content)
    end

    def test_merge_update_delete_and_no_resurrection
      existing = Parser.parse(make_feed(<<-EOX))
<entry>
  <id>urn:uuid:one</id>
  <title>Original</title>
  <updated>2026-01-01T00:00:00Z</updated>
</entry>
EOX
      deletion = Parser.parse(make_feed(<<-EOX))
<at:deleted-entry ref="urn:uuid:one"
                 when="2026-01-02T00:00:00Z"/>
EOX

      merger = Atom::FeedMerger.new
      state = Atom::FeedMerger.empty_state
      result = merger.merge(state, existing)
      assert_equal(["urn:uuid:one"], result.entries.keys)
      result = merger.merge(result.state, deletion)
      assert_empty(result.entries)
      assert_equal(["urn:uuid:one"], result.deleted_entries.keys)

      stale_copy = Parser.parse(make_feed(<<-EOX))
<entry>
  <id>urn:uuid:one</id>
  <title>Original</title>
  <updated>2026-01-01T12:00:00Z</updated>
</entry>
EOX
      result = merger.merge(result.state, stale_copy)
      assert_empty(result.entries)
      assert_equal(["urn:uuid:one"], result.deleted_entries.keys)

      restored = Parser.parse(make_feed(<<-EOX))
<entry>
  <id>urn:uuid:one</id>
  <title>Restored</title>
  <updated>2026-01-03T00:00:00Z</updated>
</entry>
EOX
      result = merger.merge(result.state, restored)
      assert_equal("Restored",
                   result.entries["urn:uuid:one"].title.content)
      assert_empty(result.deleted_entries)
    end

    def test_same_timestamp_conflicts
      entry = Parser.parse(make_feed(<<-EOX))
<entry>
  <id>urn:uuid:one</id>
  <title>One</title>
  <updated>2026-01-02T00:00:00Z</updated>
</entry>
EOX
      deletion = Parser.parse(make_feed(<<-EOX))
<at:deleted-entry ref="urn:uuid:one"
                 when="2026-01-02T00:00:00Z"/>
EOX

      state = Atom::FeedMerger.merge(Atom::FeedMerger.empty_state, entry).state
      result = Atom::FeedMerger.merge(state, deletion,
                                     same_time_policy: :conflict)
      assert_equal(1, result.conflicts.size)
      assert_equal("urn:uuid:one", result.conflicts.first.id)
      assert_equal("One",
                   result.entries["urn:uuid:one"].title.content)

      result = Atom::FeedMerger.merge(state, deletion,
                                     same_time_policy: :take_incoming)
      assert_empty(result.entries)
      assert(result.deleted_entries.key?("urn:uuid:one"))

      result = Atom::FeedMerger.merge(state, deletion,
                                     same_time_policy: :keep_existing)
      assert_equal("One",
                   result.entries["urn:uuid:one"].title.content)
      assert_empty(result.deleted_entries)
    end

    def test_repeated_and_out_of_order_merge
      first = Parser.parse(make_feed(<<-EOX))
<entry>
  <id>urn:uuid:one</id>
  <title>First</title>
  <updated>2026-01-01T00:00:00Z</updated>
</entry>
<at:deleted-entry ref="urn:uuid:two"
                 when="2026-01-03T00:00:00Z"/>
EOX
      second = Parser.parse(make_feed(<<-EOX))
<entry>
  <id>urn:uuid:one</id>
  <title>Second</title>
  <updated>2026-01-04T00:00:00Z</updated>
</entry>
EOX

      merger = Atom::FeedMerger.new
      merged_once = merger.merge(Atom::FeedMerger.empty_state, first)
      merged_twice = merger.merge(merged_once.state, first)
      assert_equal(merged_once.state.keys, merged_twice.state.keys)
      assert_empty(merged_twice.conflicts)

      result = merger.merge(merged_twice.state, second)
      result = merger.merge(result.state, first)
      assert_equal("Second",
                   result.entries["urn:uuid:one"].title.content)
      assert_equal(["urn:uuid:two"], result.deleted_entries.keys)
      assert_empty(result.conflicts)
    end

    def test_merge_without_timestamp_returns_conflict
      entry = Parser.parse(make_feed(<<-EOX))
<entry>
  <id>urn:uuid:one</id>
  <title>One</title>
  <updated>2026-01-01T00:00:00Z</updated>
</entry>
EOX
      tombstone = Parser.parse(make_feed(<<-EOX), false)
<at:deleted-entry ref="urn:uuid:one" when=""/>
EOX
      state = Atom::FeedMerger.merge(Atom::FeedMerger.empty_state, entry).state
      result = Atom::FeedMerger.new.merge(state, tombstone)
      assert_equal(1, result.conflicts.size)
      assert_equal("insufficient timestamp evidence",
                   result.conflicts.first.reason)
    end

    private
    def make_feed(content)
      <<-EOX
<feed xmlns="#{ATOM_URI}"
      xmlns:at="#{TOMBSTONE_URI}"
      xmlns:ex="http://example.com/ext">
  <id>urn:uuid:feed</id>
  <title>Incremental feed</title>
  <updated>2026-01-01T00:00:00Z</updated>
  <author><name>Publisher</name></author>
  #{content}
</feed>
EOX
    end

    def setup_minimal_atom_feed(maker)
      maker.channel.id = "urn:uuid:feed"
      maker.channel.title = "Incremental feed"
      maker.channel.updated = "2026-01-01T00:00:00Z"
      maker.channel.author = "Publisher"
    end
  end
end
