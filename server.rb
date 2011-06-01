require 'eventmachine'
require 'thin'
require 'sinatra'
require "json"
require "rack/fiber_pool"
require "fiber"

class Channel
  attr_reader :callbacks
  
  MESSAGE_BACKLOG = 200
  
  def initialize
    @messages, @callbacks = [], []
  end
  
  def append_message(nick, type, text = "")
    m = { :nick => nick, :type => type, :text => text, :timestamp => Time.new.to_i }
    
    puts case type
      when :msg then "<#{nick}> #{text}"
      when :join then "#{nick} join"
      when :part then "#{nick} part"
    end

    @messages << m

    while @callbacks.length > 0
      @callbacks.shift[:callback].call([m])
    end

    while (@messages.length > MESSAGE_BACKLOG)
      @messages.shift
    end
  end
  
  def query(since, callback)
    matching = []

    @messages.each do |m|
      matching << m if m[:timestamp] > since
    end

    if matching.length > 0
      callback.call(matching)
    else
      fiber = Fiber.current
      @callbacks << { :timestamp => Time.new, :callback => Proc.new { |messages|
        fiber.resume(messages)
      }}
      callback.call(Fiber.yield)
    end
  end
end

class Session
  attr_reader :id, :nick, :timestamp
  
  def initialize(nick)
    @id, @nick, @timestamp = (rand*99999999999).floor.to_s, nick, Time.new
  end
  
  def poke
    @timestamp = Time.new
  end
end

$start_time = Time.new.to_i * 1000
$mem = `ps -o rss= -p #{Process.pid}`.to_i * 1024
$channel = Channel.new 
$sessions = {}

CALLBACK_TIMEOUT = 25
SESSION_TIMEOUT = 60

use Rack::FiberPool

set :public, File.dirname(__FILE__) + '/public'

helpers do
  def create_session(nick)
    return nil if nick.length > 50
    return nil if !(/[^\w_\-^!]/ =~ nick).nil?
    return nil if !$sessions.select { |id, session| session.nick == nick}.empty?

    session = Session.new(nick)
    $sessions[session.id] = session;
    session;
  end
  
  def json_error(error)
    status 400
    content_type :json
    return error.to_json
  end
end

get '/' do
  redirect '/index.html'
end

get '/who' do
  nicks = []
  $sessions.each do |id, session|
    nicks << session.nick
  end
  content_type :json
  { :nicks => nicks, :rss => $mem }.to_json
end

get '/join' do
  puts "/join"
  nick = params[:nick]
  return json_error({ :error => 'Bad nick.' }) if nick.empty?
  session = create_session(nick)
  return json_error({ :error => 'Nick in use' }) if session.nil?
  $channel.append_message(session.nick, :join)
  content_type :json
  { :id => session.id, :nick => session.nick, :rss => $mem, :starttime => $start_time }.to_json
end

get '/part' do
  id = params[:id]
  session = $sessions[id]
  if !session.nil?
    $channel.append_message(session.nick, :part)
    $sessions.delete_if { |id, session| id == session.id }
  end
  content_type :json
  { :rss => $mem }.to_json
end

get '/recv' do
  puts '/recv'
  since = params[:since]
  return json_error({ :error => 'Must supply since parameter' }) if since.empty?
  since = since.to_i
  
  id = params[:id]
  session = $sessions[id]
  
  $channel.query(since, Proc.new {|messages| 
    session.poke if !session.nil?
    content_type :json
    { :messages => messages, :rss => $mem }.to_json
  })
end

get '/send' do
  id, text = params[:id], params[:text]
  return json_error({ :error => 'No such session id' }) if id.empty? || text.empty?
  
  session = $sessions[id]
  return json_error({ :error => 'No such session id' }) if session.nil?

  session.poke

  $channel.append_message(session.nick, :msg, text)
  content_type :json
  { :rss => $mem }.to_json
end

EventMachine::next_tick {
  EventMachine::add_periodic_timer(10) do
    $mem = `ps -o rss= -p #{Process.pid}`.to_i * 1024
  end
}

EventMachine::next_tick {
  EventMachine::add_periodic_timer(3) do
    now = Time.new
    while !$channel.callbacks.empty? && now - $channel.callbacks[0][:timestamp] > CALLBACK_TIMEOUT
      callback = $channel.callbacks.shift[:callback].call([])
    end 
  end
}

EventMachine::next_tick {
  EventMachine::add_periodic_timer(1) do
    now = Time.new
    $sessions.each do |id, session|
      if now - session.timestamp > SESSION_TIMEOUT
        $channel.append_message(session.nick, :part)
        $sessions.delete_if { |id, session| id == session.id }
      end
    end
  end
}