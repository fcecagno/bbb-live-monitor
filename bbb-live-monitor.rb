# Set encoding to utf-8
# encoding: UTF-8

require 'rubygems'
require 'redis'
require 'json'

$redis = Redis.new(:timeout => 0)
$meetings = {}
$stats = {
  :num_meetings => 0,
  :num_users => 0,
  :num_bots => 0,
  :num_voice_participants => 0,
  :num_voice_listeners => 0,
  :num_videos => 0,
  :desktop_sharing => false,
}

STDOUT.sync = true

puts "date,num_meetings,num_users,num_bots,num_voice_participants,num_voice_listeners,num_videos"
Thread.new do
  while true do
    puts "#{Time.now.strftime('%d-%m %T')},#{$stats[:num_meetings]},#{$stats[:num_users]},#{$stats[:num_bots]},#{$stats[:num_voice_participants]},#{$stats[:num_voice_listeners]},#{$stats[:num_videos]}"
    sleep 1
  end
end

$redis.subscribe('bigbluebutton:from-bbb-apps:meeting', 'bigbluebutton:from-bbb-apps:users') do |on|
  on.message do |channel, msg|
    data = JSON.parse(msg)
    type = data['header']['name']
    case type
    when "meeting_created_message"
      meeting_id = data['payload']['meeting_id']
      if not $meetings.has_key?(meeting_id)
        meeting = {
          :users => {}
        }
        $meetings[meeting_id] = meeting
      end
    when "meeting_destroyed_event"
      meeting_id = data['payload']['meeting_id']
      if $meetings.has_key?(meeting_id)
        $meetings.delete(meeting_id)
      end
    when "user_joined_message"
      meeting_id = data['payload']['meeting_id']
      userid = data['payload']['user']['userid']
      if $meetings.has_key?(meeting_id) and not $meetings[meeting_id][:users].has_key?(userid)
        user = {
          :listenOnly => data['payload']['user']['listenOnly'],
          :voiceUser => data['payload']['user']['voiceUser']['joined'],
          :videos => [],
          :bot => data['payload']['user']['name'].downcase.start_with?('bot')
        }
        $meetings[meeting_id][:users][userid] = user
      end
    when "user_left_message"
      meeting_id = data['payload']['meeting_id']
      userid = data['payload']['user']['userid']
      if $meetings.has_key?(meeting_id) and $meetings[meeting_id][:users].has_key?(userid)
        $meetings[meeting_id][:users].delete(userid)
      end
    when "user_listening_only"
      meeting_id = data['payload']['meeting_id']
      userid = data['payload']['userid']
      if $meetings.has_key?(meeting_id) and $meetings[meeting_id][:users].has_key?(userid)
        $meetings[meeting_id][:users][userid][:listenOnly] = data['payload']['listen_only']
      end
    when "user_joined_voice_message", "user_left_voice_message"
      meeting_id = data['payload']['meeting_id']
      userid = data['payload']['user']['userid']
      if $meetings.has_key?(meeting_id) and $meetings[meeting_id][:users].has_key?(userid)
        $meetings[meeting_id][:users][userid][:voiceUser] = data['payload']['user']['voiceUser']['joined']
      end
    when "user_shared_webcam_message", "user_unshared_webcam_message"
      meeting_id = data['payload']['meeting_id']
      userid = data['payload']['userid']
      if $meetings.has_key?(meeting_id) and $meetings[meeting_id][:users].has_key?(userid)
        $meetings[meeting_id][:users][userid][:videos] = data['payload']['stream'].split(',')
      end
    end

    $stats[:num_meetings] = $meetings.length
    $stats[:num_users] = $meetings.inject(0) { |total, (k, v)| total + v[:users].length}
    $stats[:num_bots] = $meetings.inject(0) { |total, (k, v)| total + v[:users].values.select { |u| u[:bot] }.length }
    $stats[:num_voice_participants] = $meetings.inject(0) { |total, (k, v)| total + v[:users].values.select { |u| u[:voiceUser] }.length }
    $stats[:num_voice_listeners] = $meetings.inject(0) { |total, (k, v)| total + v[:users].values.select { |u| u[:listenOnly] }.length }
    $stats[:num_videos] = $meetings.inject(0) { |total, (k, v)| total + v[:users].inject(0) { |total, (k, v)| total + v[:videos].length}}
  end
end
