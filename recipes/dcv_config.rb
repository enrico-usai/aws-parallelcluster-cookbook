#
# Cookbook Name:: aws-parallelcluster
# Recipe:: dcv_config
#
# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file.
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
# See the License for the specific language governing permissions and limitations under the License.

# This recipe install the prerequisites required to use NICE DCV on a Linux server
# Source: https://docs.aws.amazon.com/en_us/dcv/latest/adminguide/setting-up-installing-linux-prereq.html

# TODO Detect if the instance is a GPU instance.
def is_graphic_instance
  instance_type = get_instance_type
  is_graphic_instance = true if instance_type.start_with?('g2')

  false
end


# Configure the system to enable NICE DCV to have direct access to the Linux server's GPU and enable GPU sharing.
def allow_gpu_acceleration
  package "xorg-x11-server-Xorg"

  # Udate the xorg.conf to set up NVIDIA drivers.
  # NOTE: --enable-all-gpus parameter is needed to support servers with more than one NVIDIA GPU.
  execute "set up Nvidia drivers for X configuration" do
    user 'root'
    command "nvidia-xconfig --preserve-busid --enable-all-gpus"
  end

  # dcvgl package must be installed after NVIDIA and before starting up X
  dcv_gl = "#{Chef::Config[:file_cache_path]}/nice-dcv-#{node['cfncluster']['dcv']['version']}-el7/#{node['cfncluster']['dcv']['gl']}"
  package dcv_gl do
    action :install
    source dcv_gl
  end

  # Configure the X server to start automatically when the Linux server boots and start the X server in background
  bash 'launch X' do
    user 'root'
    code <<-SETUPX
      systemctl set-default graphical.target
      systemctl isolate graphical.target &
    SETUPX
  end

  # Verify that the X server is running
  execute 'wait for X to start' do
    user 'root'
    command "pidof X"
    retries 5
    retry_delay 5
  end
end


if node['platform'] == 'centos' && node['platform_version'].to_i == 7 && node['cfncluster']['cfn_node_type'] == "MasterServer"
  node.default['cfncluster']['dcv']['is_graphic_instance'] = is_graphic_instance

  if node.default['cfncluster']['dcv']['is_graphic_instance']
    # Enable graphic acceleration in dcv conf file for graphic instances.
    allow_gpu_acceleration
  end

  # Install utility file to generate HTTPs certificates for the DCV external authenticator and generate a new one
  cookbook_file "/etc/parallelcluster/generate_certificate.sh" do
    source 'ext_auth_files/generate_certificate.sh'
    owner 'root'
    mode '0700'
  end
  execute "certificate generation" do
    command "/etc/parallelcluster/generate_certificate.sh \"#{node['cfncluster']['dcv']['ext_auth_certificate']}\" #{node['cfncluster']['dcv']['ext_auth_user']} dcv"
    user 'root'
  end

  # Generate dcv.conf starting from template
  template "/etc/dcv/dcv.conf" do
    action :create
    source 'dcv.conf.erb'
    owner 'root'
    group 'root'
    mode '0755'
  end

  # Create directory for the external authenticator to
  directory '/var/spool/dcv_ext_auth' do
    owner node['cfncluster']['dcv']['ext_auth_user']
    mode '1733'
    recursive true
  end

  # Create ParallelCluster log folder
  directory '/var/log/parallelcluster/' do
    owner 'root'
    mode '1777'
    recursive true
  end

  # Install DCV external authenticator
  cookbook_file "#{node['cfncluster']['dcv']['ext_auth_user_home']}/pcluster_dcv_ext_auth.py" do
    source 'ext_auth_files/pcluster_dcv_ext_auth.py'
    owner node['cfncluster']['dcv']['ext_auth_user']
    mode '0700'
  end

  # Start NICE DCV server
  service "dcvserver" do
    action [:start, :enable]
  end
end