# frozen_string_literal: true
# typed: false

require "ffi"

module Herb
  # Herb backend for Rubies that can't load the C extension, like JRuby.
  #
  # We call libherb through Ruby FFI. The C side (ffi/serialize.c) writes the AST
  # into a byte buffer, and Deserializer rebuilds the same Herb::AST objects the
  # C extension would, so the rest of Herb can't tell the difference.
  module FFI
    extend ::FFI::Library

    LIBRARY_NAME = "libherb_ffi.#{::FFI::Platform::LIBSUFFIX}".freeze

    ffi_lib ENV.fetch("HERB_FFI_LIBRARY") { File.expand_path("../../build/#{LIBRARY_NAME}", __dir__) }

    # hb_string_T
    class HbString < ::FFI::Struct
      layout :data, :pointer, :length, :uint32
    end

    # Sets erb_openers and erb_opener_count on an options struct. We hold on to the
    # strings here so they aren't garbage collected while libherb is using them.
    module ErbOpenersField
      def erb_openers=(openers)
        @erb_openers = Options.hb_strings(openers)
        self[:erb_openers] = @erb_openers.first
        self[:erb_opener_count] = openers.size
      end
    end

    # herb_extract_ruby_options_T
    class ExtractRubyOptions < ::FFI::Struct
      include ErbOpenersField

      layout(
        :semicolons, :bool,
        :comments, :bool,
        :preserve_positions, :bool,
        :custom_tags, :bool,
        :erb_openers, :pointer,
        :erb_opener_count, :size_t
      )
    end

    # blocking: true releases the GVL during the call, like the C extension does.
    attach_function :herb_ffi_parse, [:pointer, :pointer, :pointer, :pointer], :bool, blocking: true
    attach_function :herb_ffi_lex, [:pointer, :pointer, :pointer, :pointer], :bool, blocking: true
    attach_function :herb_ffi_diff, [:string, :string, :bool, :pointer, :pointer], :bool, blocking: true
    attach_function :herb_ffi_extract_ruby, [:string, :pointer], :pointer
    attach_function :herb_ffi_extract_html, [:string], :pointer
    attach_function :herb_ffi_free, [:pointer], :void
    attach_function :herb_ffi_parser_options_size, [], :size_t
    attach_function :herb_ffi_extract_ruby_options_size, [], :size_t
    attach_function :herb_ffi_parser_options_init, [:pointer], :void
    attach_function :herb_ffi_extract_ruby_options_init, [:pointer], :void
    attach_function :herb_ffi_default_erb_openings, [:pointer], :pointer
    attach_function :herb_ffi_token_type_count, [], :uint32
    attach_function :herb_ffi_token_type_name, [:uint32], HbString.by_value
    attach_function :herb_version, [], :string
    attach_function :herb_prism_version, [], :string

    # Token type names, indexed by token_type_T. The buffer only stores the number.
    TOKEN_TYPES = Array.new(herb_ffi_token_type_count) do |type|
      name = herb_ffi_token_type_name(type)
      -name[:data].read_bytes(name[:length]).force_encoding(Encoding::UTF_8)
    end.freeze

    module_function

    def check_string(source)
      raise TypeError, "wrong argument type #{source.class} (expected String)" unless source.is_a?(String)

      source
    end

    # Reads a C string that libherb allocated, then frees it.
    def read_and_free(pointer)
      raise NoMemoryError, "libherb failed to allocate a buffer" if pointer.null?

      pointer.read_string.force_encoding(Encoding::UTF_8)
    ensure
      herb_ffi_free(pointer) unless pointer.nil? || pointer.null?
    end

    # Gives a herb_ffi_* function somewhere to put its output buffer, then copies and frees it.
    def read_buffer
      ::FFI::MemoryPointer.new(:pointer) do |out|
        ::FFI::MemoryPointer.new(:size_t) do |out_length|
          raise NoMemoryError, "libherb failed to allocate a buffer" unless yield(out, out_length)

          data = out.read_pointer

          begin
            return data.read_bytes(out_length.read(:size_t))
          ensure
            herb_ffi_free(data)
          end
        end
      end
    end

    # Runs herb_ffi_parse or herb_ffi_lex. Like the C extension, nil parses as an empty string.
    def call(function, source, options)
      check_string(source) unless source.nil?

      parser_options = ParserOptionsStruct.new
      herb_ffi_parser_options_init(parser_options)
      parser_options.apply(options || {})

      error_count = ::FFI::MemoryPointer.new(:uint32)
      parser_options[:error_count] = error_count

      source_pointer = source && ::FFI::MemoryPointer.from_string(source)
      data = read_buffer { |out, out_length| send(function, source_pointer, parser_options, out, out_length) }

      [data, parser_options, error_count.read_uint32]
    end

    # Converts option values like the C extension does (NUM2UINT, NUM2DBL, Check_Type),
    # so bad values raise the same errors.
    module Options
      # Same as HERB_MAX_ERB_OPENERS in ext/herb/extension.c
      MAX_ERB_OPENERS = 64

      module_function

      def fetch(options, name)
        value = options[name.to_s]
        value.nil? ? options[name] : value
      end

      def given?(options, name)
        options.key?(name.to_s) || options.key?(name)
      end

      # Like NUM2UINT: accepts an Integer or Float up to 2**32 - 1. Negative values
      # down to -2**31 wrap around, just like in C.
      def uint(value)
        raise TypeError, "no implicit conversion of #{value.class} into Integer" unless value.is_a?(Integer) || value.is_a?(Float)

        integer = value.to_i
        raise RangeError, "integer #{integer} too big to convert to 'unsigned int'" unless integer.between?(-0x8000_0000, 0xFFFF_FFFF)

        integer & 0xFFFF_FFFF
      end

      # Converts seconds to milliseconds, clamped to fit the uint32 field in C.
      def milliseconds(value)
        raise TypeError, "no implicit conversion to float from #{value.class.name.downcase}" unless value.is_a?(Numeric)

        (value.to_f * 1000).to_i.clamp(0, 0xFFFF_FFFF)
      end

      # Builds an hb_string_T array for openers. Returns the array plus the string
      # memory, since all of it has to stay alive while libherb reads it.
      def hb_strings(openers)
        check_openers(openers)

        array = ::FFI::MemoryPointer.new(HbString, [openers.size, 1].max)

        strings = openers.each_with_index.map do |opener, index|
          data = ::FFI::MemoryPointer.from_string(opener)
          string = HbString.new(array[index])
          string[:data] = data
          string[:length] = opener.bytesize
          data
        end

        [array, *strings]
      end

      def check_openers(openers)
        raise TypeError, "wrong argument type #{openers.class} (expected Array)" unless openers.is_a?(Array)
        raise ArgumentError, "erb_openers accepts at most #{MAX_ERB_OPENERS} entries" if openers.size > MAX_ERB_OPENERS

        openers.each do |opener|
          raise TypeError, "wrong argument type #{opener.class} (expected String)" unless opener.is_a?(String)
          raise ArgumentError, "erb_openers entries must not be empty" if opener.empty?
        end
      end

      def read_hb_strings(pointer, count)
        Array.new(count) do |index|
          string = HbString.new(pointer + (index * HbString.size))
          string[:data].read_bytes(string[:length]).force_encoding(Encoding::UTF_8)
        end
      end
    end

    module Backend
      def parse(source, **options)
        data, parser_options, error_count = FFI.call(:herb_ffi_parse, source, options)

        Deserializer.new(data).parse_result(source, ParserOptions.new(**parser_options.to_options), error_count)
      end

      def lex(source, **options)
        data, = FFI.call(:herb_ffi_lex, source, options)

        Deserializer.new(data).lex_result(source)
      end

      def diff(old_source, new_source, **options)
        FFI.check_string(old_source)
        FFI.check_string(new_source)

        track_whitespace_changes = Options.fetch(options, :track_whitespace_changes) ? true : false

        data = FFI.read_buffer do |out, out_length|
          FFI.herb_ffi_diff(old_source, new_source, track_whitespace_changes, out, out_length)
        end

        Deserializer.new(data).diff_result
      end

      def extract_ruby(source, **options)
        FFI.check_string(source)

        extract_options = ExtractRubyOptions.new
        FFI.herb_ffi_extract_ruby_options_init(extract_options)

        [:semicolons, :comments, :preserve_positions, :custom_tags].each do |name|
          value = Options.fetch(options, name)
          extract_options[name] = value ? true : false unless value.nil?
        end

        openers = Options.fetch(options, :erb_openers)
        extract_options.erb_openers = openers unless openers.nil?

        FFI.read_and_free(FFI.herb_ffi_extract_ruby(source, extract_options))
      end

      def extract_html(source)
        FFI.read_and_free(FFI.herb_ffi_extract_html(FFI.check_string(source)))
      end

      def default_erb_openings
        count = ::FFI::MemoryPointer.new(:size_t)
        openings = FFI.herb_ffi_default_erb_openings(count)

        Options.read_hb_strings(openings, count.read(:size_t)).map(&:freeze)
      end

      def version
        "herb gem v#{Herb::VERSION}, libprism v#{FFI.herb_prism_version}, " \
          "libherb v#{FFI.herb_version} (Ruby FFI backend)"
      end

      # These rely on the C extension's arena and allocator hooks, so FFI can't offer them.
      def arena_stats(**)
        raise NotImplementedError, "Herb::Backend.arena_stats is not available in the FFI backend"
      end

      def leak_check(_source)
        raise NotImplementedError, "Herb::Backend.leak_check is not available in the FFI backend"
      end
    end
  end
end

require_relative "ffi/deserialize"

# Ruby defines the option struct layouts itself, so make sure they match the library we loaded.
if Herb::FFI::ParserOptionsStruct.size != Herb::FFI.herb_ffi_parser_options_size ||
   Herb::FFI::ExtractRubyOptions.size != Herb::FFI.herb_ffi_extract_ruby_options_size
  raise LoadError, "#{Herb::FFI::LIBRARY_NAME} does not match lib/herb/ffi, rebuild it with ffi/build.sh"
end

Herb::Backend.singleton_class.prepend(Herb::FFI::Backend)
