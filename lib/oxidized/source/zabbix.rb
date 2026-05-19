# ~/.config/oxidized/source/zabbix.rb
#
# Oxidized source plugin for Zabbix
#
# Fetches the device list from Zabbix via a single host.get API call,
# filtering by tag and mapping inventory fields to Oxidized node attributes.
#
# Credentials are NOT sourced from Zabbix macros: use Oxidized's native
# username/password (global or per-group) in your oxidized config instead.
#
# ─── Required config ─────────────────────────────────────────────────────────
#
#   source:
#     default: zabbix
#     zabbix:
#       url:   https://zabbix.example.com/api_jsonrpc.php
#       token: YOUR_API_TOKEN
#
# ─── Full config reference ───────────────────────────────────────────────────
#
#   source:
#     default: zabbix
#     zabbix:
#       url:         https://zabbix.example.com/api_jsonrpc.php
#       token:       YOUR_API_TOKEN
#       tag:         Backup          # tag name filter       (default: Backup)
#       tag_value:   Oxidized        # tag value filter      (default: Oxidized)
#       ssl_verify:  true            # verify TLS cert       (default: true)
#       bearer_auth: false           # use Bearer header instead of auth in body (default: false)
#       map:
#         model: software_app_a     # inventory field → model (default: software_app_a)
#         group: software_app_b     # inventory field → group (default: software_app_b)
#
#   # Credentials are managed by Oxidized, not by this source.
#   # Define them globally and/or override per group:
#   username: oxidized
#   password: global_password
#   groups:
#     Cisco_IOS:
#       username: admin
#       password: cisco_secret
#     Juniper:
#       username: readonly
#       password: juniper_secret
#
# ─── Notes ───────────────────────────────────────────────────────────────────
#
#   - Hosts missing the model inventory field are skipped (logged as warning).
#   - Hosts missing the group inventory field are assigned group "default".
#   - Token is sent in the JSON body as "auth" field (Zabbix 6.0 documented method).
#     Set bearer_auth: true to use the Authorization: Bearer header instead (Zabbix >= 5.4).

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Oxidized
  module Source
    class Zabbix < Source
      class NoConfig < OxidizedError; end

      # Zabbix tag operator 1 = CONDITION_OPERATOR_EQUAL
      TAG_OPERATOR_EQUALS = 1

      DEFAULTS = {
        tag:       'Backup',
        tag_value: 'Oxidized',
        inv_model: 'software_app_a',
        inv_group: 'software_app_b'
      }.freeze

      def initialize
        super
        @cfg = Oxidized.config.source.zabbix

        unless @cfg.url && @cfg.token
          raise NoConfig, 'Please set source.zabbix.url and source.zabbix.token'
        end

        @tag_filter       = cfg_str(:tag,        DEFAULTS[:tag])
        @tag_value_filter = cfg_str(:tag_value,   DEFAULTS[:tag_value])
        @inv_model_field  = map_str(:model,       DEFAULTS[:inv_model])
        @inv_group_field  = map_str(:group,       DEFAULTS[:inv_group])
        @ssl_verify       = @cfg.ssl_verify.nil?  ? true  : @cfg.ssl_verify
        @bearer_auth      = @cfg.bearer_auth == true
      end

      def load(_ = nil)
        hosts = rpc('host.get',
                    {
                      output:           ['host'],
                      # status: '0' = monitored/enabled in Zabbix.
                      # Disabled hosts (status: '1') are excluded at the API
                      # level and will not appear as Oxidized nodes at all.
                      filter:           { status: '0' },
                      tags:             [{ tag:      @tag_filter,
                                           value:    @tag_value_filter,
                                           operator: TAG_OPERATOR_EQUALS }],
                      selectInventory:  [@inv_model_field, @inv_group_field],
                      selectInterfaces: ['useip', 'ip', 'dns']
                    }) || []

        return [] if hosts.empty?

        Oxidized.logger.info "Zabbix: #{hosts.size} host(s) matched " \
                             "tag '#{@tag_filter}'='#{@tag_value_filter}'"

        nodes = hosts.map { |h| build_node(h) }

        Oxidized.logger.info "Zabbix: returning #{nodes.size} valid node(s)"
        nodes
      end

      private

      def build_node(host)
        inventory = host['inventory'] || {}

        # Model: fall back to 'default' if the inventory field is empty,
        # matching the PHP reference script behaviour ($host['inventory']['software_app_a'] ?? 'default')
        model = inventory[@inv_model_field].to_s.strip
        if model.empty?
          Oxidized.logger.debug "Zabbix: '#{host['host']}' — inventory field " \
                                "'#{@inv_model_field}' (model) is empty, using 'default'"
          model = 'default'
        end

        # IP: use useip-aware address picker (honours Zabbix useip/dns flag)
        ip = pick_address(host['interfaces'] || [])

        node = { name: host['host'], ip: ip, model: model }

        # Group: only set the key when the inventory field is non-empty.
        # When absent, Oxidized uses the default group from its own config —
        # do NOT hardcode the string 'default' here.
        group = inventory[@inv_group_field].to_s.strip
        unless group.empty?
          node[:group] = group
        else
          Oxidized.logger.debug "Zabbix: '#{host['host']}' — inventory field " \
                                "'#{@inv_group_field}' (group) is empty, " \
                                "Oxidized will use its configured default group"
        end

        node
      end

      # ── Interface address picker ────────────────────────────────────────────

      # Mirrors Zabbix's own host-connection logic:
      #   useip == '1' → use the ip field
      #   useip == '0' → use the dns field
      # Iterates all interfaces and returns the first non-empty address found.
      # Falls back to the other field if the preferred one is empty (misconfigured
      # host in Zabbix), and ultimately returns '' if nothing is usable.
      def pick_address(interfaces)
        interfaces.each do |iface|
          addr = if iface['useip'].to_s == '1'
                   iface['ip'].to_s.strip.empty? ? iface['dns'].to_s.strip \
                                                 : iface['ip'].to_s.strip
                 else
                   iface['dns'].to_s.strip.empty? ? iface['ip'].to_s.strip \
                                                  : iface['dns'].to_s.strip
                 end
          return addr unless addr.empty?
        end
        ''
      end

      # ── Config accessor helpers ─────────────────────────────────────────────

      def cfg_str(key, default)
        v = @cfg.respond_to?(key) ? @cfg.public_send(key).to_s.strip : ''
        v.empty? ? default : v
      end

      def map_str(key, default)
        return default unless @cfg.respond_to?(:map) && @cfg.map.respond_to?(key)
        v = @cfg.map.public_send(key).to_s.strip
        v.empty? ? default : v
      end

      # ── JSON-RPC ────────────────────────────────────────────────────────────

      def rpc(method, params)
        uri  = URI.parse(@cfg.url)
        http = Net::HTTP.new(uri.host, uri.port)
        if uri.scheme == 'https'
          http.use_ssl     = true
          http.verify_mode = @ssl_verify ? OpenSSL::SSL::VERIFY_PEER
                                         : OpenSSL::SSL::VERIFY_NONE
        end

        payload = { jsonrpc: '2.0', method: method, params: params, id: 1 }

        if @bearer_auth
          # opt-in: Authorization: Bearer header (Zabbix >= 5.4 alternative)
          headers = { 'Content-Type'  => 'application/json-rpc',
                      'Authorization' => "Bearer #{@cfg.token}" }
        else
          # default: token in the "auth" field per Zabbix 6.0 documented API
          payload[:auth] = @cfg.token
          headers = { 'Content-Type' => 'application/json-rpc' }
        end

        resp   = http.post(uri.request_uri, payload.to_json, headers)
        parsed = JSON.parse(resp.body)

        if parsed['error']
          Oxidized.logger.error "Zabbix RPC error on '#{method}': #{parsed['error']}"
          return []
        end

        parsed['result'] || []
      rescue StandardError => e
        Oxidized.logger.error "Zabbix RPC(#{method}): #{e.class} #{e.message}"
        []
      end
    end
  end
end
