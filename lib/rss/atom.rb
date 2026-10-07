# frozen_string_literal: false
require_relative 'parser'

module RSS
  ##
  # Atom is an XML-based document format that is used to describe 'feeds' of related information.
  # A typical use is in a news feed where the information is periodically updated and which users
  # can subscribe to.  The Atom format is described in http://tools.ietf.org/html/rfc4287
  #
  # The Atom module provides support in reading and creating feeds.
  #
  # See the RSS module for examples consuming and creating feeds.
  module Atom

    ##
    # The Atom URI W3C Namespace

    URI = "http://www.w3.org/2005/Atom"

    ##
    # The XHTML URI W3C Namespace

    XHTML_URI = "http://www.w3.org/1999/xhtml"

    ##
    # The namespace used by the Atom tombstone extension defined in
    # RFC 6721.

    TOMBSTONE_URI = "http://purl.org/atompub/tombstones/1.0"

    module CommonModel
      NSPOOL = {}
      ELEMENTS = []

      def self.append_features(klass)
        super
        klass.install_must_call_validator("atom", URI)
        [
         ["lang", :xml],
         ["base", :xml],
        ].each do |name, uri, required|
          klass.install_get_attribute(name, uri, required, [nil, :inherit])
        end
        klass.class_eval do
          class << self
            # Returns the Atom URI W3C Namespace
            def required_uri
              URI
            end

            # Returns true
            def need_parent?
              true
            end
          end
        end
      end
    end

    module ContentModel
      module ClassMethods
        def content_type
          @content_type ||= nil
        end
      end

      class << self
        def append_features(klass)
          super
          klass.extend(ClassMethods)
          klass.content_setup(klass.content_type, klass.tag_name)
        end
      end

      def maker_target(target)
        target
      end

      private
      def setup_maker_element_writer
        "#{self.class.name.split(/::/).last.downcase}="
      end

      def setup_maker_element(target)
        target.__send__(setup_maker_element_writer, content)
        super
      end
    end

    module URIContentModel
      class  << self
        def append_features(klass)
          super
          klass.class_eval do
            @content_type = [nil, :uri]
            include(ContentModel)
          end
        end
      end
    end

    # The TextConstruct module is used to define a Text construct Atom element,
    # which is used to store small quantities of human-readable text.
    #
    # The TextConstruct has a type attribute, e.g. text, html, xhtml
    #
    # Reference: https://validator.w3.org/feed/docs/rfc4287.html#text.constructs
    module TextConstruct
      def self.append_features(klass)
        super
        klass.class_eval do
          [
           ["type", ""],
          ].each do |name, uri, required|
            install_get_attribute(name, uri, required, :text_type)
          end

          content_setup
          add_need_initialize_variable("xhtml")

          class << self
            def xml_getter
              "xhtml"
            end

            def xml_setter
              "xhtml="
            end
          end
        end
      end

      attr_writer :xhtml

      # Returns or builds the XHTML content.
      def xhtml
        return @xhtml if @xhtml.nil?
        if @xhtml.is_a?(XML::Element) and
            [@xhtml.name, @xhtml.uri] == ["div", XHTML_URI]
          return @xhtml
        end

        children = @xhtml
        children = [children] unless children.is_a?(Array)
        XML::Element.new("div", nil, XHTML_URI,
                         {"xmlns" => XHTML_URI}, children)
      end

      # Returns true if type is "xhtml".
      def have_xml_content?
        @type == "xhtml"
      end

      # Raises a MissingTagError or NotExpectedTagError
      # if the element is not properly formatted.
      def atom_validate(ignore_unknown_element, tags, uri)
        if have_xml_content?
          if @xhtml.nil?
            raise MissingTagError.new("div", tag_name)
          end
          unless [@xhtml.name, @xhtml.uri] == ["div", XHTML_URI]
            raise NotExpectedTagError.new(@xhtml.name, @xhtml.uri, tag_name)
          end
        end
      end

      private
      def maker_target(target)
        target.__send__(self.class.name.split(/::/).last.downcase) {|x| x}
      end

      def setup_maker_attributes(target)
        target.type = type
        target.content = content
        target.xml_content = @xhtml
      end
    end

    # The PersonConstruct module is used to define a person Atom element that can be
    # used to describe a person, corporation or similar entity.
    #
    # The PersonConstruct has a Name, Uri and Email child elements.
    #
    # Reference: https://validator.w3.org/feed/docs/rfc4287.html#atomPersonConstruct
    module PersonConstruct

      # Adds attributes for name, uri, and email to the +klass+
      def self.append_features(klass)
        super
        klass.class_eval do
          [
           ["name", nil],
           ["uri", "?"],
           ["email", "?"],
          ].each do |tag, occurs|
            install_have_attribute_element(tag, URI, occurs, nil, :content)
          end
        end
      end

      def maker_target(target)
        target.__send__("new_#{self.class.name.split(/::/).last.downcase}")
      end

      # The name of the person or entity.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.name
      class Name < RSS::Element
        include CommonModel
        include ContentModel
      end

      # The URI of the person or entity.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.uri
      class Uri < RSS::Element
        include CommonModel
        include URIContentModel
      end

      # The email of the person or entity.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.email
      class Email < RSS::Element
        include CommonModel
        include ContentModel
      end
    end

    # Element used to describe an Atom date and time in the ISO 8601 format
    #
    # Examples:
    # * 2013-03-04T15:30:02Z
    # * 2013-03-04T10:30:02-05:00
    module DateConstruct
      def self.append_features(klass)
        super
        klass.class_eval do
          @content_type = :w3cdtf
          include(ContentModel)
        end
      end

      # Raises NotAvailableValueError if element content is nil
      def atom_validate(ignore_unknown_element, tags, uri)
        raise NotAvailableValueError.new(tag_name, "") if content.nil?
      end
    end

    module DuplicateLinkChecker
      # Checks if there are duplicate links with the same type and hreflang attributes
      # that have an alternate (or empty) rel attribute
      #
      # Raises a TooMuchTagError if there are duplicates found
      def validate_duplicate_links(links)
        link_infos = {}
        links.each do |link|
          rel = link.rel || "alternate"
          next unless rel == "alternate"
          key = [link.hreflang, link.type]
          if link_infos.has_key?(key)
            raise TooMuchTagError.new("link", tag_name)
          end
          link_infos[key] = true
        end
      end
    end

    module TombstoneModel
      NSPOOL = {
        "at" => TOMBSTONE_URI,
        "atom" => URI,
      }

      def self.append_features(klass)
        super
        klass.install_must_call_validator("at", TOMBSTONE_URI)
        [
         ["lang", :xml],
         ["base", :xml],
        ].each do |name, uri, required|
          klass.install_get_attribute(name, uri, required, [nil, :inherit])
        end
        klass.class_eval do
          class << self

            def need_parent?
              true
            end
          end
        end
      end
    end

    # Defines the top-level element of an Atom Feed Document.
    # It consists of a number of children Entry elements,
    # and has the following attributes:
    #
    # * author
    # * categories
    # * category
    # * content
    # * contributor
    # * entries (aliased as items)
    # * entry
    # * generator
    # * icon
    # * id
    # * link
    # * logo
    # * rights
    # * subtitle
    # * title
    # * updated
    #
    # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.feed
    class Feed < RSS::Element
      include RootElementMixin
      include CommonModel
      include DuplicateLinkChecker

      install_ns('', URI)

      [
       ["author", "*", :children],
       ["category", "*", :children, "categories"],
       ["contributor", "*", :children],
       ["generator", "?"],
       ["icon", "?", nil, :content],
       ["id", nil, nil, :content],
       ["link", "*", :children],
       ["logo", "?"],
       ["rights", "?"],
       ["subtitle", "?", nil, :content],
       ["title", nil, nil, :content],
       ["updated", nil, nil, :content],
       ["entry", "*", :children, "entries"],
      ].each do |tag, occurs, type, *args|
        type ||= :child
        __send__("install_have_#{type}_element",
                 tag, URI, occurs, tag, *args)
      end
      add_have_children_element("at_deleted_entry", "at_deleted_entries")
      add_plural_form("at_deleted_entry", "at_deleted_entries")
      add_to_element_method("at_deleted_entries_element")
      module_eval do
        def at_deleted_entries_element(need_convert=true, indent='')
          @at_deleted_entries.collect do |deleted_entry|
            deleted_entry.to_s(need_convert, indent)
          end.join("\n")
        end
        private :at_deleted_entries_element
      end

      # Creates a new Atom feed
      def initialize(version=nil, encoding=nil, standalone=nil)
        super("1.0", version, encoding, standalone)
        @feed_type = "atom"
        @feed_subtype = "feed"
        @at_deleted_entries ||= []
      end

      attr_accessor :seen_tombstone

      alias_method :items, :entries
      def deleted_entry
        @at_deleted_entries.first
      end

      def deleted_entries
        @at_deleted_entries
      end

      # Returns true if there are any authors for the feed or any of the Entry
      # child elements have an author
      def have_author?
        authors.any? {|author| !author.to_s.empty?} or
          entries.any? {|entry| entry.have_author?(false)}
      end

      private
      def _validate(ignore_unknown_element, tags, uri, models=self.class.models)
        return super unless uri == URI and seen_tombstone
        atom_models = models.find_all {|_, model_uri| model_uri == uri}
        model_names = atom_models.collect {|name,| name}
        atom_tags = Array(tags).reject do |tag|
          tag_name = tag.is_a?(Array) ? tag.last : tag
          tag_name == "deleted-entry"
        end
        atom_tags = atom_tags.collect do |tag|
          tag.is_a?(Array) ? tag.last : tag
        end
        atom_tags = atom_tags.sort_by do |name|
          model_names.index(name) || model_names.size
        end
        return if atom_tags.empty?
      end

      def ns_declarations
        declarations = super
        if deleted_entries.any?
          declarations["xmlns:at"] = TOMBSTONE_URI
        end
        declarations
      end

      def atom_validate(ignore_unknown_element, tags, uri)
        unless have_author?
          raise MissingTagError.new("author", tag_name)
        end
        validate_duplicate_links(links)
      end

      def have_required_elements?
        super and have_author?
      end

      def maker_target(maker)
        maker.channel
      end

      def setup_maker_element(channel)
        prev_dc_dates = channel.dc_dates.to_a.dup
        super
        channel.about = id.content if id
        channel.dc_dates.replace(prev_dc_dates)
      end

      def setup_maker_elements(channel)
        super
        items = channel.maker.items
        entries.each do |entry|
          entry.setup_maker(items)
        end
      end

      # PersonConstruct that contains information regarding the author
      # of a Feed or Entry.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.author
      class Author < RSS::Element
        include CommonModel
        include PersonConstruct
      end

      # Contains information about a category associated with a Feed or Entry.
      # It has the following attributes:
      #
      # * term
      # * scheme
      # * label
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.category
      class Category < RSS::Element
        include CommonModel

        [
         ["term", "", true],
         ["scheme", "", false, [nil, :uri]],
         ["label", ""],
        ].each do |name, uri, required, type|
          install_get_attribute(name, uri, required, type)
        end

        private
        def maker_target(target)
          target.new_category
        end
      end

      # PersonConstruct that contains information regarding the
      # contributors of a Feed or Entry.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.contributor
      class Contributor < RSS::Element
        include CommonModel
        include PersonConstruct
      end

      # Contains information on the agent used to generate the feed.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.generator
      class Generator < RSS::Element
        include CommonModel
        include ContentModel

        [
         ["uri", "", false, [nil, :uri]],
         ["version", ""],
        ].each do |name, uri, required, type|
          install_get_attribute(name, uri, required, type)
        end

        private
        def setup_maker_attributes(target)
          target.generator do |generator|
            generator.uri = uri if uri
            generator.version = version if version
          end
        end
      end

      # Defines an image that provides a visual identification for a eed.
      # The image should have an aspect ratio of 1:1.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.icon
      class Icon < RSS::Element
        include CommonModel
        include URIContentModel
      end

      # Defines the Universally Unique Identifier (UUID) for a Feed or Entry.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.id
      class Id < RSS::Element
        include CommonModel
        include URIContentModel
      end

      # Defines a reference to a Web resource. It has the following
      # attributes:
      #
      # * href
      # * rel
      # * type
      # * hreflang
      # * title
      # * length
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.link
      class Link < RSS::Element
        include CommonModel

        [
         ["href", "", true, [nil, :uri]],
         ["rel", ""],
         ["type", ""],
         ["hreflang", ""],
         ["title", ""],
         ["length", ""],
        ].each do |name, uri, required, type|
          install_get_attribute(name, uri, required, type)
        end

        private
        def maker_target(target)
          target.new_link
        end
      end

      # Defines an image that provides a visual identification for the Feed.
      # The image should have an aspect ratio of 2:1 (horizontal:vertical).
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.logo
      class Logo < RSS::Element
        include CommonModel
        include URIContentModel

        def maker_target(target)
          target.maker.image
        end

        private
        def setup_maker_element_writer
          "url="
        end
      end

      # TextConstruct that contains copyright information regarding
      # the content in an Entry or Feed. It should not be used to
      # convey machine readable licensing information.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.rights
      class Rights < RSS::Element
        include CommonModel
        include TextConstruct
      end

      # TextConstruct that conveys a description or subtitle for a Feed.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.subtitle
      class Subtitle < RSS::Element
        include CommonModel
        include TextConstruct
      end

      # TextConstruct that conveys a description or title for a Feed or Entry.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.title
      class Title < RSS::Element
        include CommonModel
        include TextConstruct
      end

      # DateConstruct indicating the most recent time when a Feed or
      # Entry was modified in a way the publisher considers
      # significant.
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.updated
      class Updated < RSS::Element
        include CommonModel
        include DateConstruct
      end

      # A tombstone that records the deletion of the Atom Entry identified
      # by the +ref+ attribute.
      #
      # Reference: RFC 6721 section 3
      class TombstoneEntry < RSS::Element
        include TombstoneModel

        install_get_attribute("ref", "", true, [nil, :uri])
        # +when+ is defined explicitly below so a Time value passed by
        # the maker does not get parsed again.

        install_have_child_element("by", TOMBSTONE_URI, "?", "at_by")
        install_have_child_element("comment", TOMBSTONE_URI, "?",
                                   "at_comment")
        add_to_element_method("at_extensions_element")

        attr_accessor :extensions, :extension_attributes,
                      :extension_namespaces
        attr_reader :when_attribute_missing
        attr_reader :when

        def initialize(*args)
          super
          @extensions ||= []
          @extension_attributes ||= {}
          @extension_namespaces ||= {}
        end

        def full_name
          "at:deleted-entry"
        end

        def by
          @at_by
        end

        def comment
          @at_comment
        end

        def by=(value)
          @at_by = value
          @at_by.parent = self unless value.nil?
        end

        def comment=(value)
          @at_comment = value
          @at_comment.parent = self unless value.nil?
        end

        def converter=(converter)
          super
          by.converter = converter unless by.nil?
          comment.converter = converter unless comment.nil?
        end

        def at_extensions_element(need_convert=true, indent='')
          extensions.collect do |extension|
            "#{indent}#{extension}"
          end.join("\n")
        end

        def collect_attrs
          attributes = super
          return nil if attributes.nil?
          attributes["when"] = @when&.w3cdtf unless @when.nil?
          attributes.update(extension_namespaces)
          attributes.update(extension_attributes)
          attributes
        end

        def when=(value)
          @when_attribute_missing = value.nil? or value.to_s.empty?
          @when =
            if value.class.name.start_with?("Time", "DateTime")
              value
            elsif @when_attribute_missing
              nil
            else
              begin
                Time.w3cdtf(value)
              rescue ArgumentError
                Time.parse(value)
              end
            end
        end

        def at_validate(ignore_unknown_element, tags, uri)
          if self.when.nil?
            raise MissingAttributeError.new(tag_name, "when")
          end
          known_tags = Array(tags).find_all do |tag_uri, tag_name|
            tag_uri == TOMBSTONE_URI and ["by", "comment"].include?(tag_name)
          end
          _validate(ignore_unknown_element, known_tags, TOMBSTONE_URI)
        end

        private

        # The entity responsible for deleting an entry.
        class By < Feed::Author
          class << self
            def required_prefix
              nil
            end

            def required_uri
              TOMBSTONE_URI
            end
          end

          def full_name
            standalone_tombstone? ? "by" : "at:by"
          end

          def standalone_tombstone?
            parent.is_a?(Atom::DeletedEntry)
          end

          def self.need_parent?
            true
          end

          alias_method :atom_name, :name
          alias_method :atom_uri, :uri
          alias_method :atom_email, :email
          alias_method :name_element_without_tombstone,
                       :name_element
          alias_method :uri_element_without_tombstone,
                       :uri_element
          alias_method :email_element_without_tombstone,
                       :email_element

          def name_element(need_convert=true, indent='')
            value = name_element_without_tombstone(need_convert, indent)
            return value unless standalone_tombstone?
            value.sub("<name", "<atom:name")
              .sub("</name>", "</atom:name>")
          end

          def uri_element(need_convert=true, indent='')
            value = uri_element_without_tombstone(need_convert, indent)
            return value unless standalone_tombstone?
            value.sub("<uri", "<atom:uri")
              .sub("</uri>", "</atom:uri>")
          end

          def email_element(need_convert=true, indent='')
            value = email_element_without_tombstone(need_convert, indent)
            return value unless standalone_tombstone?
            value.sub("<email", "<atom:email")
              .sub("</email>", "</atom:email>")
          end
        end

        # A human-readable explanation of why the entry was deleted.
        class Comment < RSS::Element
          include TombstoneModel
          include ContentModel

          class << self
            def required_prefix
              nil
            end
          end

          def full_name
            parent.is_a?(Atom::DeletedEntry) ? "comment" : "at:comment"
          end
        end
      end

      # Defines a child Atom Entry element of an Atom Feed element.
      # It has the following attributes:
      #
      # * author
      # * category
      # * categories
      # * content
      # * contributor
      # * id
      # * link
      # * published
      # * rights
      # * source
      # * summary
      # * title
      # * updated
      #
      # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.entry
      class Entry < RSS::Element
        include CommonModel
        include DuplicateLinkChecker

        [
         ["author", "*", :children],
         ["category", "*", :children, "categories"],
         ["content", "?", :child],
         ["contributor", "*", :children],
         ["id", nil, nil, :content],
         ["link", "*", :children],
         ["published", "?", :child, :content],
         ["rights", "?", :child],
         ["source", "?"],
         ["summary", "?", :child],
         ["title", nil],
         ["updated", nil, :child, :content],
        ].each do |tag, occurs, type, *args|
          type ||= :attribute
          __send__("install_have_#{type}_element",
                   tag, URI, occurs, tag, *args)
        end

        # Returns whether any of the following are true:
        #
        # * There are any authors in the feed
        # * If the parent element has an author and the +check_parent+
        #   parameter was given.
        # * There is a source element that has an author
        def have_author?(check_parent=true)
          authors.any? {|author| !author.to_s.empty?} or
            (check_parent and @parent and @parent.have_author?) or
            (source and source.have_author?)
        end

        private
        def atom_validate(ignore_unknown_element, tags, uri)
          unless have_author?
            raise MissingTagError.new("author", tag_name)
          end
          validate_duplicate_links(links)
        end

        def have_required_elements?
          super and have_author?
        end

        def maker_target(items)
          if items.respond_to?("items")
            # For backward compatibility
            items = items.items
          end
          items.new_item
        end

        # Feed::Author
        Author = Feed::Author
        # Feed::Category
        Category = Feed::Category

        # Contains or links to the content of the Entry.
        # It has the following attributes:
        #
        # * type
        # * src
        #
        # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.content
        class Content < RSS::Element
          include CommonModel

          class << self
            def xml_setter
              "xml="
            end

            def xml_getter
              "xml"
            end
          end

          [
           ["type", ""],
           ["src", "", false, [nil, :uri]],
          ].each do |name, uri, required, type|
            install_get_attribute(name, uri, required, type)
          end

          content_setup
          add_need_initialize_variable("xml")

          # Returns the element content in XML.
          attr_writer :xml

          # Returns true if the element has inline XML content.
          def have_xml_content?
            inline_xhtml? or inline_other_xml?
          end

          # Returns or builds the element content in XML.
          def xml
            return @xml unless inline_xhtml?
            return @xml if @xml.nil?
            if @xml.is_a?(XML::Element) and
                [@xml.name, @xml.uri] == ["div", XHTML_URI]
              return @xml
            end

            children = @xml
            children = [children] unless children.is_a?(Array)
            XML::Element.new("div", nil, XHTML_URI,
                             {"xmlns" => XHTML_URI}, children)
          end

          # Returns the element content in XHTML.
          def xhtml
            if inline_xhtml?
              xml
            else
              nil
            end
          end

          # Raises a MissingAttributeError, NotAvailableValueError,
          # MissingTagError or NotExpectedTagError if the element is
          # not properly formatted.
          def atom_validate(ignore_unknown_element, tags, uri)
            if out_of_line?
              raise MissingAttributeError.new(tag_name, "type") if @type.nil?
              unless (content.nil? or content.empty?)
                raise NotAvailableValueError.new(tag_name, content)
              end
            elsif inline_xhtml?
              if @xml.nil?
                raise MissingTagError.new("div", tag_name)
              end
              unless @xml.name == "div" and @xml.uri == XHTML_URI
                raise NotExpectedTagError.new(@xml.name, @xml.uri, tag_name)
              end
            end
          end

          # Returns true if the element contains inline content
          # that has a text or HTML media type, or no media type at all.
          def inline_text?
            !out_of_line? and [nil, "text", "html"].include?(@type)
          end

          # Returns true if the element contains inline content that
          # has a HTML media type.
          def inline_html?
            return false if out_of_line?
            @type == "html" or mime_split == ["text", "html"]
          end

          # Returns true if the element contains inline content that
          # has a XHTML media type.
          def inline_xhtml?
            !out_of_line? and @type == "xhtml"
          end

          # Returns true if the element contains inline content that
          # has a MIME media type.
          def inline_other?
            return false if out_of_line?
            media_type, subtype = mime_split
            return false if media_type.nil? or subtype.nil?
            true
          end

          # Returns true if the element contains inline content that
          # has a text media type.
          def inline_other_text?
            return false unless inline_other?
            return false if inline_other_xml?

            media_type, = mime_split
            return true if "text" == media_type.downcase
            false
          end

          # Returns true if the element contains inline content that
          # has a XML media type.
          def inline_other_xml?
            return false unless inline_other?

            media_type, subtype = mime_split
            normalized_mime_type = "#{media_type}/#{subtype}".downcase
            if /(?:\+xml|^xml)$/ =~ subtype or
                %w(text/xml-external-parsed-entity
                   application/xml-external-parsed-entity
                   application/xml-dtd).find {|x| x == normalized_mime_type}
              return true
            end
            false
          end

          # Returns true if the element contains inline content
          # encoded in base64.
          def inline_other_base64?
            inline_other? and !inline_other_text? and !inline_other_xml?
          end

          # Returns true if the element contains linked content.
          def out_of_line?
            not @src.nil?
          end

          # Splits the type attribute into an array, e.g. ["text", "xml"]
          def mime_split
            media_type = subtype = nil
            if /\A\s*([a-z]+)\/([a-z\+]+)\s*(?:;.*)?\z/i =~ @type.to_s
              media_type = $1.downcase
              subtype = $2.downcase
            end
            [media_type, subtype]
          end

          # Returns true if the content needs to be encoded in base64.
          def need_base64_encode?
            inline_other_base64?
          end

          private
          def empty_content?
            out_of_line? or super
          end
        end

        # Feed::Contributor
        Contributor = Feed::Contributor
        # Feed::Id
        Id = Feed::Id
        # Feed::Link
        Link = Feed::Link

        # DateConstruct that usually indicates the time of the initial
        # creation of an Entry.
        #
        # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.published
        class Published < RSS::Element
          include CommonModel
          include DateConstruct
        end

        # Feed::Rights
        Rights = Feed::Rights

        # Defines a Atom Source element. It has the following attributes:
        #
        # * author
        # * category
        # * categories
        # * content
        # * contributor
        # * generator
        # * icon
        # * id
        # * link
        # * logo
        # * rights
        # * subtitle
        # * title
        # * updated
        #
        # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.source
        class Source < RSS::Element
          include CommonModel

          [
           ["author", "*", :children],
           ["category", "*", :children, "categories"],
           ["contributor", "*", :children],
           ["generator", "?"],
           ["icon", "?"],
           ["id", "?", nil, :content],
           ["link", "*", :children],
           ["logo", "?"],
           ["rights", "?"],
           ["subtitle", "?"],
           ["title", "?"],
           ["updated", "?", nil, :content],
          ].each do |tag, occurs, type, *args|
            type ||= :attribute
            __send__("install_have_#{type}_element",
                     tag, URI, occurs, tag, *args)
          end

          # Returns true if the Source element has an author.
          def have_author?
            !author.to_s.empty?
          end

          # Feed::Author
          Author = Feed::Author
          # Feed::Category
          Category = Feed::Category
          # Feed::Contributor
          Contributor = Feed::Contributor
          # Feed::Generator
          Generator = Feed::Generator
          # Feed::Icon
          Icon = Feed::Icon
          # Feed::Id
          Id = Feed::Id
          # Feed::Link
          Link = Feed::Link
          # Feed::Logo
          Logo = Feed::Logo
          # Feed::Rights
          Rights = Feed::Rights
          # Feed::Subtitle
          Subtitle = Feed::Subtitle
          # Feed::Title
          Title = Feed::Title
          # Feed::Updated
          Updated = Feed::Updated
        end

        # TextConstruct that describes a summary of the Entry.
        #
        # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.summary
        class Summary < RSS::Element
          include CommonModel
          include TextConstruct
        end

        # Feed::Title
        Title = Feed::Title
        # Feed::Updated
        Updated = Feed::Updated
      end
    end

    # Defines a top-level Atom Entry element,
    # used as the document element of a stand-alone Atom Entry Document.
    # It has the following attributes:
    #
    # * author
    # * category
    # * categories
    # * content
    # * contributor
    # * id
    # * link
    # * published
    # * rights
    # * source
    # * summary
    # * title
    # * updated
    #
    # Reference: https://validator.w3.org/feed/docs/rfc4287.html#element.entry]
    class Entry < RSS::Element
      include RootElementMixin
      include CommonModel
      include DuplicateLinkChecker

      [
       ["author", "*", :children],
       ["category", "*", :children, "categories"],
       ["content", "?"],
       ["contributor", "*", :children],
       ["id", nil, nil, :content],
       ["link", "*", :children],
       ["published", "?", :child, :content],
       ["rights", "?"],
       ["source", "?"],
       ["summary", "?"],
       ["title", nil],
       ["updated", nil, nil, :content],
      ].each do |tag, occurs, type, *args|
        type ||= :attribute
        __send__("install_have_#{type}_element",
                 tag, URI, occurs, tag, *args)
      end

      # Creates a new Atom Entry element.
      def initialize(version=nil, encoding=nil, standalone=nil)
        super("1.0", version, encoding, standalone)
        @feed_type = "atom"
        @feed_subtype = "entry"
      end

      # Returns the Entry in an array.
      def items
        [self]
      end

      # Sets up the +maker+ for constructing Entry elements.
      def setup_maker(maker)
        maker = maker.maker if maker.respond_to?("maker")
        super(maker)
      end

      # Returns where there are any authors present or there is a
      # source with an author.
      def have_author?
        authors.any? {|author| !author.to_s.empty?} or
          (source and source.have_author?)
      end

      private
      def atom_validate(ignore_unknown_element, tags, uri)
        unless have_author?
          raise MissingTagError.new("author", tag_name)
        end
        validate_duplicate_links(links)
      end

      def have_required_elements?
        super and have_author?
      end

      def maker_target(maker)
        maker.items.new_item
      end

      # Feed::Entry::Author
      Author = Feed::Entry::Author
      # Feed::Entry::Category
      Category = Feed::Entry::Category
      # Feed::Entry::Content
      Content = Feed::Entry::Content
      # Feed::Entry::Contributor
      Contributor = Feed::Entry::Contributor
      # Feed::Entry::Id
      Id = Feed::Entry::Id
      # Feed::Entry::Link
      Link = Feed::Entry::Link
      # Feed::Entry::Published
      Published = Feed::Entry::Published
      # Feed::Entry::Rights
      Rights = Feed::Entry::Rights
      # Feed::Entry::Source
      Source = Feed::Entry::Source
      # Feed::Entry::Summary
      Summary = Feed::Entry::Summary
      # Feed::Entry::Title
      Title = Feed::Entry::Title
      # Feed::Entry::Updated
      Updated = Feed::Entry::Updated
    end

    # Defines a top-level Atom tombstone document.
    #
    # Reference: RFC 6721 section 3
    class DeletedEntry < Feed::TombstoneEntry
      include RootElementMixin

      NSPOOL = {
        "" => TOMBSTONE_URI,
        "atom" => URI,
      }

      def initialize(version=nil, encoding=nil, standalone=nil)
        super("1.0", version, encoding, standalone)
        @feed_type = "atom"
        @feed_subtype = "deleted-entry"
      end

      def full_name
        "deleted-entry"
      end
    end
  end

  Atom::CommonModel::ELEMENTS.each do |name|
    BaseListener.install_get_text_element(Atom::URI, name, "#{name}=")
  end

  module ListenerMixin
    alias_method :start_else_element_without_tombstone, :start_else_element
    alias_method :tag_start_without_tombstone, :tag_start

    public
    def tag_start(name, attributes)
      ns = @ns_stack.last.dup
      attrs = {}
      attributes.each do |attribute_name, value|
        if /\Axmlns(?:\z|:)/ =~ attribute_name
          ns[$POSTMATCH] = value
        else
          attrs[attribute_name] = value
        end
      end

      prefix, local = split_name(name)
      previous_element = @last_element
      if previous_element.nil? and local == "deleted-entry" and
          _ns(ns, prefix) == Atom::TOMBSTONE_URI
        @text_stack.push('')
        @ns_stack.push(ns)
        @tag_stack.last.push([_ns(ns, prefix), local])
        @tag_stack.push([])
        initial_start_deleted_entry(local, prefix, attrs, ns.dup)
        return
      end
      tag_start_without_tombstone(name, attributes)
      if !@xml_child_mode and local == "deleted-entry" and
          _ns(ns, prefix) == Atom::TOMBSTONE_URI and
          (previous_element.nil? or previous_element.is_a?(Atom::Feed))
        if previous_element.nil?
          initialize_tombstone_attributes(@rss, attrs, ns)
        else
          replace_unknown_tombstone(local, prefix, attrs, ns,
                                    previous_element)
          previous_element.seen_tombstone = true
        end
      end
    end

    private
    def initial_start_feed(tag_name, prefix, attrs, ns)
      check_ns(tag_name, prefix, ns, Atom::URI, false)

      @rss = Atom::Feed.new(@version, @encoding, @standalone)
      @rss.do_validate = @do_validate
      @rss.xml_stylesheets = @xml_stylesheets
      @rss.lang = attrs["xml:lang"]
      @rss.base = attrs["xml:base"]
      @last_element = @rss
      pr = Proc.new do |text, tags|
        @rss.validate_for_stream(tags) if @do_validate
      end
      @proc_stack.push(pr)
    end

    def initial_start_entry(tag_name, prefix, attrs, ns)
      check_ns(tag_name, prefix, ns, Atom::URI, false)

      @rss = Atom::Entry.new(@version, @encoding, @standalone)
      @rss.do_validate = @do_validate
      @rss.xml_stylesheets = @xml_stylesheets
      @rss.lang = attrs["xml:lang"]
      @rss.base = attrs["xml:base"]
      @last_element = @rss
      pr = Proc.new do |text, tags|
        @rss.validate_for_stream(tags) if @do_validate
      end
      @proc_stack.push(pr)
    end

    def initial_start_deleted_entry(tag_name, prefix, attrs, ns)
      check_ns(tag_name, prefix, ns, Atom::TOMBSTONE_URI, false)

      allow_missing_when = attrs["when"]&.to_s&.empty?
      @rss = Atom::DeletedEntry.new(@version, @encoding, @standalone)
      if attrs.key?("when")
        @rss.instance_variable_set(:@when, allow_missing_when ? nil :
                                   Time.w3cdtf(attrs["when"]))
        @rss.instance_variable_set(:@when_attribute_missing,
                                   allow_missing_when)
      end
      @rss.do_validate = @do_validate
      @rss.xml_stylesheets = @xml_stylesheets
      @rss.lang = attrs["xml:lang"]
      @rss.base = attrs["xml:base"]
      @last_element = @rss
      initialize_tombstone_attributes(@rss, attrs, ns)
      pr = Proc.new do |text, tags|
        @rss.validate_for_stream(tags) if
          @do_validate and !allow_missing_when
      end
      @proc_stack.push(pr)
    end

    def start_else_element(local, prefix, attrs, ns)
      known_tombstone_children = %w(by comment)
      if @last_element.is_a?(Atom::Feed::TombstoneEntry) and
          not (known_tombstone_children.include?(local) and
               [Atom::TOMBSTONE_URI, Atom::URI].include?(_ns(ns, prefix)))
        start_tombstone_extension_element(local, prefix, attrs, ns)
      else
        start_else_element_without_tombstone(local, prefix, attrs, ns)
      end
    end

    def start_by(local, prefix, attrs, ns)
      if @last_element.is_a?(Atom::Feed::TombstoneEntry) and
          _ns(ns, prefix) == Atom::TOMBSTONE_URI
        start_tombstone_named_child(local, prefix, attrs, ns,
                                    Atom::Feed::TombstoneEntry::By, :@at_by)
      else
        start_else_element_without_tombstone(local, prefix, attrs, ns)
      end
    end

    def start_comment(local, prefix, attrs, ns)
      if @last_element.is_a?(Atom::Feed::TombstoneEntry) and
          _ns(ns, prefix) == Atom::TOMBSTONE_URI
        start_tombstone_named_child(local, prefix, attrs, ns,
                                    Atom::Feed::TombstoneEntry::Comment,
                                    :@at_comment)
      else
        start_else_element_without_tombstone(local, prefix, attrs, ns)
      end
    end

    private
    def start_tombstone_named_child(tag_name, prefix, attrs, ns, klass,
                                    variable_name)
      if check_ns(tag_name, prefix, ns, Atom::TOMBSTONE_URI, false)
        previous = @last_element
        child = klass.new(@do_validate,
                          collect_attributes(tag_name, prefix, attrs, ns,
                                            klass))
        previous.instance_variable_set(variable_name, child)
        child.parent = previous
        @last_element = child
        @xml_child_mode = child.have_xml_content?

        Proc.new do |text, tags|
          child.content = text if klass.have_content?
          child.validate_for_stream(tags, @ignore_unknown_element) if
            @do_validate
          @last_element = previous
        end.tap do |callback|
          @proc_stack.push(callback)
        end
      else
        @proc_stack.push(setup_next_element_in_unknown_element)
      end
    end

      def replace_unknown_tombstone(tag_name, prefix, attrs, ns, parent)
        @proc_stack.pop
        parent.seen_tombstone = true
        deleted_entry_class = Atom::Feed::TombstoneEntry
        allow_missing_when = attrs["when"]&.to_s&.empty?
        attributes = collect_attributes(tag_name, prefix, attrs, ns,
                                       deleted_entry_class)
        deleted_entry = deleted_entry_class.allocate
        deleted_entry.send(:initialize, @do_validate, attributes)
        if allow_missing_when
          deleted_entry.instance_variable_set(:@when, nil)
          deleted_entry.instance_variable_set(:@when_attribute_missing, true)
        else
          deleted_entry.when = attrs["when"]
          deleted_entry.instance_variable_set(:@when_attribute_missing,
                                             false)
        end
        initialize_tombstone_attributes(deleted_entry, attrs, ns)
        parent.deleted_entries << deleted_entry
        @last_element = deleted_entry
        deleted_entry.parent = parent

        Proc.new do |text, tags|
          if @do_validate and !allow_missing_when
            deleted_entry.validate_for_stream(tags,
                                             @ignore_unknown_element)
          end
          @last_element = parent
        end.tap do |callback|
          @proc_stack.push(callback)
        end
      end

      def initialize_tombstone_attributes(deleted_entry, attrs, ns)
        known_attributes = ["ref", "when", "xml:lang", "xml:base"]
        deleted_entry.ref = attrs["ref"] if attrs.key?("ref")
        deleted_entry.instance_variable_set(:@when_attribute_missing,
                                           attrs["when"].to_s.empty?)
        deleted_entry.extension_attributes =
          attrs.reject {|name,| known_attributes.include?(name)}
        deleted_entry.extension_namespaces = ns.reject do |namespace_prefix, uri|
          namespace_prefix == "xml" or
            (namespace_prefix.empty? and
              [Atom::URI, Atom::TOMBSTONE_URI].include?(uri)) or
            (namespace_prefix == "at" and
              uri == Atom::TOMBSTONE_URI) or
            (namespace_prefix == "atom" and uri == Atom::URI)
        end.each_with_object({}) do |(namespace_prefix, uri), namespaces|
          name = namespace_prefix.empty? ? "xmlns" :
            "xmlns:#{namespace_prefix}"
          namespaces[name] = uri
        end
      end

      def remove_blank_extension_text(element)
        element.children.reject! do |child|
          child.is_a?(String) and child.strip.empty?
        end
        element.children.each do |child|
          remove_blank_extension_text(child) if child.is_a?(XML::Element)
        end
      end

      def start_tombstone_extension_element(local, prefix, attrs, ns)
        previous = @last_element
        element_attrs = attrs.dup
        ns.each do |namespace_prefix, uri|
          next if namespace_prefix == "xml"
          next if namespace_prefix.empty? and uri == Atom::URI
          next if namespace_prefix == "at" and
            uri == Atom::TOMBSTONE_URI
          key = namespace_prefix.empty? ? "xmlns" :
            "xmlns:#{namespace_prefix}"
          element_attrs[key] ||= uri
        end
        extension = XML::Element.new(local,
                                    prefix.empty? ? nil : prefix,
                                    _ns(ns, prefix),
                                    element_attrs)
        previous.extensions << extension
        @last_xml_element = extension
        @xml_child_mode = true

        Proc.new do
          remove_blank_extension_text(extension)
          @last_xml_element = nil
          @xml_element = nil
          @xml_child_mode = false
          @last_element = previous
        end
      end
  end
end
