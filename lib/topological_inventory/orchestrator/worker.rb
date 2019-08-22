require "base64"
require "json"
require "manageiq-loggers"
require "manageiq-password"
require "more_core_extensions/core_ext/hash"
require "active_support/core_ext/enumerable"
require "rest-client"
require "yaml"

require "topological_inventory/orchestrator/object_manager"

module TopologicalInventory
  module Orchestrator
    class Worker
      ORCHESTRATOR_TENANT = "system_orchestrator".freeze
      SUPPORTED_APPLICATIONS = ["/insights/platform/catalog", "/insights/platform/topological-inventory"].freeze

      attr_reader :logger, :collector_image_tag, :sources_api, :sources_internal_api, :topology_api, :topology_internal_api

      def initialize(collector_image_tag:, sources_api:, topology_api:)
        @collector_image_tag = collector_image_tag

        @logger = ManageIQ::Loggers::CloudWatch.new

        @sources_api = sources_api
        @sources_internal_api = URI.parse(sources_api).tap { |uri| uri.path = "/internal/v1.0" }.to_s

        @topology_api = topology_api
        @topology_internal_api = URI.parse(topology_api).tap { |uri| uri.path = "/internal/v1.0" }.to_s
      end

      def run
        loop do
          make_openshift_match_database

          sleep 10
        end
      end

      private

      def digest(object)
        require 'digest'
        Digest::SHA1.hexdigest(Marshal.dump(object))
      end

      def make_openshift_match_database
        collector_hash = collectors_from_sources_api

        expected_digests = collector_hash.keys
        current_digests  = collector_digests_from_openshift

        logger.info("Checking...")

        (current_digests - expected_digests).each { |i| remove_openshift_objects_for_source(i) }
        (expected_digests - current_digests).each { |i| create_openshift_objects_for_source(i, collector_hash[i]) }

        logger.info("Checking... complete.")
      end

      ### API STUFF
      def each_source
        source_types_by_id = resources(sources_api_url_for("source_types")).index_by { |st| st["id"] }

        each_tenant do |tenant|
          # Query applications for the supported application_types, then later we can check if the source
          # has any supported applications from this hash
          applications_by_source_id = resources(supported_applications_url, tenant).group_by { |app| app["source_id"] }

          each_resource(topology_api_url_for("sources"), tenant) do |topology_source|
            source = get_and_parse(sources_api_url_for("sources", topology_source["id"]), tenant)
            next if source.nil?

            source_type = source_types_by_id[source["source_type_id"]]
            next unless (collector_definition = collector_definitions[source_type["name"]])

            next if applications_by_source_id[source["id"]].blank?

            endpoints = get_and_parse(sources_api_url_for("sources", source["id"], "endpoints"), tenant)
            next unless (endpoint = endpoints&.dig("data")&.first)

            authentications = get_and_parse(sources_api_url_for("endpoints", endpoint["id"], "authentications"), tenant)
            next unless (authentication = authentications&.dig("data")&.first)

            auth = authentication_with_password(authentication["id"], tenant)
            next if auth.nil?

            yield source, endpoint, auth, collector_definition, tenant
          end
        end
      end

      def collectors_from_sources_api
        hash = {}
        each_source do |source, endpoint, authentication, collector_definition, tenant|
          value = {
            "endpoint_host"   => endpoint["host"],
            "endpoint_path"   => endpoint["path"],
            "endpoint_port"   => endpoint["port"].to_s,
            "endpoint_scheme" => endpoint["scheme"],
            "image"           => collector_definition["image"],
            "image_namespace" => ENV["IMAGE_NAMESPACE"],
            "source_id"       => source["id"],
            "source_uid"      => source["uid"],
            "secret"          => {
              "password" => authentication["password"],
              "username" => authentication["username"],
            },
            "tenant"          => tenant,
          }
          key = digest(value)
          hash[key] = value
        end
        hash
      end

      def sources_api_url_for(*path)
        File.join(sources_api, *path)
      end

      def sources_internal_url_for(path)
        File.join(sources_internal_api, path)
      end

      def topology_api_url_for(path)
        File.join(topology_api, path)
      end

      def topology_internal_url_for(*path)
        File.join(topology_internal_api, *path)
      end

      def each_resource(url, tenant_account = ORCHESTRATOR_TENANT)
        return if url.nil?

        loop do
          response = get_and_parse(url, tenant_account)
          paging = response.kind_of?(Hash)

          resources = paging ? response["data"] : response
          resources.each { |i| yield i }

          break unless paging

          next_page_link = response.fetch_path("links", "next")
          break unless next_page_link

          url = URI.parse(url).merge(next_page_link).to_s
        end
      end

      def resources(url, tenant_account = ORCHESTRATOR_TENANT)
        Enumerator.new { |enum| each_resource(url, tenant_account) { |r| enum.yield r } }
      end

      def get_and_parse(url, tenant_account = ORCHESTRATOR_TENANT)
        JSON.parse(
          RestClient.get(url, tenant_header(tenant_account))
        )
      rescue RestClient::NotFound
        nil
      end

      def tenant_header(tenant_account)
        {"x-rh-identity" => Base64.strict_encode64({"identity" => {"account_number" => tenant_account}}.to_json)}
      end

      def each_tenant
        each_resource(topology_internal_url_for("tenants")) { |tenant| yield tenant["external_tenant"] }
      end

      # Set of ids for supported applications
      def supported_application_type_ids
        ids = []
        each_resource(sources_api_url_for("application_types")) do |application_type|
          ids << application_type["id"] if SUPPORTED_APPLICATIONS.include?(application_type["name"])
        end
        ids
      end

      # URL to get a list of applications for supported application types
      def supported_applications_url
        query = CGI.escape(supported_application_type_ids.map { |id| "filter[application_type_id][eq]=#{id}" }.join("&"))
        sources_api_url_for("applications?#{query}")
      end

      # HACK: for Authentications
      def authentication_with_password(id, tenant_account)
        get_and_parse(sources_internal_url_for("/authentications/#{id}?expose_encrypted_attribute[]=password"), tenant_account)
      end

      ### ------------------
      ### Orchestrator Stuff
      ###
      def collector_definitions
        @collector_definitions ||= begin
          {
            "amazon"        => {
              "image" => "topological-inventory-amazon:#{collector_image_tag}"
            },
            "ansible-tower" => {
              "image" => "topological-inventory-ansible-tower:#{collector_image_tag}"
            },
            "openshift"     => {
              "image" => "topological-inventory-openshift:#{collector_image_tag}"
            },
          }
        end
      end

      def object_manager
        @object_manager ||= ObjectManager.new
      end

      ### ---------------
      ### Openshift stuff
      ###
      def collector_digests_from_openshift
        object_manager.get_deployment_configs("topological-inventory/collector=true").collect { |i| i.metadata.labels["topological-inventory/collector_digest"] }
      end

      def create_openshift_objects_for_source(digest, source)
        logger.info("Creating objects for source #{source["source_id"]} with digest #{digest}")

        secret_name = collector_deployment_secret_name_for_source(source)
        object_manager.create_secret(secret_name, source["secret"])
        logger.info("Secret #{secret_name} created for source #{source["source_id"]}")

        deployment_config_name = collector_deployment_name_for_source(source)
        object_manager.create_deployment_config(deployment_config_name, source["image_namespace"], source["image"]) do |d|
          d[:metadata][:labels]["topological-inventory/collector_digest"] = digest
          d[:metadata][:labels]["topological-inventory/collector"] = "true"
          d[:spec][:replicas] = 1
          container = d[:spec][:template][:spec][:containers].first
          container[:env] = collector_container_environment(source)
        end
        logger.info("DeploymentConfig #{deployment_config_name} created for source #{source["source_id"]}")
      rescue TopologicalInventory::Orchestrator::ObjectManager::QuotaError
        update_topological_inventory_source_refresh_status(source, "quota_limited")
        logger.info("Skipping Deployment Config creation for source #{source["source_id"]} because it would exceed quota.")
      else
        update_topological_inventory_source_refresh_status(source, "deployed")
      end

      def update_topological_inventory_source_refresh_status(source, refresh_status)
        RestClient.patch(
          topology_internal_url_for("sources", source["source_id"]),
          {:refresh_status => refresh_status}.to_json,
          tenant_header(source["tenant"])
        )
      rescue RestClient::NotFound
        logger.error("Failed to update 'refresh_status' on source #{source["source_id"]}")
      end

      def remove_openshift_objects_for_source(digest)
        return unless digest

        deployment = object_manager.get_deployment_configs("topological-inventory/collector_digest=#{digest}").detect { |i| i.metadata.labels["topological-inventory/collector"] == "true" }
        return unless deployment

        logger.info("Removing deployment config #{deployment.metadata.name}")
        object_manager.delete_deployment_config(deployment.metadata.name)
        logger.info("Removing secret #{deployment.metadata.name}-secrets")
        object_manager.delete_secret("#{deployment.metadata.name}-secrets")
      end

      def collector_deployment_name_for_source(source)
        "topological-inventory-collector-source-#{source["source_id"]}"
      end

      def collector_deployment_secret_name_for_source(source)
        "#{collector_deployment_name_for_source(source)}-secrets"
      end

      def collector_container_environment(source)
        secret_name = collector_deployment_secret_name_for_source(source)
        [
          {:name => "AUTH_PASSWORD", :valueFrom => {:secretKeyRef => {:name => secret_name, :key => "password"}}},
          {:name => "AUTH_USERNAME", :valueFrom => {:secretKeyRef => {:name => secret_name, :key => "username"}}},
          {:name => "ENDPOINT_HOST", :value => source["endpoint_host"]},
          {:name => "ENDPOINT_PATH", :value => source["endpoint_path"]},
          {:name => "ENDPOINT_PORT", :value => source["endpoint_port"]},
          {:name => "ENDPOINT_SCHEME", :value => source["endpoint_scheme"]},
          {:name => "INGRESS_API", :value => "http://#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_HOST"]}:#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_PORT"]}"},
          {:name => "SOURCE_UID",  :value => source["source_uid"]},
        ]
      end
    end
  end
end
