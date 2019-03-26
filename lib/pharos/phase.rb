# frozen_string_literal: true

require 'logger'

module Pharos
  class Phase
    using Pharos::CoreExt::Colorize

    RESOURCE_PATH = Pathname.new(File.expand_path(File.join(__dir__, 'resources'))).freeze

    # @return [String]
    def self.title(title = nil)
      @title = title if title
      @title || name
    end

    # Define which hosts to run on, :master_host is equivalent to @config.master_host.
    #
    # @example phase runs on the primary master host
    #   on :master_host
    # @example phase runs on all the master hosts
    #   on :master_hosts
    # @example phase runs on all hosts
    #   on :hosts
    # @example phase runs on all hosts
    #   on :hosts # it is the default and can be omitted
    # @param [*Symbol]
    # @return [Array<Symbol,Proc>]
    def self.on(*hosts)
      return @on if @on
      return [:hosts] if hosts.empty?
      @on = hosts.flatten.compact
    end

    # @param config [Pharos::Config]
    # @return [Array<Pharos::Phase>]
    def self.hosts_for(config)
      on.map do |getter|
        config.send(getter)
      end.flatten.compact
    end

    def to_s
      "#{self.class.title} @ #{@host}"
    end

    def self.register_component(component)
      Pharos::Phases.register_component(component)
    end

    attr_reader :cluster_context, :host

    # @param host [Pharos::Configuration::Host]
    # @param config [Pharos::Config]
    def initialize(host, config: nil, cluster_context: nil)
      @host = host
      @config = config
      @cluster_context = cluster_context
    end

    def transport
      @host.transport
    end

    FORMATTER_COLOR = proc do |severity, _datetime, hostname, msg|
      message = msg.is_a?(Exception) ? Pharos::Logging.format_exception(msg, severity) : msg

      color = case severity
              when "DEBUG" then :dim
              when "INFO" then :to_s
              when "WARN" then :yellow
              else :red
              end

      message.gsub(/^/m) { "    [#{hostname.send(color)}] " } + "\n"
    end

    FORMATTER_NO_COLOR = proc do |severity, _datetime, hostname, msg|
      message = msg.is_a?(Exception) ? Pharos::Logging.format_exception(msg, severity) : msg

      if severity == "INFO"
        message.gsub(/^/m) { "    [#{hostname}] " } + "\n"
      else
        message.gsub(/^/m) { "    [#{hostname}] [#{severity}] " } + "\n"
      end
    end

    def logger
      @logger ||= Logger.new($stdout).tap do |logger|
        logger.progname = @host.to_s
        logger.level = Pharos::Logging.log_level
        logger.formatter = Pharos::CoreExt::Colorize.enabled? ? FORMATTER_COLOR : FORMATTER_NO_COLOR
      end
    end

    # @return [String]
    def script_path(*path)
      File.join(__dir__, 'scripts', *path)
    end

    # @return [String]
    def resource_path(*path)
      File.join(__dir__, 'resources', *path)
    end

    # @param script [String] name of file under ../scripts/
    # @param vars [Hash]
    def exec_script(script, vars = {})
      transport.exec_script!(
        script,
        env: vars,
        path: script_path(script)
      )
    end

    # @param path [String]
    # @param vars [Hash]
    # @return [Pharos::YamlFile]
    def parse_resource_file(path, vars = {})
      Pharos::YamlFile.new(resource_path(path)).read(vars)
    end

    # @return [Pharos::Host::Configurer]
    def host_configurer
      @host_configurer ||= @host.configurer
    end

    # @return [Pharos::Configuration::Host]
    def master_host
      @config.master_host
    end

    # @return [K8s::Client]
    def kube_client
      fail "Phase #{self.class.name} does not have kubeconfig cluster_context" unless cluster_context['kubeconfig']

      @config.kube_client(cluster_context['kubeconfig'])
    end

    # @param name [String]
    # @param vars [Hash]
    def kube_stack(name, **vars)
      Pharos::Kube.stack(name, File.join(RESOURCE_PATH, name), name: name, **vars)
    end

    # @param name [String]
    # @param vars [Hash]
    def apply_stack(name, **vars)
      kube_stack(name, **vars).apply(kube_client)
    end

    # @param name [String]
    # @return [Array<K8s::Resource>]
    def delete_stack(name)
      Pharos::Kube::Stack.new(name).delete(kube_client)
    end

    def mutex
      self.class.mutex
    end

    def self.mutex
      @mutex ||= Mutex.new
    end
  end
end
