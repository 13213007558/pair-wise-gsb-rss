# frozen_string_literal: false
require "stringio"

module RSS

  class Parser

    # An event yielded by Parser.each_entry as soon as the feed level
    # metadata (the channel of an RSS feed or the feed element of an
    # Atom feed) is available.
    #
    # The event fires at most once per document: right before the first
    # entry event, or at the end of the document when the feed has no
    # entries at all.
    #
    # Note that the metadata may not be fully determined yet when the
    # event fires. Feed level elements that appear after entries are
    # still added to the same object afterwards. The object is shared
    # with the entries (via their #parent) and with the final result
    # (via StreamResult#feed), so it is complete once each_entry
    # returns.
    class MetadataEvent
      # The object that carries the feed level metadata: the channel
      # for an RSS feed, the feed itself for an Atom feed.
      attr_reader :feed

      def initialize(feed)
        @feed = feed
      end

      def entry?
        false
      end

      def metadata?
        true
      end
    end

    # An event yielded by Parser.each_entry each time an entry (an
    # item of an RSS feed or an entry of an Atom feed) has been
    # completely parsed.
    #
    # The entry is detached from its feed before it is yielded, so the
    # parser does not keep yielded entries in memory. The entry still
    # references its feed through #parent, so feed level metadata that
    # entries inherit (for example the author of an Atom feed) stays
    # available. That metadata may only be fully determined later; see
    # MetadataEvent.
    class EntryEvent
      # The parsed entry: an RSS::Rss::Channel::Item for an RSS feed,
      # an RSS::Atom::Feed::Entry for an Atom feed.
      attr_reader :entry

      # The 1-based position of the entry in the document.
      attr_reader :index

      def initialize(entry, index)
        @entry = entry
        @index = index
      end

      def entry?
        true
      end

      def metadata?
        false
      end
    end

    # The final result of Parser.each_entry.
    #
    # Having received entry events does not imply that the whole
    # document is fine: required feed level elements may turn out to
    # be missing, entry IDs may conflict, or the document may even be
    # truncated after valid entries. Consult #complete?, #valid? and
    # #errors instead of assuming that yielded entries mean success.
    class StreamResult
      # The root element of the parsed document (an RSS::Rss or an
      # RSS::Atom::Feed), the same object Parser.parse would have
      # returned, except that yielded entries are not kept in it. It
      # is nil when no root element could be parsed at all.
      attr_reader :feed

      # The errors that were detected while parsing or during the
      # final validation, in the order they were detected.
      attr_reader :errors

      # The number of entries that were yielded to the consumer.
      attr_reader :entry_count

      def initialize
        @feed = nil
        @errors = []
        @entry_count = 0
        @complete = false
      end

      # Whether the whole document was consumed. It is false when
      # parsing stopped before the end of the document, for example
      # because the document is not well formed or an element failed
      # validation.
      def complete?
        @complete
      end

      # Whether the document was completely consumed and no error was
      # detected, including the final validation of required elements
      # and entry ID conflicts.
      def valid?
        complete? and @errors.empty?
      end

      private

      def record_event(event)
        @entry_count += 1 if event.entry?
      end

      def feed=(feed)
        @feed = feed
      end

      def mark_complete
        @complete = true
      end
    end

    # An error reported through StreamResult#errors when two entries
    # of a feed use the same ID (the guid of an RSS item or the id of
    # an Atom entry).
    class DuplicateEntryIDError < InvalidRSSError
      attr_reader :id, :first_index, :conflict_index

      def initialize(id, first_index, conflict_index)
        @id = id
        @first_index = first_index
        @conflict_index = conflict_index
        super("entry ID <#{id}> is used by both " <<
              "entry #{first_index} and entry #{conflict_index}")
      end
    end

    # An IO like wrapper that gives any object that responds to
    # +read+ the line oriented reading that the streaming parsers
    # expect. The wrapped object may serve arbitrarily short reads;
    # data is pulled from it in chunks, only when more input is
    # needed, so reading still stops as soon as the consumer stops.
    class BufferedIO
      CHUNK_SIZE = 4096

      def initialize(io)
        @io = io
        @buffer = +""
        @eof = false
        @pos = 0
        @lineno = 0
      end

      def read(length=nil, outbuf=nil)
        if length.nil?
          fill_buffer until @eof
          return consume(@buffer.bytesize)
        end
        fill_buffer while @buffer.bytesize < length and not @eof
        return nil if @buffer.empty?
        consume(length)
      end

      def readline(separator=nil)
        separator = $/ if separator.nil?
        fill_buffer until @buffer.include?(separator) or @eof
        return nil if @buffer.empty?
        index = @buffer.index(separator)
        if index
          consume(index + separator.bytesize)
        else
          consume(@buffer.bytesize)
        end
      end

      def eof?
        @buffer.empty? and @eof
      end

      def pos
        @pos
      end

      def lineno
        @lineno
      end

      def rewind
        raise IOError, "stream is not seekable"
      end

      def seek(offset)
        raise IOError, "stream is not seekable"
      end

      def binmode
        @io.binmode if @io.respond_to?(:binmode)
        nil
      end

      def set_encoding(*args)
        @io.set_encoding(*args) if @io.respond_to?(:set_encoding)
        nil
      end

      private

      def fill_buffer
        return if @eof
        chunk = @io.read(CHUNK_SIZE)
        if chunk.nil? or chunk.empty?
          @eof = true
        else
          @buffer << chunk
        end
      end

      def consume(length)
        result = @buffer.slice!(0, length)
        @pos += result.bytesize
        @lineno += result.count("\n")
        result
      end
    end

    # A listener mixin that turns the document tree builder into an
    # entry stream: completed entries are detached from their parent
    # and reported through the event handler instead of being kept in
    # the feed object.
    module StreamListenerMixin
      attr_accessor :event_handler
      attr_reader :duplicate_id_errors

      def initialize
        super
        @event_handler = nil
        @metadata_event_emitted = false
        @entry_count = 0
        @seen_entry_ids = {}
        @duplicate_id_errors = []
        @entries_had_author = false
      end

      # Whether an entry that carries its own author has been seen.
      # Atom feeds are allowed to omit their own author in that case,
      # but the check in Atom::Feed looks at its entries, which are
      # detached here, so the final validation has to be told about it.
      def entries_had_author?
        @entries_had_author
      end

      def emit_pending_metadata_event
        return if @metadata_event_emitted
        return if @rss.nil?
        emit_metadata_event
      end

      private

      def setup_next_element(tag_name, klass, attributes)
        parent = @last_element
        pr = super
        return pr unless stream_entry_class?(klass)
        Proc.new do |text, tags|
          pr.call(text, tags)
          emit_entry_event(parent, tag_name, klass)
        end
      end

      def initial_start_feed(tag_name, prefix, attrs, ns)
        if defined?(super)
          super
          @proc_stack.pop
          @proc_stack.push(Proc.new do |text, tags|
            validate_atom_feed_for_stream(tags) if @do_validate
          end)
        else
          start_else_element(tag_name, prefix, attrs, ns)
        end
      end

      def validate_atom_feed_for_stream(tags)
        @rss.validate_for_stream(tags)
      rescue MissingTagError => error
        raise unless error.tag == "author" and entries_had_author?
      end

      def stream_entry_class?(klass)
        stream_entry_classes.any? {|entry_class| klass <= entry_class}
      end

      def stream_entry_classes
        classes = []
        if defined?(RSS::Rss::Channel::Item)
          classes << RSS::Rss::Channel::Item
        end
        if defined?(RSS::Atom::Feed::Entry)
          classes << RSS::Atom::Feed::Entry
        end
        classes
      end

      def emit_entry_event(parent, tag_name, klass)
        entry = detach_entry(parent, tag_name, klass)
        entry.parent ||= parent
        @entry_count += 1
        remember_entry_id(entry)
        if entry.respond_to?(:have_author?) and entry.have_author?(false)
          @entries_had_author = true
        end
        emit_metadata_event unless @metadata_event_emitted
        @event_handler.call(EntryEvent.new(entry, @entry_count))
      end

      def detach_entry(parent, tag_name, klass)
        key = tag_name.gsub(/-/, "_")
        key = "#{klass.required_prefix}_#{key}" if klass.required_prefix
        plural_name = parent.class.plural_forms[key]
        parent.__send__(plural_name).pop
      end

      def remember_entry_id(entry)
        id = entry_id(entry)
        return if id.nil? or id.empty?
        first_index = @seen_entry_ids[id]
        if first_index
          @duplicate_id_errors <<
            DuplicateEntryIDError.new(id, first_index, @entry_count)
        else
          @seen_entry_ids[id] = @entry_count
        end
      end

      def entry_id(entry)
        if defined?(RSS::Atom::Feed::Entry) and
            entry.is_a?(RSS::Atom::Feed::Entry)
          id = entry.id
          id && id.content
        elsif defined?(RSS::Rss::Channel::Item) and
            entry.is_a?(RSS::Rss::Channel::Item)
          guid = entry.guid
          guid && guid.content
        end
      end

      def emit_metadata_event
        @metadata_event_emitted = true
        @event_handler.call(MetadataEvent.new(feed_metadata))
      end

      def feed_metadata
        root = @rss
        if root.respond_to?(:channel) and root.channel
          root.channel
        else
          root
        end
      end
    end

    class << self

      # Parses a feed from +source+ and yields an event for each entry
      # as soon as the entry is completely parsed, instead of building
      # the whole document in memory first. This is useful for feeds
      # with a very large number of entries that are processed one by
      # one, for example when importing a subscription into a
      # database.
      #
      #   RSS::Parser.each_entry(io) do |event|
      #     case event
      #     when RSS::Parser::MetadataEvent
      #       puts "feed: #{event.feed.title}"
      #     when RSS::Parser::EntryEvent
      #       puts "entry #{event.index}: #{event.entry.title}"
      #     end
      #   end
      #
      # RSS 2.0 (and 0.9x) items and Atom entries are supported.
      # Yielded entries are detached from their feed, so the parser
      # does not keep them in memory; each entry still references its
      # feed through RSS::Element#parent for inherited metadata.
      #
      # +source+ may be an IO like object (anything that responds to
      # +read+, even one that only serves short reads), an XML string,
      # a file path, or a URI. An IO like +source+ is owned by the
      # caller and is not closed; a source that is opened by this
      # method (a file path, a URI, or an XML string) is closed before
      # this method returns.
      #
      # The remaining arguments are the same as for Parser.parse:
      # +validate+, +ignore_unknown_element+ and +parser_class+, each
      # either positioned or as an option.
      #
      # When the consumer breaks out of the block, reading stops and
      # the rest of the source is left unread. Otherwise the whole
      # document is consumed and a Parser::StreamResult is returned
      # that reports whether the document was complete and valid.
      # Having received entries does not imply that the document
      # turned out to be valid in the end; check the result.
      def each_entry(source, *args)
        raise ArgumentError, "a block is required" unless block_given?

        if args.last.is_a?(Hash)
          options = args.pop
        else
          options = {}
        end
        do_validate = boolean_argument(args[0], options[:validate], true)
        ignore_unknown_element =
          boolean_argument(args[1], options[:ignore_unknown_element], true)
        parser_class = args[2] || options[:parser_class] || default_parser

        source_io, owned = normalize_entry_source(source)
        io = wrap_entry_source(source_io)
        listener = stream_listener_class(parser_class).new
        listener.do_validate = do_validate
        listener.ignore_unknown_element = ignore_unknown_element
        result = StreamResult.new
        listener.event_handler = proc do |event|
          result.send(:record_event, event)
          yield event
        end
        begin
          parser_class.new(io, listener).parse
          listener.emit_pending_metadata_event
          if do_validate
            validate_stream_result(listener, result, ignore_unknown_element)
          end
          result.send(:mark_complete)
        rescue RSS::Error => error
          result.errors << error
        ensure
          source_io.close if owned
          result.send(:feed=, listener.rss)
        end
        result
      end

      private

      def wrap_entry_source(source)
        if source.is_a?(::IO) or source.is_a?(StringIO)
          source
        else
          BufferedIO.new(source)
        end
      end

      def stream_listener_class(parser_class)
        @stream_listener_classes ||= {}
        @stream_listener_classes[parser_class] ||=
          Class.new(parser_class.listener) do
            include StreamListenerMixin
          end
      end

      def validate_stream_result(listener, result, ignore_unknown_element)
        root = listener.rss
        unless root.nil?
          begin
            root.validate(ignore_unknown_element)
          rescue MissingTagError => error
            unless error.tag == "author" and listener.entries_had_author?
              result.errors << error
            end
          rescue RSS::Error => error
            result.errors << error
          end
        end
        result.errors.concat(listener.duplicate_id_errors)
      end

      # Returns an IO like object for +source+ and whether this method
      # owns it (and therefore has to close it).
      def normalize_entry_source(source)
        return [source, false] if source.respond_to?(:read)
        if source.is_a?(::URI::Generic)
          return [::URI.open(source), true]
        end
        if source.is_a?(String)
          return [StringIO.new(source), true] if maybe_xml?(source)
          uri = to_uri(source)
          if uri.is_a?(::URI::Generic) and uri.scheme
            return [::URI.open(uri), true]
          end
          return [File.open(source, "r"), true] if File.readable?(source)
        end
        raise ArgumentError,
              "don't know how to read an entry stream from #{source.inspect}"
      end

      def maybe_xml?(source)
        source.is_a?(String) and /</ =~ source
      end

      def to_uri(source)
        return source if source.is_a?(::URI::Generic)
        begin
          ::URI.parse(source)
        rescue ::URI::Error
          source
        end
      end
    end
  end
end
