# Copyright (C) 2003 Gimite 市川 <gimite@mx12.freecom.ne.jp>
# Modified by Glass_saga <glass.saga@gmail.com>

require_relative 'reudy_common'

module Gimite
  # 単語クラス
  class Word
    def initialize(str, author = "", mids = [])
      @str = str # 単語の文字列。
      @author = author # 単語を教えた人。
      @mids = mids # この単語を含む発言の番号。
    end

    attr_accessor :str, :author, :mids

    def ==(other)
      @str == other.str
    end

    def eql?(other)
      @str == other.str
    end

    def hash
      @str.hash
    end

    def <=>(other)
      @str <=> other.str
    end

    def inspect
      "<Word: \"#{str}\">"
    end
  end

  # 単語集
  class WordSet
    include Enumerable
    include Gimite

    def initialize(filename)
      @filename = filename
      @added_words = []
      File.open(filename, File::RDONLY | File::CREAT) do |f|
        @words = YAML.load(f) || []
      end
    end

    attr_reader :words

    # 単語を追加
    def addWord(str, author = "")
      return nil if str.empty? && str != nil
      i = @words.find_index { |word| str.include?(word.str) }
      return nil if i && @words[i].str == str # 重複する単語があった場合

      word = Word.new(str, author)
      if i
        @words.insert(i, word)
      else
        @words.push(word)
      end
      @added_words.push(word)
      word
    end

    # ファイルに保存
    def save
      File.open(@filename, "w") do |f|
        YAML.dump(@words, f)
      end
    end

    # 単語イテレータ
    def each
      @words.each
    end

    def deleteFix
      i = 0
      @words.each do |word|
        ii = 0
        @words[i].mids.each do |mid|
        @words[i].mids[ii] -= 1
        @words[i].mids.delete_at(ii) if @words[i].mids[ii] < 1
        ii += 1
	end
	i += 1
      end
      save
    end

    # 中身をテキスト形式で出力。
    def output(io)
      @words.each do |word|
        io.puts "#{word.str}\t#{word.author}\t#{word.mids.join(',')}"
      end
    end

    private

    # 既存のファイルとかぶらないファイル名を作る。
    def makeNewFileName(base)
      return base unless File.exist?(base)
      i = 2
      loop do
        name = base + i.to_s
        return name unless File.exist?(name)
        i += 1
      end
    end
  end
end
