# frozen_string_literal: true

require "stringio"
require "zip"

module PortfolioPerformanceApi
  class FileReader
    PROTO_MAGIC = "PPPBV1"
    XML_ENTRY = "data.xml"
    PROTO_ENTRY = "data.portfolio"

    Result = Struct.new(:format, :bytes, :version, keyword_init: true)

    def self.read(bytes, password: nil)
      bytes = bytes.b
      if Decryptor.encrypted?(bytes)
        payload = Decryptor.decrypt(bytes, password)
        inner = unzip(payload.zip_bytes, prefer: payload.content_type == 2 ? :protobuf : :xml)
        Result.new(format: inner.fetch(:format), bytes: inner.fetch(:bytes), version: payload.version)
      elsif zip?(bytes)
        inner = unzip(bytes)
        Result.new(format: inner.fetch(:format), bytes: inner.fetch(:bytes), version: nil)
      elsif xml?(bytes)
        Result.new(format: :xml, bytes: bytes, version: nil)
      else
        raise NotAPortfolioFile, "unrecognized portfolio file format"
      end
    end

    def self.zip?(bytes)
      bytes.start_with?("PK\x03\x04".b)
    end

    def self.xml?(bytes)
      sample = bytes.byteslice(0, 64).to_s.force_encoding(Encoding::UTF_8)
      sample.sub!("\uFEFF", "")
      sample.lstrip.start_with?("<")
    rescue Encoding::CompatibilityError
      false
    end

    def self.unzip(zip_bytes, prefer: nil)
      entries = {}
      Zip::File.open_buffer(StringIO.new(zip_bytes)) do |zip|
        zip.each do |entry|
          next if entry.directory?

          entries[File.basename(entry.name)] = entry.get_input_stream.read
        end
      end

      if prefer == :protobuf || entries.key?(PROTO_ENTRY)
        data = entries[PROTO_ENTRY] || first_bytes(entries)
        return { format: :protobuf, bytes: strip_proto_magic(data) }
      end

      if prefer == :xml || entries.key?(XML_ENTRY)
        return { format: :xml, bytes: entries[XML_ENTRY] || first_bytes(entries) }
      end

      data = first_bytes(entries)
      if data.start_with?(PROTO_MAGIC) || (!xml?(data) && !data.lstrip.start_with?("<"))
        { format: :protobuf, bytes: strip_proto_magic(data) }
      else
        { format: :xml, bytes: data }
      end
    end

    def self.strip_proto_magic(data)
      data.start_with?(PROTO_MAGIC) ? data.byteslice(PROTO_MAGIC.bytesize..) : data
    end

    def self.first_bytes(entries)
      raise NotAPortfolioFile, "empty zip container" if entries.empty?

      entries.fetch("data") { entries.values.first }
    end
    private_class_method :first_bytes
  end
end
