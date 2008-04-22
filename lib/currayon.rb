require "rubygems"
require "xmpp4r"
require "xmpp4r/roster"
require "xmpp4r/version"
require "xurrency"
require "delegate"
require "thread"
require "fileutils"
require "logger"
require "singleton"

# for debug
Jabber.debug = $DEBUG

class Currayon
  VERSION = "001"

  class Config
    include Singleton

    def initialize
      @table = Hash.new
      default_settings
    end

    def default_settings
      o :amount_limit => 1_0000_0000_0000
      o :cc_queue_max => 1000
      o :log_dir => "log"
      o :log_lotation => "monthly"
      o :log_filename => "currayon.log"
      o :presence => 45
    end

    def o(setting)
      setting.each {|key, val| @table[key] = val }
    end

    class << self
      def setup(&block)
        instance.instance_eval(&block)
      end

      def method_missing(name, *args)
        instance.instance_eval { @table[name] }
      end
    end
  end

  class Logger < ::Logger
    include Singleton

    def initialize
      # create log dir
      FileUtils.mkdir_p Config.log_dir

      # setup log name and lotation
      super(File.join(Config.log_dir, "currayon.log"), Config.log_lotation)

      # define format
      @formatter = lambda do |severity, time, progname, msg|
        timestamp = time.strftime "%Y-%m-%d %H:%M:%S"
        "#{severity} #{timestamp} #{msg}\n"
      end

      # log level
      @level = $DEBUG ? Logger::DEBUG : Logger::INFO
    end

    # delegate
    def self.method_missing(name, *args)
      instance.__send__(name, *args)
    end
  end

  class CurrencyConverter
    attr_reader :queue, :thread

    def initialize
      @xu = Xurrency.new
      @queue = SizedQueue.new(Config.cc_queue_max)
      @thread = Thread.new { while job = @queue.pop do convert(*job) end }
    end

    def currencies; @xu.currencies; end

    def push(*args)
      Logger.debug "pushed to cc queue: " + args[1..-1].join(" ")
      @queue.push(args)
    end

    def shutdown
      # wait to finish all conversions
      sleep 1 while @queue.size > 0

      # kill
      @thread.kill
    end

    private

    def convert(res, amount, base, target)
      # needs to update?
      cached = @xu.values_cached?(base)
      expired = Time.now - @xu.values(base)[:timestamp] > 30*60
      if not cached or expired
        @xu.update_values(base)
        Logger.info "updated values of #{base}"
      end

      # calc and send the result
      value = @xu.value(amount, base, target)
      res.send "#{amount} #{base} = #{value} #{target}"
    end
  end

  # Jabber response.
  class Response
    def initialize(client, msg)
      @client = client
      @send_to = msg.from
    end

    def type; "jabber"; end

    def send(msg)
      @client.send Jabber::Message.new(@send_to, msg.to_s).set_type(:chat)
    end

    def error(msg)
      send("ERROR: " + msg.to_s)
    end

    def usage
      send("Currayon usage: amount base target")
    end

    def list
      send(@client.cc.currencies.sort.join(", "))
    end

    def who
      send(<<__MSG__)
Currayon is a currency converter.
URL: http://d.hatena.ne.jp/keita_yamaguchi/
__MSG__
    end
  end

  # Twitter version response.
  class TwitterResponse < Response
    def initialize(client, msg)
      @twname = msg.elements["screen_name"].text
      super(client, msg)
    end

    # send direct message
    def send(msg); super("d #{@twname} #{msg}"); end

    def type; "twitter"; end
  end

  # Currayon core: recieves and sends messages.
  class Reciever < DelegateClass(Jabber::Client)
    include Jabber

    def initialize(cc)
      @cc = cc
      super(Client.new(JID.new(Config.user)))
      start
    end

    def start
      Logger.info "setup reciever"

      # make connection
      connect
      Logger.info "connected to server as #{Config.user}"

      # auth
      auth(Config.password)
      Logger.info "auth OK"

      # handlers
      register_handlers

      # initial presence
      send_presence
      Logger.info "sent initial presence"

      # set currayon profile
      init_version_responder

      Logger.info "start to recieve messages"
    end

    undef_method :send

    def send_presence
      send(Presence::new.set_type(:available))
    end

    def shutdown
      stop
    end

    private

    def init_version_responder
      Version::SimpleResponder.new(__getobj__,
                                   "Currayon",
                                   Currayon::VERSION,
                                   "Keita Yamaguchi")
    end

    def handle_message(msg)
      # chat only
      return if msg.type != :chat
      # not empty body
      return if msg.body.nil? or msg.body.size == 0
      # ignore twitter direct messages
      return if msg.body =~ /Your direct message has been sent./

      # make response
      res = (msg.from == "twitter@twitter.com" ?
               TwitterResponse : Response).new(self, msg)

      # list
      return res.list if msg.body =~ /list|currenc(y|ies)|code(s?)/

      # help
      return res.usage if msg.body =~ /help|usage/

      # who
      return res.who if msg.body =~ /who/

      #
      # check syntax of the message
      #
      unless md = /(\d+) ([a-zA-Z]{3}) ([a-zA-Z]{3})/.match(msg.body)
        return res.usage
      end
      amount, base, target = md[1], md[2], md[3]
      amount = amount.gsub(",", "").to_i

      # check amount size
      if amount > Config.amount_limit
        return res.error("The amount is too large!")
      end

      # base and target should not be empty
      return res.usage unless base or target

      # and it should be currency code
      not_currency_code = "seems not to be a suportted currency code."
      unless @cc.currencies.include?(base)
        return res.error(base + not_currency_code)
      end
      unless @cc.currencies.include?(target)
        return res.error(target + not_currency_code)
      end

      # convert
      Logger.info "#{res.type}: #{amount} #{base} #{target}"

      @cc.push(res, amount, base, target)
    end

    def register_handlers
      # message handler
      add_message_callback {|msg| handle_message(msg) }

      roster = Roster::Helper.new(__getobj__)

      # accept subscription
      roster.add_subscription_request_callback do |item, pres|
        Logger.info "subscription request from #{pres.from}"
        roster.accept_subscription(pres.from)
      end

      roster.add_subscription_callback do |item, pres|
        if pres.type == :unsubscribe
          Logger.info "unsubscription request from #{pres.from}"
        end
      end

      # accept subscription, is this needed?
      roster.add_update_callback do |item, pres|
        if pres.subscription == :from
          roster.accept_subscription(pres.jid)
        end
      end

      # handle exceptions
      on_exception do |e, client, stage|
        Logger.error "#{stage}: #{e.to_s}"
        start
      end
    end
  end

  # configuration
  def self.setup(&block)
    Config.instance.instance_eval(&block)
  end

  def initialize
    # log version
    Logger.info "Currayon version #{VERSION} (PID:#{$$})"

    # make converter
    @cc = CurrencyConverter.new

    # make reciever
    @reciever = Reciever.new(@cc)

    # handle signals
    trap(:INT, lambda{ @thread.kill; shutdown })
    trap(:HUP, lambda{ @reciever.stop; @reciever.start })

    # wait
    @thread = Thread.new { loop { sleep Config.presence; ping } }
    @thread.join
  end

  private

  def ping
    if @reciever.is_connected?
      @reciever.send_presence
    else
      # lost connection: wait to restart
      Logger.warn "lost connection"
    end
  end

  def shutdown
    # shutdown reciever
    @reciever.shutdown
    Logger.info "shutdown reciever"

    # shutdown converter
    @cc.shutdown
    Logger.info "shutdown currency converter"

    # shutdown self and exit
    Logger.info "shutdown currayon (PID:#{$$})"
    exit
  end
end
