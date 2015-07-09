#!/usr/bin/env ruby

require 'bundler/setup'
require 'pry'
require 'net/ssh'
require 'active_support/all'
require 'lifx'
require 'yaml'
require 'fancy-open-struct'

class PhoneMonitor

  def initialize
    @config              = {}
    @data                = ''
    @lifx_current_status = nil
    @lifx_client         = nil
    @lifx_light          = nil
    @lifx_last_updated   = Time.now

    load_config
  end

  def run
    init_lifx_client

    Net::SSH.start(@config.mikrotik_router.ip_address, @config.mikrotik_router.ssh_user, :password => @config.mikrotik_router.ssh_pass) do |ssh|
      channel = ssh.open_channel do |ch|

        pty_options = { :term       => "xterm",
                        :chars_wide => 120,
                        :chars_high => 24 }

        ch.request_pty(pty_options) do |ch_pty, pty_success|
          raise "could not establish pty" unless pty_success

          ch.exec "/tool torch bridge-local src-address=0.0.0.0/0 dst-address=#{@config.remote_voip_server_ip}" do |ch_cmd, cmd_success|
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

      channel.wait
    end
  end

  def load_config
    @config = if File.exists?(File.join('config.yml'))
                FancyOpenStruct.new(::YAML.load_file(File.join('config.yml')))
              else
                raise 'You need to set up your config.yml file, per the README!'
              end
  end

  def init_lifx_client
    @lifx_client = LIFX::Client.lan
    # Discover lights. Blocks until a light is found
    @lifx_client.discover! do |c|
      c.lights.with_label(@config.lifx_light_name)
    end
    @lifx_light = @lifx_client.lights.with_label(@config.lifx_light_name)
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
    active_phone_lines = []

    parsed_data.each do |data|
      kilobits = 0
      if data[2] == 'kbps'
        kilobits = data[1].to_i
      elsif data[2] == 'mbps'
        kilobits = data[1].to_i * 1000
      end

      if kilobits >= @config.voip_activity_threshold_kilobits
        active_phone_lines += [data[0]]
      end
    end

    update_lifx_status(active_phone_lines)
  end

  def update_lifx_status(active_phone_lines)
    if active_phone_lines.length != @lifx_current_status || (Time.now >= @lifx_last_updated + @config.lifx_sync_delay_in_seconds.seconds)
      @lifx_current_status = active_phone_lines
      @lifx_last_updated   = Time.now

      # Determine the color, based on the suffix of each IP
      total_hue            = active_phone_lines.reduce(0) { |sum, ip| sum + (ip.split('.').last.to_f / 255 * 360) }
      total_hue            = total_hue / active_phone_lines.length if active_phone_lines.length > 0

      if active_phone_lines.length > 0
        color = LIFX::Color.hsbk(total_hue, 1, 0.7, 3500)
      else
        color = LIFX::Color.hsbk(184, 1, 0, 3500)
      end

      @lifx_light.set_color(color, duration: 0.25)

      print "#{active_phone_lines.length}\r"
    end
  end

end

PhoneMonitor.new.run