require 'spec_helper'
require 'fakefs/spec_helpers'

module VSphereCloud
  describe AgentEnv do
    include FakeFS::SpecHelpers

    subject(:agent_env) { described_class.new(client, file_provider) }

    let(:client) { instance_double('VSphereCloud::Client') }
    let(:file_provider) { double('VSphereCloud::FileProvider') }

    let(:location) do
      {
        datacenter: 'fake-datacenter-name 1',
        datastore: 'fake-datastore-name 1',
        vm: 'fake-vm-name',
      }
    end

    describe '#get_current_env' do
      let(:vm) { instance_double('VimSdk::Vim::Vm') }

      before do
        allow(client).to receive(:get_cdrom_device).with(vm).and_return(cdrom_device)
      end

      let(:cdrom_device) do
        instance_double(
          'VimSdk::Vim::Vm::Device::VirtualCdrom',
          backing: cdrom_backing
        )
      end

      before do
        allow(cdrom_device).to receive(:kind_of?).
          with(VimSdk::Vim::Vm::Device::VirtualCdrom).and_return(true)
      end

      let(:cdrom_backing) do
        instance_double('VimSdk::Vim::Vm::Device::VirtualCdrom::IsoBackingInfo',
          datastore: cdrom_datastore,
          file_name: '[fake-datastore-name 1] fake-vm-name/env.iso'
        )
      end

      let(:cdrom_datastore) { instance_double('VimSdk::Vim::Datastore', name: 'fake-datastore-name 1') }

      it 'gets current agent environment from fetched file' do
        expect(file_provider).to receive(:fetch_file).with(
          'fake-datacenter-name 1',
          'fake-datastore-name 1',
          'fake-vm-name/env.json',
        ).and_return('{"fake-response-json" : "some-value"}')

        expect(agent_env.get_current_env(vm, 'fake-datacenter-name 1')).to eq({'fake-response-json' => 'some-value'})
      end

      it 'raises if env.json is empty' do
        allow(file_provider).to receive(:fetch_file).with(
          'fake-datacenter-name 1',
          'fake-datastore-name 1',
          'fake-vm-name/env.json',
        ).and_return(nil)

        expect {
          agent_env.get_current_env(vm, 'fake-datacenter-name 1')
        }.to raise_error(Bosh::Clouds::CloudError)
      end
    end

    describe '#set_env' do
      let(:vm) { instance_double('VimSdk::Vim::VirtualMachine') }
      let(:config_spec) { instance_double('VimSdk::Vim::Vm::ConfigSpec') }
      before { allow(VimSdk::Vim::Vm::ConfigSpec).to receive(:new).and_return(config_spec) }

      let(:device_config_spec) { instance_double('VimSdk::Vim::Vm::Device::VirtualDeviceSpec') }
      before { allow(VimSdk::Vim::Vm::Device::VirtualDeviceSpec).to receive(:new).and_return(device_config_spec) }

      let(:env) { ['fake-json'] }

      let(:cdrom_connectable) { double(:connectable, connected: true) }
      let(:cdrom) do
        instance_double(
          'VimSdk::Vim::Vm::Device::VirtualCdrom',
          connectable: cdrom_connectable,
          backing: cdrom_backing
        )
      end

      let(:cdrom_backing) do
        instance_double('VimSdk::Vim::Vm::Device::VirtualCdrom::IsoBackingInfo',
          datastore: cdrom_datastore,
          file_name: '[fake-cdrom-datastore-name 1] fake-vm-name/env.iso'
        )
      end

      let(:cdrom_datastore) { instance_double('VimSdk::Vim::Datastore', name: 'fake-cdrom-datastore-name 1') }

      let(:datacenter) { instance_double('VimSdk::Vim::Datacenter') }
      before do
        allow(cdrom).to receive(:kind_of?).with(VimSdk::Vim::Vm::Device::VirtualCdrom).and_return(true)
        allow(client).to receive(:get_cdrom_device).with(vm).and_return(cdrom)
        allow(client).to receive(:find_parent).with(vm, VimSdk::Vim::Datacenter).and_return(datacenter)
      end

      def it_disconnects_cdrom
        expect(cdrom_connectable).to receive(:connected=).with(false) do
          allow(cdrom_connectable).to receive(:connected).and_return(false)
        end.ordered
        expect(device_config_spec).to receive(:device=).with(cdrom).ordered
        expect(device_config_spec).to receive(:operation=).with(VimSdk::Vim::Vm::Device::VirtualDeviceSpec::Operation::EDIT).ordered
        expect(config_spec).to receive(:device_change=).with([device_config_spec]).ordered
        expect(client).to receive(:reconfig_vm).with(vm, config_spec)
      end

      def it_cleans_up_old_env_files
        expect(client).to receive(:delete_path).with(datacenter, '[fake-cdrom-datastore-name 1] fake-vm-name/env.json')
        expect(client).to receive(:delete_path).with(datacenter, '[fake-cdrom-datastore-name 1] fake-vm-name/env.iso')
      end

      def it_uploads_environment_json(code = 204)
        expect(file_provider).to receive(:upload_file).with(
          'fake-datacenter-name 1',
          'fake-datastore-name 1',
          'fake-vm-name/env.json',
          '["fake-json"]'
        ).and_return(double(:response, code: code))
      end

      def it_generates_environment_iso(options = {})
        iso_generator = options.fetch(:iso_generator, 'genisoimage')
        exit_status = options.fetch(:exit_status, 0)

        allow(Dir).to receive(:mktmpdir) do |&blk|
          FileUtils.mkdir_p('/some/tmp/dir')
          blk.call('/some/tmp/dir')
        end

        expect(agent_env).to receive(:`).with("#{iso_generator} -o /some/tmp/dir/env.iso /some/tmp/dir/env 2>&1") do
          expect(File.read('/some/tmp/dir/env')).to eq('["fake-json"]')
          File.open('/some/tmp/dir/env.iso', 'w') { |f| f.write('iso contents') }
          allow($?).to receive(:exitstatus).and_return(exit_status)
        end
      end

      def it_uploads_environment_iso
        expect(file_provider).to receive(:upload_file).with(
          'fake-datacenter-name 1',
          'fake-datastore-name 1',
          'fake-vm-name/env.iso',
          'iso contents',
        ).and_return(double(:response, code: 204))
      end

      def it_connects_cdrom
        expect(cdrom_connectable).to receive(:connected=).with(true) do
          allow(cdrom_connectable).to receive(:connected).and_return(true)
        end
        expect(device_config_spec).to receive(:device=).with(cdrom).ordered
        expect(device_config_spec).to receive(:operation=).with(VimSdk::Vim::Vm::Device::VirtualDeviceSpec::Operation::EDIT).ordered
        expect(config_spec).to receive(:device_change=).with([device_config_spec]).ordered
        expect(client).to receive(:reconfig_vm).with(vm, config_spec)
      end

      it 'disconnects cdrom, cleans up old env files, uploads environment json, uploads environment iso and connectes cdrom' do
        it_disconnects_cdrom.ordered

        it_cleans_up_old_env_files.ordered

        it_uploads_environment_json.ordered

        it_generates_environment_iso.ordered

        it_uploads_environment_iso.ordered

        it_connects_cdrom.ordered

        agent_env.set_env(vm, location, env)
      end

      context 'when cdrom is disconnected' do
        before { allow(cdrom_connectable).to receive(:connected).and_return(false) }

        it 'does not disconnect cdrom' do
          it_cleans_up_old_env_files.ordered

          it_uploads_environment_json.ordered

          it_generates_environment_iso(iso_generator: 'genisoimage').ordered

          it_uploads_environment_iso.ordered

          it_connects_cdrom.ordered

          agent_env.set_env(vm, location, env)
        end
      end

      context 'when genisoimage is found' do
        before do
          stub_const('ENV', {'PATH' => '/bin'})
          allow(File).to receive(:exists?).and_call_original
          allow(File).to receive(:exists?).with('/bin/genisoimage').and_return(true)
        end

        it 'uses genisoimage' do
          it_disconnects_cdrom.ordered

          it_cleans_up_old_env_files.ordered

          it_uploads_environment_json.ordered

          it_generates_environment_iso(iso_generator: '/bin/genisoimage').ordered

          it_uploads_environment_iso.ordered

          it_connects_cdrom.ordered

          agent_env.set_env(vm, location, env)
        end
      end

      context 'when genisoimage is not found' do
        before do
          stub_const('ENV', {'PATH' => '/bin'})
          allow(File).to receive(:exists?).and_call_original
          allow(File).to receive(:exists?).with('/bin/mkisofs').and_return(true)
        end

        it 'uses mkisofs' do
          it_disconnects_cdrom.ordered

          it_cleans_up_old_env_files.ordered

          it_uploads_environment_json.ordered

          it_generates_environment_iso(iso_generator: '/bin/mkisofs').ordered

          it_uploads_environment_iso.ordered

          it_connects_cdrom.ordered

          agent_env.set_env(vm, location, env)
        end
      end

      context 'when uploading environment file fails' do
        before { it_uploads_environment_json(500) }

        it 'retries and raises an error' do
          it_disconnects_cdrom.ordered

          it_cleans_up_old_env_files.ordered

          expect {
            agent_env.set_env(vm, location, env)
          }.to raise_error
        end
      end

      context 'when generating iso image fails' do
        before { it_generates_environment_iso(exit_status: 1) }

        it 'raises an error' do
          it_disconnects_cdrom.ordered

          it_cleans_up_old_env_files.ordered

          it_uploads_environment_json.ordered

          expect {
            agent_env.set_env(vm, location, env)
          }.to raise_error
        end
      end
    end

    describe '#configure_env_cdrom' do
      let(:backing_info) { instance_double('VimSdk::Vim::Vm::Device::VirtualCdrom::IsoBackingInfo') }
      before { allow(VimSdk::Vim::Vm::Device::VirtualCdrom::IsoBackingInfo).to receive(:new).and_return(backing_info) }

      let(:connect_info) { instance_double('VimSdk::Vim::Vm::Device::VirtualDevice::ConnectInfo') }
      before { allow(VimSdk::Vim::Vm::Device::VirtualDevice::ConnectInfo).to receive(:new).and_return(connect_info) }

      let(:datastore) { instance_double('VSphereCloud::Resources::Datastore') }
      let(:device) { instance_double('VimSdk::Vim::Vm::Device::VirtualCdrom') }
      before { allow(device).to receive(:kind_of?).with(VimSdk::Vim::Vm::Device::VirtualCdrom).and_return(true) }

      it 'configures env cdrom' do
        expect(backing_info).to receive(:datastore=)
        expect(backing_info).to receive(:file_name=).with('fake-file-name')

        expect(connect_info).to receive(:allow_guest_control=).with(false)
        expect(connect_info).to receive(:start_connected=).with(true)
        expect(connect_info).to receive(:connected=).with(true)

        expect(device).to receive(:connectable=).with(connect_info)
        expect(device).to receive(:backing=).with(backing_info)

        agent_env.configure_env_cdrom(datastore, [device], 'fake-file-name')
      end
    end
  end
end
