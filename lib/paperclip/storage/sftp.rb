module Paperclip
  module Storage
    # You can also store attachments at a remote server over SFTP. The additional options are similar to the S3 ones:
    # * +sftp_credentials+: Takes a path, a File, or a Hash. The path (or File) must point
    #   to a YAML file containing the +host+, +user+ and +password+ for your sftp connection.
    #   Your YAML file could look like this:
    #     development:
    #       host: test.foo.com
    #       user: peter
    #       password: fa21tsd13
    #
    #     production:
    #       host: foo.com
    #       user: bar
    #       password: lga3fo1
    # * +path+: The location where the attachments are saved at the SFTP server. For example:
    #     :path => "/var/app/attachments/:class/:id/:style/:basename.:extension"
    # * +url+: The url paperclip uses to access the attachment. For available parameters see :path.

    module Sftp
      def self.extended(base)
        begin
          require 'net/ssh'
          require 'net/sftp'
        rescue LoadError => e
          e.message << " (You may need to install the net-ssh and net-sftp gem)"
          raise e
        end

        base.instance_eval do
          @sftp_credentials = parse_credentials(@options[:sftp_credentials])
        end
      end

      def ssh
        @ssh_connection ||= Net::SSH.start(@sftp_credentials[:host], @sftp_credentials[:user], :password => @sftp_credentials[:password])
      end

      def exists?(style = default_style)
        ssh.exec!("ls #{path(style)} 2>/dev/null") ? true : false
      end

      def to_file(style=default_style)
        @queued_for_write[style] || (ssh.sftp.file.open(path(style), 'rb') if exists?(style))
      end
      alias_method :to_io, :to_file

      def flush_writes #:nodoc:
        log("[paperclip] Writing files for #{name}")
        @queued_for_write.each do |style, file|
          file.close
          ssh.exec! "mkdir -m 711 -p #{File.dirname(path(style))}"
          log("[paperclip] -> #{path(style)}")
          ssh.sftp.upload!(file.path, path(style))
          ssh.sftp.setstat!(path(style), :permissions => 0644)
        end
        @queued_for_write = {}
      end

      def flush_deletes #:nodoc:
        log("[paperclip] Deleting files for #{name}")
        @queued_for_delete.each do |path|
          begin
            log("[paperclip] -> #{path}")
            ssh.sftp.remove!(path)
          rescue Net::SFTP::StatusException
            # ignore file-not-found, let everything else pass
          end
          begin
            while(true)
              path = File.dirname(path)
              ssh.sftp.rmdir!(path)
            end
          rescue Net::SFTP::StatusException
            # Stop trying to remove parent directories
          end
        end
        @queued_for_delete = []
      end

      def parse_credentials creds
        creds = find_credentials(creds).stringify_keys
        (creds[Rails.env] || creds).symbolize_keys
      end

      def find_credentials creds
        case creds
        when File
          YAML::load(ERB.new(File.read(creds.path)).result)
        when String
          YAML::load(ERB.new(File.read(creds)).result)
        when Hash
          creds
        else
          raise ArgumentError, "Credentials are not a path, file, or hash."
        end
      end
      private :find_credentials

    end
