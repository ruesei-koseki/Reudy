# Copyright (C) 2011 Glass_saga <glass.saga@gmail.com>

require 'mecab'

class WordExtractor
  # WordExtractor(単語候補リストを保持する長さ,単語追加時のコールバック)

  POS_ID = [38, 41, 42, 43, 44, 45, 46, 47].freeze # 単語として扱う品詞リスト

  def initialize(_candlistlength = 7, onaddword = nil)
    @onAddWord = onaddword
    @m = MeCab::Tagger.new
  end

  # 文中で使われている単語を取得
  def extractWords(line, words = [])
    n = @m.parseToNode(line)

    while (n = n.next)
      words << n.surface.force_encoding(Encoding::UTF_8) if !n.surface.empty? && POS_ID.include?(n.posid)
    end

    if @onAddWord
      words.each do |w|
        @onAddWord.call(w)
      end
    end

    words
  end

  # 単語取得・単語候補リスト更新を1行分処理する
  def processLine(line)
    words = extractWords(line)
    words
  end
end
