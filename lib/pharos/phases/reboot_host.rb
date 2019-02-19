# frozen_string_literal: true

module Pharos
  module Phases
    class RebootHost < Pharos::Phase
      title "Reboot hosts"

      EXPECTED_ERRORS = Pharos::Transport::SSH::RETRY_CONNECTION_ERRORS + [
        Pharos::ExecError
      ].freeze

      def call
        if host.local?
          reboot
          reconnect
          uncordon
        else
          host.transport.exec!("sudo shutdown -r now")
        end
      end

      def reboot
        logger.debug { "Sending the reboot command .." }
        seconds = exec_script('reboot-asap.sh').strip.to_i
        ssh.disconnect
        logger.info "Scheduled a reboot to happen in #{seconds} second#{'s' if seconds > 1}, waiting for reboot .."
        sleep seconds
        logger.debug { "Allowing the host some time to start the shutdown process .." }
        sleep 20
      end

      def reconnect
        logger.info "Reconnecting and waiting for kubelet to start .."
        Pharos::Retry.perform(exceptions: EXPECTED_ERRORS) do
          ssh.connect unless ssh.connected?
          ssh.exec!('systemctl is-active kubelet')
        end
        logger.debug { "Connected" }
      end

      def uncordon
        logger.info "Uncordoning .."
        sleep 0.5 until master_ssh.exec?("kubectl uncordon #{host.hostname} | grep -q 'already uncordoned'")
      end
    end
  end
end
