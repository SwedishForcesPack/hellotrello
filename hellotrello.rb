require 'cinch'
require 'net/http'
require 'open-uri'
require 'active_support/core_ext/object'
require 'yaml'

$config = YAML.load_file('config.yml')

def fetch(url, params = {})
  params = '?' + params.merge( $config['trello'] ).to_query
  url = url+ params
  body = open(url).read
  JSON.parse(body)
end

# Generates the Regexp pattern that's used for detecting incoming commands
def command(input)
  Regexp.new("#{$config['nick']}_?:?\s?#{input}")
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

  $lastChecked = Time.now

  def author(author)
    name = author['fullName'] || "Someone"

    name.capitalize.slice(/^\w+\s?/).strip
  end

  def parseActivities(board_id)
    params = {:filter => ['createCard','commentCard']}
    params[:since] = $lastChecked if $lastChecked

    # Change the board url here
    activities = fetch("https://api.trello.com/1/boards/#{board_id}/actions/", params)
    output = {}

    activities.each do |activity|
      creator = author(activity['memberCreator'])
      card_id = activity['data']['card']['idShort']
      name    = activity['data']['card']['name']
      url     = "https://trello.com/card/#{activity['data']['board']['id']}/#{activity['data']['card']['idShort']}"

      if activity['type'] == "createCard"
        action = 'added a new ticket to Trello:'
      else
        action = 'added a comment to the ticket'
      end

      output[creator] = "#{action} ##{card_id.to_s}: #{name} - #{url}"
    end

    output
  end


  timer 10.minutes, method: :send_activities

  def send_activities
    $config['teams'].each do |team|
      puts "Fetching for " + team['channel'].to_s
      list_of_activities = parseActivities(team['board_id'])

      if list_of_activities == {}
        puts "No new entries for " + team['channel'].to_s
      else
        list_of_activities.each do |author, activity|
          message = author + ' ' + activity
          message << " /cc #{team['scrum_master']}" if team['scrum_master'] && team['scrum_master'].downcase != author.downcase
          Channel(team['channel']).send(message)
          puts "posted message to " + team['channel']
        end
      end
    end

    $lastChecked = Time.now
  end
end

bot = Cinch::Bot.new do

  configure do |c|
    c.server = $config['irc']['server']
    c.nick = $config['irc']['nick']
    c.channels = $config['teams'].each.map{|c| c['channel']}
    c.port = $config['irc']['port']
    c.plugins.plugins = [Tickets]
  end

  on :message, command('help') do |m|
    m.reply "OHAI fellas! I'll post new Trello tickets and comments on tickets to your magnificent channel. You can also request a ticket's description by typing '#{$config['nick']} getme 123'. If you want, you can add a 'scrum master' for your team to my config file, this person will receive a mention when a change occurs."
  end

  on :message, Regexp.new("(?:hey|hej|hello|ohai) #{$config['irc']['nick']}") do |m|
    m.reply "#{m.user.nick}: Hey!"
  end

  on :message, "cats" do |m|
    sleep 5
    m.reply "Oh! I like cats!"
  end

  on :message, command("getme ([a-zA-Z].*$)") do |m, what|
    m.safe_reply "Silly #{m.user.nick}! He asked me to get #{what}. I can only get tickets!"
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

bot.start
