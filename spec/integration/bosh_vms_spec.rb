require 'spec_helper'

describe 'vms list' do
  include IntegrationExampleGroup

  it 'should return vms in a deployment' do
    manifest_hash = Bosh::Spec::Deployments.simple_manifest
    manifest_hash['release']['version'] = 'latest'

    deployment_manifest = yaml_file('simple', manifest_hash)

    run_bosh("target http://localhost:#{current_sandbox.director_port}")
    run_bosh('login admin admin')

    run_bosh('create release', TEST_RELEASE_DIR)
    run_bosh('upload release', TEST_RELEASE_DIR)

    run_bosh("upload stemcell #{spec_asset('valid_stemcell.tgz')}")

    run_bosh("deployment #{deployment_manifest.path}")
    run_bosh('deploy')
    expect($?).to be_success
    vms = run_bosh('vms')

    expect(vms).to match /foobar\/0/
    expect(vms).to match /foobar\/1/
    expect(vms).to match /foobar\/2/
    expect(vms).to match /VMs total: 3/
  end
end