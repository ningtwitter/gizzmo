require "pp"
module Gizzard
  class Command
    include Thrift
    
    attr_reader :buffer

    def self.run(command_name, service, global_options, argv, subcommand_options)
      command = Gizzard.const_get("#{classify(command_name)}Command").new(service, global_options, argv, subcommand_options)
      command.run
      if command.buffer && command_name = global_options.render.shift
        run(command_name, service, global_options, command.buffer, OpenStruct.new)
      end
    end

    def self.classify(string)
      string.split(/\W+/).map{|s| s.capitalize }.join("")
    end

    attr_reader :service, :global_options, :argv, :command_options
    def initialize(service, global_options, argv, command_options)
      @service         = service
      @global_options  = global_options
      @argv            = argv
      @command_options = command_options
    end

    def help!(message = nil)
      raise HelpNeededError, message
    end
    
    def output(string)
      if global_options.render.any?
        @buffer ||= []
        @buffer << string.strip
      else 
        puts string
      end
    end
  end

  class AddforwardingCommand < Command
    def run
      help! if argv.length != 3
      table_id, base_id, shard_id_text = argv
      shard_id = ShardId.parse(shard_id_text)
      service.set_forwarding(Forwarding.new(table_id.to_i, base_id.to_i, shard_id))
    end
  end

  class ForwardingsCommand < Command
    def run
      service.get_forwardings().sort_by do |f|
        [ ((f.table_id.abs << 1) + (f.table_id < 0 ? 1 : 0)), f.base_id ]
      end.reject do |forwarding|
        @command_options.table_ids && !@command_options.table_ids.include?(forwarding.table_id)
      end.each do |forwarding|
        output [ forwarding.table_id, forwarding.base_id, forwarding.shard_id.to_unix ].join("\t")
      end
    end
  end

  class SubtreeCommand < Command
    def run
      @roots = []
      argv.each do |arg|
        @id = ShardId.parse(arg)
        @roots += roots_of(@id)
      end
      @roots.uniq.each do |root|
        output root.to_unix
        down(root, 1)
      end
    end

    def roots_of(id)
      links = service.list_upward_links(id)
      if links.empty?
        [id]
      else
        links.map { |link| roots_of(link.up_id) }.flatten
      end
    end
    
    def down(id, depth = 0)
      service.list_downward_links(id).map do |link|
        printable = "  " * depth + link.down_id.to_unix
        output printable
        down(link.down_id, depth + 1)
      end
    end
  end

  class ReloadCommand < Command
    def run
      if global_options.force || ask
        service.reload_forwardings
      else
        STDERR.puts "aborted"
      end
    end

    def ask
      output "Are you sure? Reloading will affect production services immediately! (Type 'yes')"
      gets.chomp == "yes"
    end
  end

  class DeleteCommand < Command
    def run
      argv.each do |arg|
        id  = ShardId.parse(arg)
        service.delete_shard(id)
        output id.to_unix
      end
    end
  end

  class AddlinkCommand < Command
    def run
      up_id, down_id, weight = argv
      help! if argv.length != 3
      weight = weight.to_i
      up_id = ShardId.parse(up_id)
      down_id = ShardId.parse(down_id)
      link = LinkInfo.new(up_id, down_id, weight)
      service.add_link(link.up_id, link.down_id, link.weight)
      output link.to_unix
    end
  end

  class UnlinkCommand < Command
    def run
      up_id, down_id = argv
      up_id = ShardId.parse(up_id)
      down_id = ShardId.parse(down_id)
      service.remove_link(up_id, down_id)
    end
  end

  class UnwrapCommand < Command
    def run
      shard_ids = argv
      help! "No shards specified" if shard_ids.empty?
      shard_ids.each do |shard_id_string|
        shard_id = ShardId.parse(shard_id_string)
        service.list_upward_links(shard_id).each do |uplink|
          service.list_downward_links(shard_id).each do |downlink|
            service.add_link(uplink.up_id, downlink.down_id, uplink.weight)
            new_link = LinkInfo.new(uplink.up_id, downlink.down_id, uplink.weight)
            service.remove_link(uplink.up_id, uplink.down_id)
            service.remove_link(downlink.up_id, downlink.down_id)
            output new_link.to_unix
          end
        end
        service.delete_shard shard_id
      end
    end
  end

  class CreateCommand < Command
    def run
      help! if argv.length != 3
      host, table, class_name = argv
      busy = 0
      source_type = command_options.source_type || ""
      destination_type = command_options.destination_type || ""
      service.create_shard(ShardInfo.new(shard_id = ShardId.new(host, table), class_name, source_type, destination_type, busy))
      service.get_shard(shard_id)
      output shard_id.to_unix
    end
  end

  class LinksCommand < Command
    def run
      shard_ids = @argv
      shard_ids.each do |shard_id_text|
        shard_id = ShardId.parse(shard_id_text)
        service.list_upward_links(shard_id).each do |link_info|
          output link_info.to_unix
        end
        service.list_downward_links(shard_id).each do |link_info|
          output link_info.to_unix
        end
      end
    end
  end

  class InfoCommand < Command
    def run
      shard_ids = @argv
      shard_ids.each do |shard_id|
        shard_info = service.get_shard(ShardId.parse(shard_id))
        output shard_info.to_unix
      end
    end
  end

  class WrapCommand < Command
    def self.derive_wrapper_shard_id(shard_info, wrapping_class_name)
      prefix_prefix = wrapping_class_name.split(".").last.downcase.gsub("shard", "") + "_"
      ShardId.new("localhost", prefix_prefix + shard_info.id.table_prefix)
    end

    def run
      class_name, *shard_ids = @argv
      help! "No shards specified" if shard_ids.empty?
      shard_ids.each do |shard_id_string|
        shard_id   = ShardId.parse(shard_id_string)
        shard_info = service.get_shard(shard_id)
        service.create_shard(ShardInfo.new(wrapper_id = self.class.derive_wrapper_shard_id(shard_info, class_name), class_name, "", "", 0))

        existing_links = service.list_upward_links(shard_id)
        unless existing_links.include?(LinkInfo.new(wrapper_id, shard_id, 1))
          service.add_link(wrapper_id, shard_id, 1)
          existing_links.each do |link_info|
            service.add_link(link_info.up_id, wrapper_id, link_info.weight)
            service.remove_link(link_info.up_id, link_info.down_id)
          end
        end
        output wrapper_id.to_unix
      end
    end
  end

  class FindCommand < Command
    def run
      help!("host is a required option") unless command_options.shard_host
      service.shards_for_hostname(command_options.shard_host).each do |shard|
        next if command_options.shard_type && shard.class_name !~ Regexp.new(command_options.shard_type)
        output shard.id.to_unix
      end
    end
  end

  class LookupCommand < Command
    def run
      table_id, source_id = @argv
      help!("Requires table id and source id") unless table_id && source_id
      shard = service.find_current_forwarding(table_id.to_i, source_id.to_i)
      output shard.id.to_unix
    end
  end
end
