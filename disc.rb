# Copyright (C) 2003 Gimite 市川 <gimite@mx12.freecom.ne.jp>
# Modified by Glass_saga <glass.saga@gmail.com>

require 'optparse'
require_relative 'lib/reudy/disc_client'
require_relative 'lib/reudy/reudy'

module Gimite
  STDOUT.sync = true
  STDERR.sync = true
  Thread.abort_on_exception = true

  opt = OptionParser.new

  directory = 'public'
  opt.on('-d DIRECTORY') { |v| directory = v }

  db = 'pstore'
  opt.on('--db DB_TYPE') { |v| db = v }

  mecab = true
  opt.on('-nm', '--nmecab') { mecab = nil }

  opt.parse!(ARGV)
  directory = ARGV.first unless ARGV.empty?

  begin
    # IRC用ロイディを作成
    client = DiscordBot.new(Reudy.new(directory, {}, db, mecab))
  rescue => e
    p e #=> RuntimeError
  end
end
