# frozen_string_literal: true

module Pharos
  module Phases
    class ConfigureClient < Pharos::Phase
      title "Configure kube client"

      REMOTE_FILE = "/etc/kubernetes/admin.conf"

      # @param optional [Boolean] skip if kubeconfig does not exist instead of failing
      def initialize(host, optional: false, **options)
        super(host, **options)

        @optional = optional
      end

      def call
        return if @optional && !kubeconfig?

        transport.close(cluster_context['kube_client'].transport.server[/:(\d+)/, 1].to_i) if cluster_context['kube_client']
        cluster_context['kube_client'] = Pharos::Kube.client('localhost', k8s_config, transport.forward(host.api_address, 6443))

        client_prefetch unless @optional
      end

      def kubeconfig
        @kubeconfig ||= transport.file(REMOTE_FILE)
      end

      # @return [String]
      def kubeconfig?
        kubeconfig.exist?
      end

      # @return [K8s::Config]
      def k8s_config
        logger.info { "Fetching kubectl config ..." }
        config = YAML.safe_load(kubeconfig.read)

        logger.debug { "New config: #{config}" }
        K8s::Config.new(config)
      end

      # prefetch client resources to warm up caches
      def client_prefetch
        kube_client.apis(prefetch_resources: true)
      end
    end
  end
end
