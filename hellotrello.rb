#!/usr/bin/env ruby
require 'cinch'
require 'net/http'
require 'open-uri'
require 'active_support/core_ext/object'
require 'yaml'

$config = YAML.load_file('config.yml')
$irc = YAML.load_file('irc_formatting_codes.yml')

def fetch(url, params = {})
  params = '?' + params.merge( $config['trello'] ).to_query
  url = url+ params
  body = open(url).read
  JSON.parse(body)
end

# Generates the Regexp pattern that's used for detecting incoming commands
def command(input)
  Regexp.new("#{$config['irc']['nick']}_?:?\s?#{input}")
end

def truncate(string)
  if string.length > 250
    string = string[0,249] + '...'
  end
  string
end

# Cleans up a ticket's description by removing links, markdown headers and line breaks
def cleanup(string)
  string.gsub(/(?:\#{1,3}\s?|\(http:\/\/.*\))/, '').gsub(/\n/, ' ').strip
end

class Tickets
  include Cinch::Plugin

  $displayed_event_ids = []
  $lastChecked = Time.now

  def author_name(author)
    name = author['fullName'] || "Someone"

    name.capitalize.slice(/^\w+\s?/).strip
  end

  def card_url(activity)
    "https://trello.com/c/#{activity['data']['card']['shortLink']}"
  end

  def ticket_name(activity)
    activity['data']['card']['name']
  end

  def ticket_name_and_url(activity)
    card_id         = activity['data']['card']['idShort']
    name            = ticket_name(activity)

    "#{$irc['control']['bold']}#{name}#{$irc['control']['bold']} #{card_url(activity)}"
  end

  # TODO: should be split up into a fetch, filter and announce methods, which are testable.
  def parseActivities(board_id)
    params = { :filter => ['createCard','commentCard', 'updateCard', 'updateCard::closed'].join(',') }
    params[:since] = $lastChecked if $lastChecked

    # Change the board url here
    activities = fetch("https://api.trello.com/1/boards/#{board_id}/actions/", params)
    output = {}

    activities.reject! do |activity|
      already_displayed = $displayed_event_ids.include?(activity['id'])
      if already_displayed
        puts "Found duplicate activity " + activity['id']
      end
      already_displayed
    end

    activities.reverse.each do |activity|
      $displayed_event_ids.push(activity['id'])
      creator = author_name(activity['memberCreator'])
      activityData = activity['data']
      type = activity['type']

      case type
      when "createCard"
        action = "#{$irc['color']['red']}[" + $config['labels']['createCard'] + "]#{$irc['control']['color']} " + ticket_name_and_url(activity)
      when "updateCard"
        if activityData['card'] && activityData['card']['closed'] == true
          action = "#{$irc['color']['darkgreen']}[" + $config['labels']['closeCard'] + "]#{$irc['control']['color']} " + ticket_name_and_url(activity)
        elsif activityData['listAfter'] && activityData['listBefore']
          before = activityData['listBefore']['name']
          after = activityData['listAfter']['name']
          action = "#{$irc['color']['violet']}[" + $config['labels']['moveCard'] + "]#{$irc['control']['color']} \"#{ticket_name(activity)}\" from \"#{$irc['control']['bold']}#{before}#{$irc['control']['bold']}\" to \"#{$irc['control']['bold']}#{after}#{$irc['control']['bold']}\""
        elsif !(activityData['old'] && activityData['old'].keys == ["pos"])
          action = "#{$irc['color']['orange']}[" + $config['labels']['updateCard'] + "]#{$irc['control']['color']} #{$irc['control']['bold']}#{ticket_name(activity)}#{$irc['control']['bold']} #{card_url(activity)}"
        end
      when "commentCard"
        text = activityData['text']
        text.gsub!(/(\S)[^\S\n]*\n[^\S\n]*(\S)/, '\1 \2')
        if text.length > 150
          text.slice(0..150)
          action = "#{$irc['color']['orange']}[" + $config['labels']['commentCard'] + "]#{$irc['control']['color']} #{$irc['control']['bold']}#{creator}#{$irc['control']['bold']} said \"#{text} [...]\" on " + ticket_name_and_url(activity)
        else
          action = "#{$irc['color']['orange']}[" + $config['labels']['commentCard'] + "]#{$irc['control']['color']} #{$irc['control']['bold']}#{creator}#{$irc['control']['bold']} said \"#{text}\" on " + ticket_name_and_url(activity)
        end
      end

      if action.present?
        output[type] = [] unless output[type]
        output[type].push(action)
      end
    end
    output
  end

  def send_activities
    $config['teams'].each do |team|
      puts "Fetching for " + team['channel'].to_s
      message = ''

      [team['board_id']].flatten.each do |board_id|
        list_of_activities = parseActivities(board_id)

        unless list_of_activities == {}
          list_of_activities.each do |type, activities|
            message = activities.uniq.join("\n")
          end
        end
      end

      if message.present?
        message << "\n/cc #{team['scrum_master']}" if team['scrum_master']
        Channel(team['channel']).send(message)
        puts "posted activities to " + team['channel']
      end
    end
    $lastChecked = Time.now
  end

  timer $config['timer_in_seconds'].seconds, method: :send_activities
end
bot = Cinch::Bot.new do
  configure do |c|
    c.server = $config['irc']['server']
    c.nick = $config['irc']['nick']
    c.channels = $config['teams'].each.map { |team| [team['channel'], team['key']].join(' ')}
    c.port = $config['irc']['port']
    c.plugins.plugins = [Tickets]
    c.ssl.use = true if $config['irc']['ssl']
    c.password = $config['irc']['password'] if $config['irc']['password']
  end

  on :message, command('help') do |m|
    m.reply "OHAI fellas! I'll post new Trello tickets and comments on tickets to your magnificent channel. You can also request a ticket's description by typing '#{$config['nick']} getme 123'. If you want, you can add a 'scrum master' for your team to my config file, this person will receive a mention when a change occurs."
  end

  on :message, command('quit') do |m|
    m.reply "Quitting!"
    bot.quit
  end

  on :message, Regexp.new("(?:hey|hej|hello|ohai) #{$config['irc']['nick']}") do |m|
    m.reply "#{m.user.nick}: Hey!"
  end

  on :message, /(?:^| )cats(?: |$)/ do |m|
    sleep 5
    m.reply "Oh! I like cats!"
  end

  on :message, command("getme ([a-zA-Z].*$)") do |m, what|
    m.safe_reply "Silly #{m.user.nick}! I can't get #{what}! I can only get tickets!"
  end

  on :message, command("getme ([0-9]{1,5})") do |m, ticket_id|
    begin
      board_id = $config['teams'].select{|t| t['channel'] == m.channel.name}.first['board_id']
      card = fetch("https://api.trello.com/1/boards/#{board_id}/cards/#{ticket_id}")

      message = "#{card['name']} (#{card['closed'] ? 'closed' : 'open'}): #{cleanup(truncate(card['desc']))} - #{card['url']}"

    rescue
      message = "#{m.user.nick}: Couldn't retrieve the ticket, does it exist?"
    end

    m.safe_reply message
  end
end

bot.loggers.first.level = :warn
puts "Starting bot..."
bot.start
