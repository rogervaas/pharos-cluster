# frozen_string_literal: true

module Pharos
  module Configuration
    class Bastion < Pharos::Configuration::Struct
      include Comparable

      attr_writer :host

      attribute :address, Pharos::Types::Strict::String
      attribute :user, Pharos::Types::Strict::String
      attribute :ssh_key_path, Pharos::Types::Strict::String

      def ==(other)
        address == other.address && user == other.user && ssh_key_path == other.ssh_key_path
      end

      def host
        @host ||= Host.new(address: address, user: user, ssh_key_path: ssh_key_path)
      end
    end
  end
end
