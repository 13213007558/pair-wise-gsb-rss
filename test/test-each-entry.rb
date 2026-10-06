# frozen_string_literal: false
require "tempfile"

require_relative "rss-testcase"

require "rss/2.0"
require "rss/atom"

module RSS
  class TestParserEachEntry < TestCase
    # An IO like object that only serves short reads and counts how
    # many reads it served, to prove that parsing is incremental.
    class ShortReadIO
      attr_reader :read_count

      def initialize(data, chunk_size=8)
        @data = data
        @chunk_size = chunk_size
        @pos = 0
        @read_count = 0
        @closed = false
      end

      def read(length=nil, outbuf=nil)
        @read_count += 1
        return nil if eof?
        length = @chunk_size if length.nil? or length > @chunk_size
        chunk = @data.byteslice(@pos, length)
        @pos += chunk.bytesize
        chunk
      end

      def eof?
        @pos >= @data.bytesize
      end

      def close
        @closed = true
      end

      def closed?
        @closed
      end
    end

    def make_rss20_document(item_count)
      items = (1..item_count).collect do |i|
        "<item>\n" \
          "<title>Item #{i}</title>\n" \
          "<link>http://example.org/#{i}</link>\n" \
          "<guid>urn:test:item:#{i}</guid>\n" \
          "</item>"
      end.join("\n")
      make_rss20(<<-EOC)
<channel>
  <title>#{TITLE_VALUE}</title>
  <link>#{LINK_VALUE}</link>
  <description>#{DESCRIPTION_VALUE}</description>
#{items}
</channel>
EOC
    end

    def make_atom_document(entry_count, options={})
      feed_author = options.fetch(:feed_author, true)
      entry_author = options.fetch(:entry_author, false)
      author = ""
      if feed_author
        author = "<author><name>#{FEED_AUTHOR_NAME}</name></author>"
      end
      entries = (1..entry_count).collect do |i|
        entry = "<entry>\n" \
          "<title>Entry #{i}</title>\n" \
          "<id>urn:test:entry:#{i}</id>\n" \
          "<updated>#{FEED_UPDATED}</updated>\n"
        if entry_author
          entry << "<author><name>Author #{i}</name></author>\n"
        end
        entry << "</entry>"
        entry
      end.join("\n")
      <<-EOA
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="#{Atom::URI}">
  <id>#{FEED_ID}</id>
  <title>#{FEED_TITLE}</title>
  <updated>#{FEED_UPDATED}</updated>
  #{author}
#{entries}
</feed>
EOA
    end

    def collect_events(source, *args)
      events = []
      result = RSS::Parser.each_entry(source, *args) do |event|
        events << event
      end
      [events, result]
    end

    def entry_events(events)
      events.select {|event| event.entry? }
    end

    def test_rss20_events_and_result
      events, result = collect_events(ShortReadIO.new(make_rss20_document(3)))

      metadata = events.first
      assert_instance_of(RSS::Parser::MetadataEvent, metadata)
      assert_equal(TITLE_VALUE, metadata.feed.title)

      entries = entry_events(events)
      assert_equal([1, 2, 3], entries.collect {|event| event.index })
      assert_equal(["Item 1", "Item 2", "Item 3"],
                   entries.collect {|event| event.entry.title })
      assert_instance_of(RSS::Rss::Channel::Item, entries.first.entry)
      assert_same(metadata.feed, entries.first.entry.parent)

      assert_equal(true, result.complete?)
      assert_equal(true, result.valid?)
      assert_equal([], result.errors)
      assert_equal(3, result.entry_count)
      assert_instance_of(RSS::Rss, result.feed)
      assert_equal([], result.feed.channel.items)
    end

    def test_atom_events_and_result
      events, result = collect_events(ShortReadIO.new(make_atom_document(3)))

      metadata = events.first
      assert_instance_of(RSS::Parser::MetadataEvent, metadata)
      assert_instance_of(RSS::Atom::Feed, metadata.feed)
      assert_equal(FEED_TITLE, metadata.feed.title.content)

      entries = entry_events(events)
      assert_equal(3, entries.size)
      entry = entries.first.entry
      assert_instance_of(RSS::Atom::Feed::Entry, entry)
      assert_same(metadata.feed, entry.parent)
      assert_equal([], entry.authors)
      assert_equal(true, entry.have_author?)

      assert_equal(true, result.complete?)
      assert_equal(true, result.valid?)
      assert_equal([], result.feed.entries)
    end

    def test_metadata_event_for_feed_without_entries
      xml = make_rss20(<<-EOC)
<channel>
  <title>#{TITLE_VALUE}</title>
  <link>#{LINK_VALUE}</link>
  <description>#{DESCRIPTION_VALUE}</description>
</channel>
EOC
      events, result = collect_events(ShortReadIO.new(xml))
      assert_equal(1, events.size)
      assert_equal(true, events.first.metadata?)
      assert_equal(TITLE_VALUE, events.first.feed.title)
      assert_equal(true, result.valid?)
    end

    def test_consumer_break_stops_reading
      xml = make_rss20_document(30)
      full_io = ShortReadIO.new(xml)
      RSS::Parser.each_entry(full_io) {|event| }

      io = ShortReadIO.new(xml)
      entries = []
      RSS::Parser.each_entry(io) do |event|
        next unless event.entry?
        entries << event.entry
        break if entries.size == 10
      end

      assert_equal(10, entries.size)
      assert_equal(false, io.eof?)
      assert_operator(io.read_count, :<, full_io.read_count)
    end

    def test_broken_tail_reports_incomplete_result
      xml = make_rss20_document(3)
      broken = xml[0...-10]
      events, result = collect_events(ShortReadIO.new(broken))

      assert_equal(3, entry_events(events).size)
      assert_equal(false, result.complete?)
      assert_equal(false, result.valid?)
      not_well_formed = result.errors.find do |error|
        error.is_a?(RSS::NotWellFormedError)
      end
      assert_not_nil(not_well_formed)
    end

    def test_missing_required_element_is_reported_at_the_end
      xml = make_rss20(<<-EOC)
<channel>
  <link>#{LINK_VALUE}</link>
  <description>#{DESCRIPTION_VALUE}</description>
  <item>
    <title>Item 1</title>
    <link>http://example.org/1</link>
  </item>
</channel>
EOC
      events, result = collect_events(ShortReadIO.new(xml))

      assert_equal(1, entry_events(events).size)
      assert_equal(false, result.valid?)
      missing = result.errors.find do |error|
        error.is_a?(RSS::MissingTagError)
      end
      assert_not_nil(missing)
      assert_equal("title", missing.tag)
      assert_equal("channel", missing.parent)
    end

    def test_atom_duplicate_entry_id
      xml = <<-EOA
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="#{Atom::URI}">
  <id>#{FEED_ID}</id>
  <title>#{FEED_TITLE}</title>
  <updated>#{FEED_UPDATED}</updated>
  <author><name>#{FEED_AUTHOR_NAME}</name></author>
  <entry>
    <title>Entry 1</title>
    <id>urn:test:duplicate</id>
    <updated>#{FEED_UPDATED}</updated>
  </entry>
  <entry>
    <title>Entry 2</title>
    <id>urn:test:duplicate</id>
    <updated>#{FEED_UPDATED}</updated>
  </entry>
</feed>
EOA
      events, result = collect_events(ShortReadIO.new(xml))

      assert_equal(2, entry_events(events).size)
      assert_equal(true, result.complete?)
      assert_equal(false, result.valid?)
      duplicate = result.errors.find do |error|
        error.is_a?(RSS::Parser::DuplicateEntryIDError)
      end
      assert_not_nil(duplicate)
      assert_equal("urn:test:duplicate", duplicate.id)
      assert_equal(1, duplicate.first_index)
      assert_equal(2, duplicate.conflict_index)
    end

    def test_atom_feed_without_author_but_entries_have_authors
      xml = make_atom_document(2, :feed_author => false,
                               :entry_author => true)
      events, result = collect_events(ShortReadIO.new(xml))
      assert_equal(2, entry_events(events).size)
      assert_equal(true, result.complete?)
      assert_equal(true, result.valid?)
    end

    def test_caller_owned_io_is_not_closed
      io = ShortReadIO.new(make_rss20_document(1))
      RSS::Parser.each_entry(io) {|event| }
      assert_equal(false, io.closed?)
    end

    def test_xml_string_source
      events, result = collect_events(make_rss20_document(2))
      assert_equal(2, entry_events(events).size)
      assert_equal(true, result.valid?)
    end

    def test_file_path_source
      Tempfile.create(["each-entry", ".rss"]) do |file|
        file.print(make_rss20_document(2))
        file.close
        events, result = collect_events(file.path)
        assert_equal(2, entry_events(events).size)
        assert_equal(true, result.valid?)
      end
    end

    def test_without_validation
      xml = make_rss20(<<-EOC)
<channel>
  <link>#{LINK_VALUE}</link>
  <description>#{DESCRIPTION_VALUE}</description>
  <item>
    <title>Item 1</title>
    <link>http://example.org/1</link>
  </item>
</channel>
EOC
      events, result = collect_events(ShortReadIO.new(xml), :validate => false)
      assert_equal(1, entry_events(events).size)
      assert_equal(true, result.complete?)
      assert_equal(true, result.valid?)
      assert_equal([], result.errors)
    end

    def test_block_is_required
      assert_raise(ArgumentError) do
        RSS::Parser.each_entry(make_rss20_document(1))
      end
    end
  end
end
