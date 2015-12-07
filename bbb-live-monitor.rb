# Set encoding to utf-8
# encoding: UTF-8

require 'rubygems'
require 'redis'
require 'json'
require 'nokogiri'
require 'digest/sha1'
require 'net/http'
require 'json'
require 'uri'

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

def read_salt
  properties = Hash[File.read('/var/lib/tomcat7/webapps/bigbluebutton/WEB-INF/classes/bigbluebutton.properties').scan(/(.+?)=(.+)/)]
  if properties.nil? or properties.empty?
    return nil
  else
    return properties["securitySalt"]
  end
end

def get_url(url)
  begin
    req = Net::HTTP::Get.new(url.to_s)
    res = Net::HTTP.start(url.host, url.port) { |http|
      http.request(req)
    }
    return res.body
  rescue
    return nil
  end
end

def get_meetings(salt)
  params = "random=#{rand(99999)}"
  checksum = Digest::SHA1.hexdigest "getMeetings#{params}#{salt}"
  url = URI.parse("http://localhost:8080/bigbluebutton/api/getMeetings?#{params}&checksum=#{checksum}")
  return get_url(url)
end

def get_meeting_info(meeting_id, salt)
  params = "meetingID=#{URI.escape(meeting_id)}&random=#{rand(99999)}"
  checksum = Digest::SHA1.hexdigest "getMeetingInfo#{params}#{salt}"
  url = URI.parse("http://localhost:8080/bigbluebutton/api/getMeetingInfo?#{params}&checksum=#{checksum}")
  return get_url(url)
end

def init
  salt = read_salt
  return if salt.nil?

  get_meetings_answer = get_meetings(salt)
  return if get_meetings_answer.nil?

  get_meetings_xml = Nokogiri::XML(get_meetings_answer)
  return if get_meetings_xml.at_xpath('/response/returncode').text != "SUCCESS"
  
  get_meetings_xml.xpath('/response/meetings/meeting').each do |meeting|
    meeting_id = meeting.at_xpath('meetingID').text
    meeting = {
      :users => {}
    }
    $meetings[meeting_id] = meeting

    get_meeting_info_answer = get_meeting_info(meeting_id, salt)
    next if get_meeting_info_answer.nil?

    get_meeting_info_xml = Nokogiri::XML(get_meeting_info_answer)
    return if get_meeting_info_xml.at_xpath('/response/returncode').text != "SUCCESS"
    
    get_meeting_info_xml.xpath('/response/attendees/attendee').each do |attendee|
      userid = attendee.at_xpath('userID').text
      user = {
        :listenOnly => attendee.at_xpath('isListeningOnly').text.downcase == 'true',
        :voiceUser => attendee.at_xpath('hasJoinedVoice').text.downcase == 'true',
        :videos => [],
        :bot => attendee.at_xpath('fullName').text.downcase.start_with?('bot')
      }
      attendee.xpath('videoStreams/streamName').each do |streamName|
        user[:videos] << streamName.text
      end
      $meetings[meeting_id][:users][userid] = user
    end
  end
  
  update_stats
end

def update_stats
  $stats[:num_meetings] = $meetings.length
  $stats[:num_users] = $meetings.inject(0) { |total, (k, v)| total + v[:users].length}
  $stats[:num_bots] = $meetings.inject(0) { |total, (k, v)| total + v[:users].values.select { |u| u[:bot] }.length }
  $stats[:num_voice_participants] = $meetings.inject(0) { |total, (k, v)| total + v[:users].values.select { |u| u[:voiceUser] }.length }
  $stats[:num_voice_listeners] = $meetings.inject(0) { |total, (k, v)| total + v[:users].values.select { |u| u[:listenOnly] }.length }
  $stats[:num_videos] = $meetings.inject(0) { |total, (k, v)| total + v[:users].inject(0) { |total, (k, v)| total + v[:videos].length}}
end

init

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

    update_stats
  end
end
