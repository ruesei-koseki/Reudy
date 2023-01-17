# Copyright (C) 2011 Glass_saga <glass.saga@gmail.com>

class WordExtractor
  # WordExtractor(単語候補リストを保持する長さ,単語追加時のコールバック)


  def initialize(_candlistlength = 7, onaddword = nil)
    @onAddWord = onaddword
  end

  # 文中で使われている単語を取得
  def extractWords(line, words = [])
    words |= line.split(" ") unless line.split(" ")[0] == line
    words |= line.split("　") unless line.split("　")[0] == line

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