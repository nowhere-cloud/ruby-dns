#!/usr/bin/env ruby

require 'ipaddress'
require 'rubydns'
require 'sequel'

# Dotenv
# Load Environment Variables.
# Uncomment if you use it locally
# require 'dotenv'
# Dotenv.load

# Class: Core
# The DNS Server Core
class Core
  # Used to reduce code redundancy
  IN = Resolv::DNS::Resource::IN
  Name = Resolv::DNS::Name

  # Define Constants based on values saved at Environment Variables
  DNS_SUFFIX    = ENV['DNS_SUFFIX']
  DNS_BIND      = ENV['DNS_PORT'].to_i
  UPSTREAM_1_IP = ENV['UPSTREAM_DNS1_IP']
  UPSTREAM_1_PO = ENV['UPSTREAM_DNS1_PORT'].to_i
  UPSTREAM_2_IP = ENV['UPSTREAM_DNS2_IP']
  UPSTREAM_2_PO = ENV['UPSTREAM_DNS2_PORT'].to_i
  TTL_VALUE     = ENV['DNS_TTL'].to_i

  # Confiure Binding and upstream DNS
  def initialize
    @database = Sequel.connect(ENV['DATABASE_URL'])
  end

  # The real server instance...
  def start
    # These "Just copy assignment" is not preventable ...

    records = @database[:dns_records]
    esc_dnssuffix = Regexp.escape(DNS_SUFFIX)
    upstreamdns = RubyDNS::Resolver.new([\
                                          [:udp, UPSTREAM_1_IP, UPSTREAM_1_PO], \
                                          [:tcp, UPSTREAM_1_IP, UPSTREAM_1_PO], \
                                          [:udp, UPSTREAM_2_IP, UPSTREAM_2_PO], \
                                          [:tcp, UPSTREAM_2_IP, UPSTREAM_2_PO]  \
                                        ])
    RubyDNS.run_server(listen: [[:udp, '::', DNS_BIND], [:tcp, '::', DNS_BIND]]) do
      # Catch Localhost Request
      match(/localhost/, IN::A) do |transaction|
        transaction.respond!('127.0.0.1')
      end

      # Catch Localhost Request, on IPv6
      match(/localhost/, IN::AAAA) do |transaction|
        transaction.respond!('::1')
      end

      # This is used to match the DNS Suffix of the internal zone
      match(/(.+)\.#{esc_dnssuffix}/, IN::A) do |transaction, match_data|
        begin
          answers = records.where(name: match_data[1], type: 'A')
          if answers.nil? || answers.empty?
            transaction.fail!(:NXDomain)
          else
            answers.each do |answer|
              transaction.respond!(answer[:ipv4address], ttl: TTL_VALUE)
            end
          end
        rescue Sequel::Error
          # deal with unavailable db
          transaction.fail!(:ServFail)
        end
      end

      match(/(.+)\.#{esc_dnssuffix}/, IN::AAAA) do |transaction, match_data|
        begin
          answers = records.where(name: match_data[1], type: 'A')
          if answers.nil? || answers.empty?
            transaction.fail!(:NXDomain)
          else
            answers.each do |answer|
              transaction.respond!(answer[:ipv6address], ttl: TTL_VALUE)
            end
          end
        rescue Sequel::Error
          # Deal with unavailable db
          transaction.fail!(:ServFail)
        end
      end

      match(/(.+)\.#{esc_dnssuffix}/, IN::CNAME) do |transaction, match_data|
        begin
          answers = records.first(name: match_data[1], type: 'CNAME')
          if answers.nil? || answers.empty?
            transaction.fail!(:NXDomain)
          else
            transaction.respond!(answer[:cname], ttl: TTL_VALUE)
          end
        rescue Sequel::Error
          # Deal with unavailable DB
          transaction.fail!(:ServFail)
        end
      end

      match(/(.+)\.#{esc_dnssuffix}/, IN::MX) do |transaction, match_data|
        begin
          answers = records.where(name: match_data[1], type: 'MX')
          if answers.nil? || answers.empty?
            transaction.fail!(:NXDomain)
          else
            answers.each do |answer|
              transaction.respond!(answer[:cname], ttl: TTL_VALUE)
            end
          end
        rescue Sequel::Error
          # Deal with unavailable DB
          transaction.fail!(:ServFail)
        end
      end

      # Handling PTR Record (IP to Hostname)
      match(/(.+)\.in-addr.arpa/, IN::PTR) do |transaction, match_data|
        realip = match_data[1].split('.').reverse.join('.')
        if IPAddress.valid_ipv4?(realip)
          begin
            answers = records.where(ipv4address: realip)
            if answers.nil? || answers.empty?
              transaction.passthrough!(upstreamdns)
            else
              answers.each do |answer|
                transaction.respond!(Name.create(answer[:name] + '.' + DNS_SUFFIX), ttl: TTL_VALUE)
              end
            end
          rescue Sequel::Error
            # Deal with unavailable DB, Fallback to External Provider
            transaction.passthrough!(upstreamdns)
          end
        else
          # Refusing inappropiate requests, inappropiate IPv6 requests also goes here.
          transaction.fail!(:Refused)
        end
      end

      # Handling IPv6 PTR Record
      match(/(.+)\.ip6.arpa/, IN::PTR) do |transaction, match_data|
        incoming = match_data[1].split('.').reverse.join
        if incoming =~ /^[0-9a-fA-F]+$/
          realip6 = IPAddress::IPv6.parse_hex(incoming).to_s
          realip4 = (IPAddress::IPv6::Mapped.new(realip6).mapped? ? '::FFFF:' + IPAddress::IPv6::Mapped.new(realip6).ipv4.address : '').to_s
          begin
            answers = records.where(ipv6address: [realip6, realip4])
            if answers.nil? || answers.empty?
              transaction.passthrough!(upstreamdns)
            else
              answers.each do |answer|
                transaction.respond!(Name.create(answer[:name] + '.' + DNS_SUFFIX), ttl: TTL_VALUE)
              end
            end
          rescue Sequel::Error
            # Deal with unavailable DB, Fallback to External Provider
            transaction.passthrough!(upstreamdns)
          end
        else
          # Refusing inappropiate requests, inappropiate IPv6 requests also goes here.
          transaction.fail!(:Refused)
        end
      end

      # Default DNS handler, forward outside address to upstream DNS
      otherwise do |transaction|
        transaction.passthrough!(upstreamdns)
      end
    end
  end
end

dns = Core.new
dns.start
