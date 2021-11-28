# Copyright (C) 2003 Gimite 市川 <gimite@mx12.freecom.ne.jp>
# Modified by Glass_saga <glass.saga@gmail.com>

# 日本語文字コード判定用コメント

require 'optparse'
require_relative 'lib/reudy/bot_irc_client'
require_relative 'lib/reudy/reudy'
require_relative 'lib/reudy/reudy_common'

trap(:INT) { exit }

module Gimite
  class StdioClient
    include(Gimite)

    def initialize(user, yourNick)
      @user = user
      @user.client = self
      @yourNick = yourNick
      greeting = @user.settings["joining_message"]
      puts greeting if greeting
    end

    def loop
      STDIN.each_line do |line|
        line = line.chomp
        if line.empty?
          @user.onSilent
        elsif @yourNick
          @user.onOtherSpeak(@yourNick, line)
        elsif line =~ /^(.+?) (.*)$/
          @user.onOtherSpeak($1, $2)
        else
          $stderr.print("Error\n")
        end
      end
    end

    # 発言する
    def speak(s)
      puts "#{s}"
    end
    def command(s)
      return false
    end
  end

  opt = OptionParser.new

  directory = 'public'
  opt.on('-d DIRECTORY') do |v|
    directory = v
  end

  db = 'pstore'
  opt.on('--db DB_TYPE') do |v|
    db = v
  end

  nick = 'test'
  opt.on('-n nickname') do |v|
    nick = v
  end

  mecab = nil
  opt.on('-m', '--mecab') do
    mecab = true
  end

  opt.parse!(ARGV)

  STDOUT.sync = true
  client = StdioClient.new(Reudy.new(directory, {}, db, mecab), nick) # 標準入出力用ロイディを作成
  client.loop
end
