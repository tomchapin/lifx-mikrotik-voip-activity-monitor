#!/usr/bin/env ruby

require 'bundler/setup'
require 'pry'
require 'net/ssh'
require 'lifx'
require 'yaml'
require 'fancy-open-struct'
require 'yaml/store'

puts '-------------------------------------------------------------------'
puts 'Note: you can safely ignore any LiFX circular argument errors above'
puts '-------------------------------------------------------------------'

class PhoneMonitor

  def initialize
    @data                = ''
    @lifx_current_status = nil
    @lifx_client         = nil
    @lifx_light          = nil
    @lifx_last_updated   = Time.now

    config
    cache
  end

  def run
    init_lifx_client

    puts 'Connecting to Mikrotik router via ssh...'
    Net::SSH.start(config.mikrotik_router.ip_address, config.mikrotik_router.ssh_user, :password => config.mikrotik_router.ssh_pass) do |ssh|
      channel = ssh.open_channel do |ch|

        pty_options = { :term       => "xterm",
                        :chars_wide => 120,
                        :chars_high => 24 }

        ch.request_pty(pty_options) do |ch_pty, pty_success|
          raise "could not establish pty" unless pty_success

          ch.exec "/tool torch #{config.mikrotik_router.monitor_interface} src-address=0.0.0.0/0 dst-address=#{config.mikrotik_router.remote_voip_server_ip}" do |ch_cmd, cmd_success|
            raise "could not execute command" unless cmd_success

            # "on_data" is called when the process writes something to stdout
            ch_cmd.on_data do |c, data|
              parse_line(data)
            end

            # "on_extended_data" is called when the process writes something to stderr
            ch_cmd.on_extended_data do |c, type, data|
              $stderr.print data
            end

            ch_cmd.on_close { puts "done!" }
          end
        end

      end

      puts '-------------------------------------------------------------------'

      channel.wait
    end
  end

  def config
    @config ||= if File.exists?(File.join('config.yml'))
                  FancyOpenStruct.new(::YAML.load_file(File.join('config.yml'))).freeze
                else
                  raise 'You need to set up your config.yml file, per the README!'
                end
  end

  def cache
    @cache ||= begin
      store = YAML::Store.new "cache.store.yml"
      store.transaction do
        if store[:colors].nil? || store[:colors].length != config.number_of_phone_lines
          # Set up the block of colors by dividing the spectrum by the number of phone lines
          store[:colors]   = []
          separate_hues_by = 360.0 / config.number_of_phone_lines.to_f
          current_hue      = separate_hues_by
          config.number_of_phone_lines.times do
            store[:colors] << {
                hue:         current_hue,
                ip:          nil,
                reserved_at: nil
            }
            current_hue += separate_hues_by
          end
          store[:colors].shuffle!
        end
      end
      store
    end
  end

  def reserve_or_fetch_ip_hue(ip_address)
    cache.transaction do
      # Find the color reservation by ip
      reserved_entry = cache[:colors].find { |color_data| color_data[:ip] == ip_address }
      if reserved_entry.nil?
        # Unable to find entry - Find the first empty reservation
        reserved_entry = cache[:colors].find { |color_data| color_data[:ip].nil? }
        if reserved_entry.nil?
          # No reservations left - Replace the oldest entry
          reserved_entry = cache[:colors].sort_by { |color_data| color_data[:reserved_at].to_i }.first
        end
      end
      # Set the data
      reserved_entry[:ip] = ip_address
      reserved_entry[:reserved_at] = Time.now
      # Return the reserved entry's hue
      reserved_entry[:hue]
    end
  end

  def init_lifx_client
    @lifx_client = LIFX::Client.lan
    # Discover lights. Blocks until a light is found
    puts 'Looking for LiFX bulb...'
    @lifx_client.discover! do |c|
      c.lights.with_label(config.lifx.light.name)
    end
    puts '-------------------------------------------------------------------'
    @lifx_light = @lifx_client.lights.with_label(config.lifx.light.name)
  end

  def parse_line(line)
    if line.index("Q quit") != nil
      parse_data
      @data = '' # Reset
    else
      @data << line
    end
  end

  def parse_data
    parsed_data        = @data.scan(/ip\s*((?:[0-9]{1,3}\.){3}[0-9]{1,3})\s*(?:[0-9]{1,3}\.){3}[0-9]{1,3}\s*([0-9|\.]+)(kbps|bps|mbps)/)
    active_phone_lines = [] # Array of phone IP addresses

    parsed_data.each do |source_ip, data_rate, rate_type|
      kilobits = 0
      if rate_type == 'kbps'
        kilobits = data_rate.to_f
      elsif rate_type == 'mbps'
        kilobits = data_rate.to_f / 1000
      elsif rate_type == 'bps'
        kilobits = data_rate.to_f * 1000
      end

      if kilobits >= config.mikrotik_router.voip_activity_threshold_kilobits
        active_phone_lines << source_ip
      end
    end

    update_lifx_status(active_phone_lines)
  end

  def update_lifx_status(active_phone_lines)
    if active_phone_lines.length != @lifx_current_status || (Time.now >= @lifx_last_updated + config.lifx.periodically_refresh_delay)
      @lifx_current_status = active_phone_lines.length
      @lifx_last_updated   = Time.now

      if active_phone_lines.length > 0
        # Determine the color as an average of the active phone line hues
        total_hue = active_phone_lines.reduce(0) { |sum, ip| sum + reserve_or_fetch_ip_hue(ip) }
        total_hue = total_hue / active_phone_lines.length if total_hue > 0
        color = LIFX::Color.hsbk(total_hue, config.lifx.light.saturation, config.lifx.light.brightness, config.lifx.light.kelvin)
      else
        # Turn light off
        color = LIFX::Color.hsbk(180, 0, 0, config.lifx.light.kelvin)
      end

      @lifx_light.set_color(color, duration: config.lifx.fade_duration)

      print "Phone Lines Currently Active: #{active_phone_lines.length}\r"
    end
  end

end

PhoneMonitor.new.run