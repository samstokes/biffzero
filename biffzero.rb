#!/home/sam/.rvm/rubies/ruby-1.8.7-p302/bin/ruby -rubygems
require 'net/imap'
require 'gmail_xoauth'
require 'redis'
require 'SVG/Graph/Line'
require 'yaml'

class BiffZero
  attr_reader :config, :imap, :redis

  def initialize(config_path)
    @config = open(config_path) {|yaml| YAML.load(yaml) }
  end

  def connect(&block)
    if block_given?
      begin
        do_connect
        yield self
      ensure
        disconnect
      end
    else
      do_connect
    end
  end

  def disconnect
    @imap.disconnect if @imap
  ensure
    @imap = nil
  end
  alias close disconnect

  def save_message_count(mailbox, count)
    key = key_message_counts(mailbox)
    redis.multi do
      redis.rpush(key, count)
      redis.ltrim(key, -336, -1)
    end
  end

  def save_message_counts
    config['mailboxes'].each do |mailbox|
      save_message_count(mailbox, message_count(imap, mailbox))
    end
  end

  def graph_message_counts
    counts = config['mailboxes'].map do |mailbox|
      [mailbox, redis.lrange(key_message_counts(mailbox), 0, -1).map {|s| s.to_i }]
    end
    graph = SVG::Graph::Line.new(
      :width => 600,
      :height => 300,
      :fields => ['zero'] + (1..counts[0][1].length).map {|n| n.to_s }.reverse,
      :stacked => true,
      :area_fill => true,
      :show_x_labels => false,
      :scale_integers => true,
      :min_scale_value => 0,
      :graph_title => config['name'],
      :show_graph_title => true,
      :show_data_points => false,
      :show_data_values => false
    )
    counts.each do |mailbox, counts|
      graph.add_data(:data => counts, :title => mailbox)
    end
    graph.burn
  end

  def message_count(imap, mailbox)
    imap.examine(mailbox)
    imap.search(['NOT', 'Deleted']).length
  end

  class << self
    def connect(config_path, *args, &block)
      new(config_path).connect(*args, &block)
    end
  end

  private
  def do_connect
    @imap = Net::IMAP.new(config['host'], config['port'], true)
    authenticate!
    @redis = Redis.new
  rescue => e
    disconnect rescue nil
    raise
  end

  def authenticate!
    authentication = config['authentication']
    case authentication['method']
    when 'login'
      @imap.login(config['username'], authentication['password'])
    when 'xoauth'
      @imap.authenticate('XOAUTH', config['username'],
                         :consumer_key => 'anonymous',
                         :consumer_secret => 'anonymous',
                         :token => authentication['token'],
                         :token_secret => authentication['token_secret'])
    else
      raise ArgumentError, "Unknown authentication method #{authentication['method']}"
    end
  end

  def key_message_counts(mailbox)
    "message_counts:#{config['name']}:#{mailbox}"
  end
end

config_path = ARGV[0] or raise 'Please specify config file'
BiffZero.connect(config_path) do |bz|
  bz.save_message_counts
  print bz.graph_message_counts
end
