# Copyright (C) 2011 Glass_saga <glass.saga@gmail.com>

require 'sinatra'
require 'json'
require_relative 'lib/reudy/reudy'

class Lingr
  def initialize
    @message = ""
  end

  def speak(n)
    @message = n
  end

  attr_accessor :message
end

reudy = Gimite::Reudy.new("public")
lingr = Lingr.new
reudy.client = lingr

post '/' do
  content_type :text
  data = JSON.parse(params[:json])
  reudy.onOtherSpeak(data["events"][0]["message"]["nickname"], data["events"][0]["message"]["text"])
  return lingr.message
end
