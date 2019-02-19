# frozen_string_literal: true

module Pharos
  class RebootCommand < Pharos::Command
    options :filtered_hosts, :yes?

    def execute
      Dir.chdir(config_yaml.dirname) do
        filtered_hosts.size == load_config.hosts.size ? reboot_all : reboot_hosts
      end
    end

    def reboot_all
      confirm_yes!(pastel.bright_yellow("==> Do you really want to reboot all of the hosts in the cluster?"), default: false)
      reboot_hosts
    end

    def reboot_hosts
      start_time = Time.now

      master_hosts = filtered_hosts.select(&:master?).reject(&:local?)
      worker_hosts = filtered_hosts.select(&:worker?).reject(&:local?)
      local_hosts  = filtered_hosts.select(&:local?)

      puts pastel.green("==> Sharpening tools ...")
      cluster_manager.gather_facts

      unless local_hosts.empty?
        puts "  " + pastel.red("!" * 76)
        puts pastel.red("    The host will remain cordoned (workloads will not be scheduled on it) after the reboot")
        puts pastel.red("    To uncordon, you must use: ") + pastel.cyan("pharos exec -c #{config_yaml.filename} -r master -f -- kubectl uncordon #{local_hosts.first}")
        puts "  " + pastel.red("!" * 76)
        confirm_yes!(pastel.bright_yellow("Host #{local_hosts.first} is localhost. It will remain cordoned after reboot. Are you sure?"), default: false)
      end

      unless master_hosts.empty?
        puts pastel.green("==> Rebooting #{master_hosts.size} master node#{'s' if master_hosts.size > 1} ...")
        cluster_manager.apply_reboot_hosts(master_hosts, parallel: false)
      end

      unless worker_hosts.empty?
        puts pastel.green("==> Rebooting #{worker_hosts.size} worker node#{'s' if worker_hosts.size > 1} ...")
        cluster_manager.apply_reboot_hosts(worker_hosts, parallel: true)
      end

      unless local_hosts.empty?
        puts pastel.green("==> Rebooting localhost")

        cluster_manager.apply_reboot_hosts(local_hosts, parallel: false)
      end

      reboot_time = Time.now - start_time
      puts pastel.green("==> Rebooted #{filtered_hosts.size} node#{'s' if filtered_hosts.size > 1}! (took #{humanize_duration(reboot_time.to_i)})")
    end

    def cluster_manager
      @cluster_manager ||= ClusterManager.new(load_config, pastel: pastel).tap(&:load)
    end
  end
end
