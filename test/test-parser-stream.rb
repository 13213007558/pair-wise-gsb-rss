# frozen_string_literal: false
require "stringio"
require "tempfile"

require_relative "rss-testcase"

require "rss/2.0"
require "rss/atom"

module RSS
  class TestParserStream < TestCase
    class ShortReadIO
      attr_reader :read_count

      def initialize(content, max_read = 1)
        @io = StringIO.new(content)
        @max_read = max_read
        @read_count = 0
      end

      def read(length = nil)
        @read_count += 1
        @io.read(length && [length, @max_read].min)
      end

      def readline(*args)
        @read_count += 1
        @io.readline(*args)
      end

      def close
        @closed = true
      end

      def closed?
        @closed == true
      end

      def eof?
        @io.eof?
      end

      def pos
        @io.pos
      end
    end

    def test_each_entry_stops_rss_io_after_ten_entries
      io = ShortReadIO.new(rss_feed(20))
      entries = []

      result = Parser.each_entry(io) do |entry|
        entries << entry.title
        break if entries.size == 10
      end

      assert_equal((1..10).map { |index| "Item #{index}" }, entries)
      assert_nil(result)
      assert_operator(io.read_count, :>, 1)
      assert_equal(false, io.eof?)
      assert_equal(false, io.closed?)
    end

    def test_foreach_returns_entry_metadata_and_result_events
      io = ShortReadIO.new(rss_feed(2))
      events = []

      result = Parser.foreach(io) do |event|
        events << event.type
      end

      assert_equal([:entry, :entry, :metadata, :result], events)
      assert_predicate(result, :complete?)
      assert_kind_of(StreamResult, result)
      assert_equal("Stream Feed", result.metadata.channel.title)
      assert_empty(result.metadata.channel.items)
    end

    def test_atom_entry_inherits_later_feed_author
      io = ShortReadIO.new(atom_feed(1))
      entries = []
      result = nil
      metadata = nil

      Parser.foreach(io) do |event|
        entries << event.entry if event.entry?
        metadata = event.metadata if event.metadata?
        result = event.result if event.result?
      end

      assert_equal(1, entries.size)
      assert_predicate(entries.first, :have_author?)
      assert_equal("Feed Author", entries.first.parent.authors.first.name.content)
      assert_equal("Feed Author", metadata.authors.first.name.content)
      assert_empty(metadata.entries)
      assert_predicate(result, :complete?)
    end

    def test_atom_entry_author_satisfies_feed_author_requirement
      feed = <<~"ATOM"
        <feed xmlns="#{Atom::URI}">
          <title>Stream Feed</title>
          <id>urn:uuid:feed</id>
          <updated>2020-01-01T00:00:00Z</updated>
          <entry>
            <title>Entry 1</title>
            <id>urn:uuid:entry-1</id>
            <updated>2020-01-01T00:00:00Z</updated>
            <author><name>Entry Author</name></author>
          </entry>
        </feed>
      ATOM
      result = nil

      Parser.foreach(StringIO.new(feed)) do |event|
        result = event.result if event.result?
      end

      assert_predicate(result, :complete?)
    end

    def test_missing_feed_metadata_is_reported_after_entries
      feed = atom_feed(1).sub("  <title>Stream Feed</title>\n", "")
      events = []
      result = nil

      Parser.foreach(StringIO.new(feed)) do |event|
        events << event.type
        result = event.result if event.result?
      end

      assert_equal([:entry, :metadata, :result], events)
      assert_not_predicate(result, :complete?)
      assert_kind_of(MissingTagError, result.error)
      assert_equal("title", result.error.tag)
      assert_equal("feed", result.error.parent)
    end

    def test_duplicate_atom_entry_id_is_reported_only_in_result
      events = []
      result = Parser.foreach(StringIO.new(atom_feed(2, :same_id => true))) do |event|
        events << event
      end

      assert_equal(2, events.count(&:entry?))
      assert_not_predicate(result, :complete?)
      assert_kind_of(DuplicateEntryIDError, result.error)
      assert_equal("urn:uuid:entry-1", result.error.id)
    end

    def test_malformed_tail_yields_entries_and_incomplete_result
      events = []
      result = Parser.foreach(StringIO.new(rss_feed(2) + "</broken>")) do |event|
        events << event
      end

      assert_equal([:entry, :entry], events.select(&:entry?).map(&:type))
      assert_not_predicate(result, :complete?)
      assert_kind_of(NotWellFormedError, result.error)
      assert_equal("Stream Feed", result.metadata.channel.title)
    end

    def test_garbage_after_root_yields_entries_and_incomplete_result
      events = []
      result = Parser.foreach(StringIO.new(rss_feed(1) + "garbage")) do |event|
        events << event.type
      end

      assert_equal([:entry, :metadata, :result], events)
      assert_not_predicate(result, :complete?)
      assert_kind_of(NotWellFormedError, result.error)
    end

    def test_caller_owned_io_is_not_closed
      io = StringIO.new(rss_feed(1))
      Parser.foreach(io) {}
      assert_equal(false, io.closed?)
    end

    def test_parser_owned_file_io_is_closed
      file = Tempfile.new(["rss-stream", ".xml"])
      file.write(rss_feed(1))
      file.flush
      path = file.path
      file.close

      result = Parser.foreach(path) {}

      assert_predicate(result, :complete?)
      assert_nothing_raised { File.unlink(path) }
    end

    private

    def rss_feed(item_count)
      items = item_count.times.map do |index|
        number = index + 1
        <<~"ITEM"
          <item>
            <title>Item #{number}</title>
            <link>https://example.com/items/#{number}</link>
            <description>Description #{number}</description>
            <guid>item-#{number}</guid>
          </item>
        ITEM
      end.join


      <<~"RSS"
        <?xml version="1.0"?>
        <rss version="2.0">
          <channel>
            <title>Stream Feed</title>
            <link>https://example.com</link>
            <description>Stream description</description>
            #{items}
          </channel>
        </rss>
      RSS
    end

    def atom_feed(entry_count, same_id: false)
      entries = entry_count.times.map do |index|
        number = index + 1
        id = same_id ? "entry-1" : "entry-#{number}"
        <<~"ENTRY"
          <entry>
            <title>Entry #{number}</title>
            <id>urn:uuid:#{id}</id>
            <updated>2020-01-0#{number}T00:00:00Z</updated>
          </entry>
        ENTRY
      end.join

      <<~"ATOM"
        <?xml version="1.0"?>
        <feed xmlns="#{Atom::URI}">
          <title>Stream Feed</title>
          <id>urn:uuid:feed</id>
          <updated>2020-01-01T00:00:00Z</updated>
          <author><name>Feed Author</name></author>
          #{entries}
        </feed>
      ATOM
    end
  end
end
