# frozen_string_literal: true

require 'net/ssh'
require 'net/ssh/gateway'
require 'shellwords'
require 'monitor'

module Pharos
  module SSH
    Error = Class.new(StandardError)
    NotConnected = Class.new(Error)

    EXPORT_ENVS = {
      http_proxy: '$http_proxy',
      HTTP_PROXY: '$HTTP_PROXY',
      HTTPS_PROXY: '$HTTPS_PROXY',
      NO_PROXY: '$NO_PROXY',
      FTP_PROXY: '$FTP_PROXY',
      PATH: '$PATH'
    }.freeze

    class Client
      include MonitorMixin

      CONNECTION_RETRY_ERRORS = [
        Errno::ECONNABORTED,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        IOError,
        Net::SSH::ConnectionTimeout,
        Net::SSH::Disconnect,
        Net::SSH::Exception
      ].freeze

      attr_reader :session, :host

      # @param host [String]
      # @param user [String, NilClass]
      # @param opts [Hash]
      def initialize(host, user = nil, opts = {})
        super()
        @host = host
        @user = user
        @opts = opts
      end

      def logger
        @logger ||= Logger.new($stderr).tap do |logger|
          logger.progname = "SSH[#{@host}]"
          logger.level = ENV["DEBUG_SSH"] ? Logger::DEBUG : Logger::INFO
        end
      end

      # @return [Hash,NilClass]
      def bastion
        @bastion ||= @opts.delete(:bastion)
      end

      # @param options [Hash] see Net::SSH#start
      def connect(**options)
        synchronize do
          Pharos::Retry.perform(10, exceptions: CONNECTION_RETRY_ERRORS) do
            logger.debug { "connect: #{@user}@#{@host} (#{@opts})" }
            if bastion
              @session = bastion.host.ssh.gateway.ssh(@host, @user, @opts.merge(options))
            else
              @session = Net::SSH.start(@host, @user, @opts.merge(options))
            end
          end
        end
      end

      # @return [Net::SSH::Gateway]
      def gateway
        @gateway ||= Net::SSH::Gateway.new(@host, @user, @opts).tap do |gw|
          gw.instance_exec do
            @thread.report_on_exception = false
          end
        end
      end

      # @example
      #   tempfile do |tmp|
      #     exec!("less #{tmp}")
      #   end
      # @example
      #   tmp = tempfile.new(content: "hello")
      #   exec!("cat #{tmp}")
      #   tmp.unlink
      #
      # @param prefix [String] tempfile filename prefix (default "pharos")
      # @param content [String,IO] initial file content, default blank
      # @return [Pharos::SSH::Tempfile]
      # @yield [Pharos::SSH::Tempfile]
      def tempfile(prefix: "pharos", content: nil, &block)
        synchronize { Tempfile.new(self, prefix: prefix, content: content, &block) }
      end

      # @param cmd [String] command to execute
      # @param options [Hash]
      # @return [Pharos::Command::Result]
      def exec(cmd, **options)
        require_session!
        synchronize { RemoteCommand.new(self, cmd, **options).run }
      end

      # @param cmd [String] command to execute
      # @param options [Hash]
      # @raise [Pharos::SSH::RemoteCommand::ExecError]
      # @return [String] stdout
      def exec!(cmd, **options)
        require_session!
        synchronize { RemoteCommand.new(self, cmd, **options).run!.stdout }
      end

      # @param name [String] name of script
      # @param env [Hash] environment variables hash
      # @param path [String] real path to file, defaults to script
      # @raise [Pharos::SSH::RemoteCommand::ExecError]
      # @return [String] stdout
      def exec_script!(name, env: {}, path: nil, **options)
        script = File.read(path || name)
        cmd = %w(sudo env -i -)

        cmd.concat(EXPORT_ENVS.merge(env).map { |key, value| "#{key}=\"#{value}\"" })
        cmd.concat(%w(bash --norc --noprofile -x -s))
        logger.debug { "exec: #{cmd}" }
        exec!(cmd, stdin: script, source: name, **options)
      end

      # @param cmd [String] command to execute
      # @param options [Hash]
      # @return [Boolean]
      def exec?(cmd, **options)
        exec(cmd, **options).success?
      end

      # @param path [String]
      # @return [Pharos::SSH::RemoteFile]
      def file(path)
        Pharos::SSH::RemoteFile.new(self, path)
      end

      def interactive_session
        synchronize { Pharos::SSH::InteractiveSession.new(self).run }
      end

      def connected?
        synchronize { !session.nil? && !session.closed? }
      end

      def gateway_shutdown
        synchronize do
          return unless @gateway
          @gateway.shutdown!
          sleep 0.1 until !@gateway.active?
          @gateway = nil
        end
      end

      def disconnect
        synchronize do
          session.close if session && !session.closed?
          bastion.host.ssh.gateway_shutdown if bastion
          gateway_shutdown
          @session = nil
        end
      end

      private

      def require_session!
        connect(timeout: 3) unless connected?
      rescue *CONNECTION_RETRY_ERRORS => ex
        raise NotConnected, "Connection not established (#{ex.class.name} : #{ex.message})" unless connected?
      end
    end
  end
end
