$: << File.join(File.dirname(__FILE__), '..', '..', 'vendor', 'feed_me', 'lib')
$: << File.join(File.dirname(__FILE__), '..', '..', 'vendor', 'mechanical_github', 'lib')
require 'rubygems'
require 'open-uri'
require 'dm-core'
require 'feed_me'
require 'mechanical_github'
require 'set'

module Seinfeld
  # Some of this is destined to be broken out into modules when support for
  # more services than just github is added.
  class User
    class << self
      attr_accessor :github_login
      attr_accessor :github_password
    end

    include DataMapper::Resource
    property :id,                   Integer, :serial => true
    property :login,                String, :unique => true
    property :email,                String
    property :last_entry_id,        String
    property :current_streak,       Integer, :default => 0, :index => true
    property :longest_streak,       Integer, :default => 0, :index => true
    property :streak_start,         Date
    property :streak_end,           Date
    property :longest_streak_start, Date
    property :longest_streak_end,   Date
    has n, :progressions, :class_name => "Seinfeld::Progression", :order => [:created_at.desc]

    def self.paginated_each(&block)
      max_id = 0
      while batch = next_batch(max_id)
        batch.each(&block)
        max_id = batch.map { |u| u.id }.max
      end
    end

    def self.next_batch(id)
      batch = all :order => [:id], :limit => 15, :id.gt => id
      batch.size.zero? ? nil : batch
    end

    def self.best_current_streak 
      all :current_streak.gt => 0, :order => [:current_streak.desc, :login], :limit => 15
    end

    def self.best_alltime_streak 
      all :longest_streak.gt => 0, :order => [:longest_streak.desc, :login], :limit => 15
    end

    def update_progress
      transaction do
        days = committed_days_in_feed || []
        save
        unless days.empty?
          existing = progressions(:created_at => days).map { |p| p.created_at }
          streaks = [current_streak = Streak.new(streak_start, streak_end)]
          days = days - existing
          days.sort!
          days.each do |day|
            if current_streak.current?(day)
              current_streak.ended = day
            else
              streaks << (current_streak = Streak.new(day))
            end
            progressions.create(:created_at => day)
          end
          highest_streak      = streaks.empty? ? 0 : streaks.max { |a, b| a.days <=> b.days }
          latest_streak       = streaks.last
          self.streak_start   = latest_streak.started if latest_streak
          self.streak_end     = latest_streak.ended   if latest_streak
          self.current_streak = latest_streak.days    if latest_streak && latest_streak.current?

          if highest_streak.days > longest_streak.to_i
            self.longest_streak       = highest_streak.days
            self.longest_streak_start = highest_streak.started
            self.longest_streak_end   = highest_streak.ended
          end

          save
        end
      end
    end

    def committed_days_in_feed(page = 1)
      feed          = get_feed(page)
      return nil if feed.nil?
      entry_id      = nil # track the first entry id to store in the user model
      skipped_early = nil
      return nil if feed.entries.empty?
      days = feed.entries.inject({}) do |selected, entry|
        this_entry_id = entry.item_id
        entry_id    ||= this_entry_id
        if last_entry_id == this_entry_id
          skipped_early = true
          break selected
        end

        if entry.title.downcase =~ %r{^#{login.downcase} committed}
          updated = entry.updated_at
          date    = Date.civil(updated.year, updated.month, updated.day)
          selected.update date => nil
        else
          selected
        end
      end.keys
      if page == 1
        self.last_entry_id = entry_id 
        unless skipped_early
          while paged_days = committed_days_in_feed(page += 1)
            days += paged_days
          end
          days.uniq!
        end
      end
      days
    end

    def progress_for(year, month)
      start = Date.new(year, month)
      Set.new progressions(:created_at => start..((start >> 1) - 1)).map { |p| Date.new(p.created_at.year, p.created_at.month, p.created_at.day) }
    end

    def longest_streak_url
      "/~#{login}/#{longest_streak_start.year}/#{longest_streak_start.month}"
    end

    def self.process_new_github_user(subject)
      login_name = subject.scan(/([\w\_\-]+) sent you a message/).first.to_s
      return if login_name.size.zero?
      if user = first(:login => login_name)
        if github_login && github_password
          session = MechanicalGitHub::Session.new
          session.login github_login, github_password
          session.send_message login_name, "[CAN] You've already registered!", "Thanks for your enthusiasm, but you've already registered for a Calendar About Nothing: http://calendaraboutnothing.com/~#{user.login}."
        end
        nil
      else
        user = new(:login => login_name)
        yield user if block_given?
        user.update_progress
      end
    end

  private
    def get_feed(page = 1)
      feed = nil
      open("http://github.com/#{login}.atom?page=#{page}") { |f| feed = FeedMe.parse(f.read) }
      feed
    rescue
      nil
    end
  end

  class Progression
    include DataMapper::Resource
    property :id,         Integer, :serial => true
    property :created_at, Date
    belongs_to :user, :class_name => "Seinfeld::User"
  end

  class Streak
    attr_accessor :started, :ended

    def initialize(started = nil, ended = nil)
      @started = started
      @ended   = ended || started
    end

    def days
      if @started && @ended
        1 + (@ended - @started).to_i.abs
      else
        0
      end
    end

    def current?(date = Date.today)
      @ended && (@ended + 1) >= date
    end

    def include?(date)
      if @started && @ended
        @started <= date && @ended >= date
      else
        false
      end
    end

    def inspect
      %(#{@started ? ("#{@started.year}-#{@started.month}-#{@started.day}") : :nil}..#{@ended ? ("#{@ended.year}-#{@ended.month}-#{@ended.day}") : :nil}:Streak)
    end
  end
end
