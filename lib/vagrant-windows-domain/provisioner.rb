require "log4r"
require 'erb'

module VagrantPlugins
  module WindowsDomain
    # DSC Errors namespace, including setup of locale-based error messages.
    class WindowsDomainError < Vagrant::Errors::VagrantError
      error_namespace("vagrant_windows_domain.errors")
      I18n.load_path << File.expand_path("locales/en.yml", File.dirname(__FILE__))
    end
    class DSCUnsupportedOperation < WindowsDomainError
      error_key(:unsupported_operation)
    end    

    # Windows Domain Provisioner Plugin.
    #
    # Connects and Removes a guest Machine from a Windows Domain.
    class Provisioner < Vagrant.plugin("2", :provisioner)

      # Default path for storing the transient script runner
      WINDOWS_DOMAIN_GUEST_RUNNER_PATH = "c:/tmp/vagrant-windows-domain-runner.ps1"

      # Constructs the Provisioner Plugin.
      #
      # @param [Machine] machine The guest machine that is to be provisioned.
      # @param [Config] config The Configuration object used by the Provisioner.
      # @returns Provisioner
      def initialize(machine, config)
        super

        @logger = Log4r::Logger.new("vagrant::provisioners::vagrant_windows_domain")
      end

      # Configures the Provisioner.
      #
      # @param [Config] root_config The default configuration from the Vagrant hierarchy.
      def configure(root_config)
        raise WindowsDomainError, :unsupported_platform if !windows?

        verify_guest_capability
      end

      # Run the Provisioner!
      def provision
        @machine.env.ui.say(:info, "Connecting guest machine to domain '#{config.domain}' with computer name '#{config.computer_name}'")

        set_credentials

        join_domain

        restart_guest
      end

      # Join the guest machine to a Windows Domain.
      #
      # Generates, writes and runs a script to join a domain.
      def join_domain        
        run_remote_command_runner(write_command_runner_script(generate_command_runner_script(true)))
      end

      # Removes the guest machine from a Windows Domain.
      #
      # Generates, writes and runs a script to leave a domain.
      def leave_domain
        run_remote_command_runner(write_command_runner_script(generate_command_runner_script(false)))
      end
      alias_method :unjoin_domain, :leave_domain

      # Get username/password from user if not provided
      # as part of the Config object
      def set_credentials
        if (config.username == nil)
          @logger.info("==> Requesting username as none provided")
          config.username = @machine.env.ui.ask("Please enter your domain username: ")
        end

        if (config.password == nil)
          @logger.info("==> Requesting password as none provided")
          config.password = @machine.env.ui.ask("Please enter your domain password (output will be hidden): ", {:echo => false})
        end
      end

      # Cleanup after a destroy action.
      #
      # This is the method called when destroying a machine that allows
      # for any state related to the machine created by the provisioner
      # to be cleaned up.
      def cleanup        
        set_credentials
        leave_domain

      end

      # Restarts the Computer and waits
      def restart_guest
        @machine.env.ui.say(:info, "Restarting computer for updates to take effect.")
        options = {}
        options[:provision_ignore_sentinel] = false
        @machine.action(:reload, options)
        begin
          sleep 10
        end until @machine.communicate.ready?
      end

      # Verify that we can call the remote operations.
      # Required to add the computer to a Domain.
      def verify_guest_capability
        verify_binary("Add-Computer")
        verify_binary("Remove-Computer")
      end

      # Verify a binary\command is executable on the guest machine.
      def verify_binary(binary)
        @machine.communicate.sudo(
          "which #{binary}",
          error_class: WindowsDomainError,
          error_key: :binary_not_detected,
          domain: config.domain,
          binary: binary)
      end

      # Generates a PowerShell runner script from an ERB template
      #
      # @param [boolean] add_to_domain Whether or not to add or remove the computer to the domain (default: true).
      # @return [String] The interpolated PowerShell script.
      def generate_command_runner_script(add_to_domain=true)
        path = File.expand_path("../templates/runner.ps1", __FILE__)

        script = Vagrant::Util::TemplateRenderer.render(path, options: {
            config: @config,
            username: @config.username,
            password: @config.password,
            domain: @config.domain,
            add_to_domain: add_to_domain
            # parameters: @config.join_options.map { |k,v| "#{k}" + (!v.nil? ? " \"#{v}\"": '') }.join(" ")
        })
      end

      # Writes the PowerShell runner script to a location on the guest.
      #
      # @param [String] script The PowerShell runner script.
      # @return [String] the Path to the uploaded location on the guest machine.
      def write_command_runner_script(script)
        guest_script_path = WINDOWS_DOMAIN_GUEST_RUNNER_PATH
        file = Tempfile.new(["vagrant-windows-domain-runner", "ps1"])
        begin
          file.write(script)
          file.fsync
          file.close
          @machine.communicate.upload(file.path, guest_script_path)
        ensure
          file.close
          file.unlink
        end
        guest_script_path
      end

      # Runs the PowerShell script on the guest machine.
      def run_remote_command_runner(script_path)
        command = ". '#{script_path}'"

        @machine.ui.info(I18n.t(
          "vagrant_windows_domain.running"))

        opts = {
          elevated: true,
          error_key: :ssh_bad_exit_status_muted,
          good_exit: 0,
          shell: :powershell
        }

        @machine.communicate.sudo(command, opts) do |type, data|
          if !data.chomp.empty?
            if [:stderr, :stdout].include?(type)
              color = type == :stdout ? :green : :red
              @machine.ui.info(
                data.chomp,
                color: color, new_line: false, prefix: false)
            end
          end
        end
      end

      # If on using WinRM, we can assume we are on Windows
      def windows?
        @machine.config.vm.communicator == :winrm
      end

    end
  end
end