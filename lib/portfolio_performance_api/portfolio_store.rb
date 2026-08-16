# frozen_string_literal: true

require "stringio"
require "zip"

module PortfolioPerformanceApi
  class PortfolioStore
    Loaded = Struct.new(
      :path, :encrypted, :aes256, :password, :version, :content_type, :client, :zip_entries,
      keyword_init: true
    )

    def self.load(path, password:)
      raw = File.binread(path).b
      encrypted = Decryptor.encrypted?(raw)
      if encrypted
        payload = Decryptor.decrypt(raw, password)
        zip_bytes = payload.zip_bytes
        version = payload.version
        content_type = payload.content_type
        aes256 = raw.getbyte(Decryptor::SIGNATURE.bytesize) == 1
      elsif FileReader.zip?(raw)
        zip_bytes = raw
        version = 70
        content_type = 2
        aes256 = true
      else
        raise NotAPortfolioFile, "expected an encrypted or zipped .portfolio file"
      end

      if content_type == 1
        raise NotAPortfolioFile, "this importer only writes protobuf portfolios"
      end

      entries = zip_entries(zip_bytes)
      proto = entries["data.portfolio"] || entries.values.first
      raise NotAPortfolioFile, "missing data.portfolio in zip" if proto.nil?

      client = Proto::PClient.decode(FileReader.strip_proto_magic(proto))
      Loaded.new(
        path: path,
        encrypted: encrypted,
        aes256: aes256,
        password: password,
        version: version,
        content_type: 2,
        client: client,
        zip_entries: entries
      )
    end

    def self.save(loaded)
      proto = FileReader::PROTO_MAGIC + loaded.client.to_proto
      # Encrypted PP files store protobuf in zip entry "data" and, on open,
      # read only the first entry. Unencrypted zips use "data.portfolio".
      entry_name = loaded.encrypted ? "data" : "data.portfolio"
      zip_bytes = write_zip({ entry_name => proto })
      bytes = if loaded.encrypted
        Decryptor.encrypt(
          zip_bytes,
          loaded.password,
          aes256: loaded.aes256,
          content_type: 2,
          version: loaded.version
        )
      else
        zip_bytes
      end
      File.binwrite(loaded.path, bytes)
    end

    def self.backup_path(path, at: Time.now)
      directory = File.dirname(path)
      basename = File.basename(path, ".portfolio")
      File.join(directory, "#{basename}-#{at.strftime("%Y%m%dT%H%M%S")}.portfolio")
    end

    def self.zip_entries(zip_bytes)
      entries = {}
      Zip::File.open_buffer(StringIO.new(zip_bytes)) do |zip|
        zip.each do |entry|
          next if entry.directory?

          entries[File.basename(entry.name)] = entry.get_input_stream.read
        end
      end
      entries
    end

    def self.write_zip(entries)
      Zip::OutputStream.write_buffer do |zio|
        entries.each do |name, data|
          zio.put_next_entry(name)
          zio.write(data)
        end
      end.string
    end
    private_class_method :zip_entries, :write_zip
  end
end
