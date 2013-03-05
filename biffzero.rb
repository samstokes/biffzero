#!/home/sam/.rvm/rubies/ruby-1.8.7-p302/bin/ruby -rubygems
require 'net/https'
require 'net/imap'
require 'gmail_xoauth'
require 'redis'
require 'SVG/Graph/Line'
require 'uri'
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

  def message_counts
    config['mailboxes'].map do |mailbox|
      [mailbox, message_count(imap, mailbox)]
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

  def beeminder
    config['beeminder']
  end

  def beemind(message_counts)
    generic_comment = "Reported by biffzero at #{Time.now.strftime('%l:%M%P %Z')}"
    comment = if message_counts.size > 1
                "#{Hash[*message_counts.flatten(1)].inspect} | #{generic_comment}"
              else
                generic_comment
              end
    url = URI.parse("https://www.beeminder.com/api/v1/users/#{beeminder['user']}/goals/#{beeminder['goal']}/datapoints.json")
    request = Net::HTTP::Post.new(url.path)
    request.set_form_data(
      'auth_token' => beeminder['token'],
      'timestamp' => Time.now.to_i.to_s,
      'comment' => comment,
      'value' => message_counts.map {|mailbox, count| count }.inject(&:+).to_s
    )
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.ca_file = '/usr/lib/ssl/certs/ca-certificates.crt'
    http.request(request)
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
  message_counts = bz.message_counts
  message_counts.each do |mailbox, count|
    bz.save_message_count(mailbox, count)
  end
  bz.beemind(message_counts) if bz.beeminder
  print bz.graph_message_counts
end
