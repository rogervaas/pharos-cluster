# frozen_string_literal: true

module Pharos
  class WorkerUpCommand < Pharos::Command
    using Pharos::CoreExt::Colorize

    options :yes?

    parameter '[ADDRESS]', 'host address', default: "localhost" do |address|
      user, host = address.split('@', 2)
      if host.nil?
        user
      else
        @user = user
        host
      end
    end

    option %w(--ssh-key-path -i), '[PATH]', 'ssh key path'
    option %w(--ssh-port -p), '[PORT]', 'ssh port', default: 22
    option %w(--user -l), '[USER]', 'ssh login username'
    option '--insecure-registry', '[REGISTRY]', 'insecure registry (can be use multipled times)', multivalued: true
    option '--container-runtime', '[CONTAINER_RUNTIME]', 'container runtime', default: 'cri-o'
    option '--image-repository', '[IMAGE_REPOSITORY]', 'image repository', default: 'registry.pharos.sh/kontenapharos'
    option '--label', '[key=value]', 'node label (can be used multiple times)', multivalued: true do |label|
      signal_usage_error 'invalid --label format' unless label.include?('=')
      label
    end

    option '--token', 'JOIN_TOKEN', 'run "sudo kubeadm token create --print-join-command" on master node to get a join token', required: true
    option '--discovery-token-ca-cert-hash', 'CERT_HASH', 'see --token', required: true

    def default_user
      @user || ENV['USER']
    end

    def host_options
      {}.tap do |options|
        options[:address] = address
        options[:ssh_key_path] = ssh_key_path if ssh_key_path
        options[:ssh_port] = ssh_port
        options[:user] = user
        options[:role] = 'worker'
        options[:container_runtime] = container_runtime
        options[:labels] = label_list.map { |l| l.split('=') }.to_h
      end
    end

    def host
      @host ||= Pharos::Configuration::Host.new(host_options)
    end

    def config
      @config ||= Pharos::Config.new(
        hosts: [host],
        container_runtime: Pharos::Configuration::ContainerRuntime.new(insecure_registries: insecure_registry_list),
        image_repository: image_repository,
        network: Pharos::Configuration::Network.new
      )
    end

    def cluster_manager
      @cluster_manager ||= ClusterManager.new(config).tap do |manager|
        puts "==> Sharpening tools ...".green
        manager.context.merge!(
          'join-command' => "kubeadm join localhost:6443 --token #{token.inspect} --discovery-token-ca-cert-hash #{discovery_token_ca_cert_hash.inspect}"
        )
        manager.load
      end
    end

    def gather_facts
      cluster_manager.apply_phase(Phases::ConnectSSH, config.hosts.reject(&:local?))
      cluster_manager.apply_phase(Phases::GatherFacts, config.hosts)
      cluster_manager.apply_phase(Phases::ValidateHost, config.hosts)
    end

    def label_node
      host.labels.each do |key, value|
        host.transport.exec!("sudo kubectl --kubeconfig=/etc/kubernetes/kubelet.conf label nodes --overwrite=true #{host.hostname} #{"#{key}=#{value}".inspect}")
      end
    end

    def apply_phases
      cluster_manager.apply_phase(Phases::ConfigureHost, config.hosts)
      cluster_manager.apply_phase(Phases::MigrateWorker, config.worker_hosts)
      cluster_manager.apply_phase(Phases::ReconfigureKubelet, config.hosts)
      cluster_manager.apply_phase(Phases::JoinNode, config.hosts)
      label_node
    end

    def disconnect
      cluster_manager.disconnect
    end

    def execute
      start_time = Time.now

      cluster_manager.config.hosts.first.config = config

      gather_facts
      apply_phases
      disconnect

      craft_time = Time.now - start_time
      puts "==> Worker has been crafted! (took #{humanize_duration(craft_time.to_i)})".green
    end
  end
end

