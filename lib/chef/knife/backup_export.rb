#
# Author:: Marius Ducea (<marius.ducea@gmail.com>)
# Author:: Steven Danna (steve@opscode.com)
# Author:: Joshua Timberman (<joshua@opscode.com>)
# Author:: Adam Jacob (<adam@opscode.com>)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/node'
require 'chef/api_client'
require 'chef/policy_builder'
require 'chef/cookbook/synchronizer'
require 'chef-dk/policyfile/lister'
require 'chef-dk/policyfile_services/show_policy'
require 'chef-dk/ui'

if Chef::VERSION =~ /^1[1-9]\./
  require 'chef/user'
end
require 'chef/knife/cookbook_download'

module ServerBackup
  class BackupExport < Chef::Knife

    deps do
      require 'fileutils'
      require 'chef/cookbook_loader'
    end

    banner "knife backup export [COMPONENT [COMPONENT ...]] [-D DIR] (options)"

    option :backup_dir,
      :short => "-D DIR",
      :long => "--backup-directory DIR",
      :description => "Store backup data in DIR.  DIR will be created if it does not already exist.",
      :default => Chef::Config[:knife][:chef_server_backup_dir] ? Chef::Config[:knife][:chef_server_backup_dir] : File.join(".chef", "chef_server_backup")

    option :latest,
      :short => "-N",
      :long => "--latest",
      :description => "The version of the cookbook to download",
      :boolean => true

    option :ignore_perm,
      :short => "-I",
      :long => "--ignore-permissions",
      :description => "Continue in case a permission problem occurs",
      :boolean => true

    def run
      validate!
      components = name_args.empty? ? COMPONENTS : name_args
      Array(components).each { |component| self.send(component) }
    end

    private
    COMPONENTS = %w(clients users nodes roles data_bags environments policies cookbooks)
    LOAD_TRIES = 5

    def validate!
      bad_names = name_args - COMPONENTS
      unless bad_names.empty?
        ui.error "Component types #{bad_names.join(",")} are not valid."
        exit 1
      end
    end

    def nodes
      backup_standard("nodes", Chef::Node)
    end

    def clients
      backup_standard("clients", Chef::ApiClient)
    end

    def users
      if Chef::VERSION =~ /^1[1-9]\./
        backup_standard("users", Chef::User)
      else
        ui.warn "users export only supported on chef >= 11"
      end
    end

    def roles
      backup_standard("roles", Chef::Role)
    end

    def environments
      backup_standard("environments", Chef::Environment)
    end

    def policies
      ui.msg "Backing up policies"
      p_lister = ChefDK::Policyfile::Lister.new(config: Chef::Config)
      p_lister.policies_by_group.each do |p_group, policies|
        policies.keys.each do |p_name|
          ui.msg "Backing up policy #{p_group}:#{p_name}"

          # Create directory structure
          dir            = File.join(config[:backup_dir], "policies", p_group, p_name)
          policyfile_dir = File.join(dir, "policyfile")
          site_cb_dir    = File.join(dir, "site-cookbooks")
          lock_file      = File.join(policyfile_dir, "#{p_name}.lock.json")
          [policyfile_dir, site_cb_dir].each { |d| FileUtils.mkdir_p(d) }

          # Download policyfile lock
          redirect_stdout(lock_file) do
            ChefDK::PolicyfileServices::ShowPolicy.new(
              config: Chef::Config,
              ui: ChefDK::UI.new,
              policy_name: p_name,
              policy_group: p_group
            ).display_policy_revision
          end

          # Download policy related cookbooks
          #
          policy_cookbooks(JSON.parse(File.read(lock_file)), p_name, p_group, dir)


          # Find site cookbooks and move to different dir
          filter_site_cookbooks(lock_file).each do |cookbook|
            FileUtils.mv(
              File.join(dir, 'cookbooks', cookbook),
              site_cb_dir
            )
          end
        end
      end
    end

    def redirect_stdout(file_path)
      begin
        original_stdout = $stdout.clone
        $stdout.reopen(File.new(file_path, 'w'))
        retval = yield
      rescue StandardError => e
        $stdout.reopen(original_stdout)
        raise e
      ensure
        $stdout.reopen(original_stdout)
      end
      retval
    end

    def policy_cookbooks(lock, policy_name, policy_group, cookbook_path)
      Chef::Config[:policy_name]     = policy_name
      Chef::Config[:policy_group]    = policy_group
      Chef::Config[:file_cache_path] = cookbook_path
      builder = Chef::PolicyBuilder::Dynamic.new(
        'fake', {}, {}, nil, Chef::EventDispatch::Base.new
      )
      builder.select_implementation(nil)
      builder.sync_cookbooks
      Dir.glob(File.join(cookbook_path, 'cookbooks', '*')).each do |ck|
        next if lock['cookbook_locks'][File.basename(ck)]['source_options']['path'] # cookbooks referred by path
        new_dir = File.join(File.dirname(ck), lock['cookbook_locks'][File.basename(ck)]['cache_key'])
        FileUtils.mv(ck, new_dir)
      end
    end

    def filter_site_cookbooks(policyfile_lock)
      JSON.parse(
        File.read(policyfile_lock)
      )['cookbook_locks'].select do |_k, v|
        v['source_options'].key?('path')
      end.keys
    end

    def data_bags
      ui.msg "Backing up data bags"
      dir = File.join(config[:backup_dir], "data_bags")
      FileUtils.mkdir_p(dir)
      Chef::DataBag.list.each do |bag_name, url|
        FileUtils.mkdir_p(File.join(dir, bag_name))
        Chef::DataBag.load(bag_name).each do |item_name, url|
          ui.msg "Backing up data bag #{bag_name} item #{item_name}"
          item = Chef::DataBagItem.load(bag_name, item_name)
          File.open(File.join(dir, bag_name, "#{item_name}.json"), "w") do |dbag_file|
            dbag_file.print(JSON.pretty_generate(item.raw_data))
          end
        end
      end
    end

    def backup_standard(component, klass)
      ui.msg "Backing up #{component}"
      dir = File.join(config[:backup_dir], component)
      FileUtils.mkdir_p(dir)
      klass.list.each do |component_name, url|
        next if component == "environments" && component_name == "_default"
        ui.msg "Backing up #{component} #{component_name}"
        component_obj = load_object(klass, component_name)
        unless component_obj
          ui.error "Could not load #{klass} #{component_name}."
          next
        end
        File.open(File.join(dir, "#{component_name}.json"), "w") do |component_file|
          component_file.print(JSON.pretty_generate(component_obj))
        end
      end
    end

    def load_object(klass, name, try = 1)
      klass.load(name)
    rescue NoMethodError
      ui.warn "Problem loading #{klass} #{name}. Try #{try}/#{LOAD_TRIES}"
      if try < LOAD_TRIES
        try += 1
        load_object(klass, name, try)
      end
    rescue Net::HTTPServerException => e
      if config[:ignore_perm]
        ui.warn "Problem loading #{name} #{e.message}."
        ui.warn "Possibly an issue with permissions on the chef server... Skipping"
      else
        raise
      end
    end

    def cookbooks
      ui.msg "Backing up cookbooks"
      dir = File.join(config[:backup_dir], "cookbooks")
      FileUtils.mkdir_p(dir)
      if config[:latest]
        cookbooks = rest.get_rest("/cookbooks?latest")
      else
        cookbooks = rest.get_rest("/cookbooks?num_versions=all")
      end
      cookbooks.keys.each do |cb|
        ui.msg "Backing up cookbook #{cb}"
        dld = Chef::Knife::CookbookDownload.new
        cookbooks[cb]['versions'].each do |ver|
          dld.name_args = [cb, ver['version']]
          dld.config[:download_directory] = dir
          dld.config[:force] = true
          begin
            dld.run
          rescue
            ui.msg "Failed to download cookbook #{cb} version #{ver['version']}... Skipping"
            FileUtils.rm_r(File.join(dir, cb + "-" + ver['version']))
          end
        end
      end
    end

  end
end
