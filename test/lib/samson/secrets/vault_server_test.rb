# frozen_string_literal: true
require_relative '../../../test_helper'

SingleCov.covered!

describe Samson::Secrets::VaultServer do
  def create_server(i)
    Samson::Secrets::VaultServer.any_instance.stubs(:validate_connection)
    Samson::Secrets::VaultServer.create!(name: "pod#{i}", address: 'http://vault-land.com', token: 'TOKEN2')
  end

  describe "validations" do
    let(:server) { Samson::Secrets::VaultServer.new(name: 'abc', address: 'http://vault-land.com', token: "TOKEN") }

    before do
      stub_request(:get, "http://vault-land.com/v1/secret/apps/?list=true").
        to_return(headers: {content_type: 'application/json'}, body: {data: {keys: ['abc']}}.to_json)
    end

    it "is valid" do
      assert_valid server
    end

    it "is invalid with only hostname" do
      server.address = server.address.sub('http://', '')
      refute_valid server
    end

    it "is valid with a valid cert" do
      server.ca_cert = File.read("#{fixture_path}/self-signed-test-cert.pem")
      assert_valid server
    end

    it "is invalid with an invalid cert" do
      server.ca_cert = "nope"
      refute_valid server
      server.errors.full_messages.must_equal ["Ca cert is invalid: not enough data"]
    end

    it "is invalid with duplicate name" do
      server.save!
      refute_valid server.dup
    end

    it "is invalid when it cannot connect to vault" do
      stub_request(:get, "http://vault-land.com/v1/secret/apps/?list=true").to_timeout
      refute_valid server
    end

    it "is invalid when vault connection fails" do
      stub_request(:get, "http://vault-land.com/v1/secret/apps/?list=true").
        to_raise(Vault::HTTPError.new("address", stub(code: '200')))
      refute_valid server
    end
  end

  describe "#sync!" do
    let(:from) { create_server(0) }
    let(:to) { create_server(1) }
    let(:scoped_key) { "secret/apps/staging/foo/pod100/a" }

    before { to.deploy_groups = [deploy_groups(:pod100)] }

    it "copies global keys" do
      key = "secret/apps/global/global/global/a"
      from.client.logical.expects(:list_recursive).returns([key])
      from.client.logical.expects(:read).with(key).returns("value")
      to.client.logical.expects(:write).with(key, "value")
      to.sync!(from)
    end

    it "copies keys that this server has access to" do
      key = scoped_key
      from.client.logical.expects(:list_recursive).returns([key])
      from.client.logical.expects(:read).with(key).returns("value")
      to.client.logical.expects(:write).with(key, "value")
      to.sync!(from)
    end

    it "does not copy keys that should not be kept in this vault by environment" do
      deploy_groups(:pod100).environment.update_column(:permalink, 'nope')
      from.client.logical.expects(:list_recursive).returns([scoped_key])
      from.client.logical.expects(:read).never
      to.client.logical.expects(:write).never
      to.sync!(from)
    end

    it "does not copy keys that should not be kept in this vault by deploy group" do
      deploy_groups(:pod100).update_column(:permalink, 'nope')
      from.client.logical.expects(:list_recursive).returns([scoped_key])
      from.client.logical.expects(:read).never
      to.client.logical.expects(:write).never
      to.sync!(from)
    end
  end

  # testing our added method
  describe "#list_recursive" do
    it "iterates through all keys" do
      stub_request(:get, "http://vault-land.com/v1/secret/apps/?list=true").
        to_return(headers: {content_type: 'application/json'}, body: {data: {keys: ['abc/'.dup, 'def'.dup]}}.to_json)
      stub_request(:get, "http://vault-land.com/v1/secret/apps/abc/?list=true").
        to_return(headers: {content_type: 'application/json'}, body: {data: {keys: ['ghi'.dup]}}.to_json)

      server = create_server(0)
      Samson::Secrets::VaultServer.any_instance.unstub(:validate_connection)
      server.client.logical.list_recursive("secret/apps/").must_equal ["abc/ghi", "def"]
    end
  end
end