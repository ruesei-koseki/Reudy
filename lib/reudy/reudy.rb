# Copyright (C) 2003 Gimite 市川 <gimite@mx12.freecom.ne.jp>
# Modified by Glass_saga <glass.saga@gmail.com>

require_relative 'wordset'
require_relative 'word_searcher'
require_relative 'message_log'
require_relative 'similar_searcher'
require_relative 'word_associator'
require_relative 'wtml_manager'
require_relative 'attention_decider'
require_relative 'response_estimator'
require_relative 'reudy_common'
require 'yaml'

unless Encoding.default_external == __ENCODING__
  STDOUT.set_encoding(Encoding.default_external, __ENCODING__)
  STDERR.set_encoding(Encoding.default_external, __ENCODING__)
  STDIN.set_encoding(Encoding.default_external, __ENCODING__)
end

module Gimite
  class Reudy
    include Gimite

    def initialize(dir, fixedSettings = {}, db = "pstore", mecab = nil)
      @attention = nil
      
      @brainSpaceMark = "=====brainSpace>>"

      # 設定を読み込む。
      @db = db # 使用するDBの名前
      if mecab
        begin
          require_relative 'tango_mecab' # 単語の抽出にmecabを使用する
        rescue => ex
          warn ex.message
          require_relative 'tango_mgm'
        end
      else
        require_relative 'tango_mgm'
      end
      @fixedSettings = fixedSettings
      @settingPath = dir + '/setting.yml'
      @settings = {}
      loadSettings
      @autoSave = !@settings[:disable_auto_saving]

      # 働き者のオブジェクト達を作る。
      @log = MessageLog.new(dir + '/log.yml')
      @log.addObserver(self)
      warn "ログロード終了"
      @wordSet = WordSet.new(dir + '/words.yml')
      @wordSearcher = WordSearcher.new(@wordSet)
      @wtmlManager = WordToMessageListManager.new(@wordSet, @log, @wordSearcher)
      @extractor = WordExtractor.new(14, method(:onAddWord))
      @simSearcher = SimilarSearcher.new(dir + '/db', @log, @db)
      @associator = WordAssociator.new(dir + '/assoc.txt')
      @attention = AttentionDecider.new
      @attention.setParameter(attentionParameters)
      @resEst = ResponseEstimator.new(@log, @wordSearcher, method(:isUsableBaseMsg), method(:canAdoptWord))
      warn "単語ロード終了"
      # その他インスタンス変数の初期化。
      @client = nil
      @lastSpeachInput = nil
      @lastSpeachOutput = nil
      @fromNick
      @inputWords = []
      @newInputWords = []
      @recentUnusedCt = 100 # 最近n個の発言は対象としない
      @repeatProofCt = 50 # 過去n発言で使ったベース発言は再利用しない
      @recentBaseMsgNs = Array.new(@repeatProofCt) # 最近使ったベース発言番号
      @thoughtFile = open(dir + "/thought.txt", "a") # 思考過程を記録するファイル
      @thoughtFile.sync = true
      @forget = 100000000

      setWordAdoptBorder
    end

    # 設定をファイルからロード
    def loadSettings
      File.open(@settingPath) do |file|
        @settings = YAML.load(file)
      end
      @settings.merge!(@fixedSettings)
      # メンバ変数を更新
      @targetNickReg = Regexp.new(@settings[:target_nick] || "", Regexp::IGNORECASE)
      # これにマッチしないNickの発言は、ベース発言として使用不能
      @forbiddenNickReg =
        if @settings[:forbidden_nick] && !@settings[:forbidden_nick].empty?
          Regexp.new(@settings[:forbidden_nick], Regexp::IGNORECASE)
        else
          /(?!)/o # 何にもマッチしない正規表現
        end
      @myNicks = @settings[:nicks] # これにマッチするNickの発言は、ベース発言として使用不能
      @my_nicks_regexp = Regexp.new(@myNicks.map { |n| Regexp.escape(n) }.join("|"))
      changeMode(@settings[:default_mode].to_i) # デフォルトのモードに変更
    end

    # チャットクライアントの指定
    attr_accessor :client, :settings

    # モードを変更
    def changeMode(mode)
      return false if mode == @mode
      @mode = mode
      @attention&.setParameter(attentionParameters)
      updateStatus
      true
    end

    def updateStatus
      @client.status = ["沈黙", "寡黙", nil, "饒舌"][@mode] if @client
    end

    # 注目判定器に与えるパラメータ。
    def attentionParameters
      case @mode
      when 0 # 沈黙モード。
        { \
          min: 0.001, \
          max: 0.001, \
          default: 0.001, \
          called: 0.001, \
          self: 0.0,   \
          ignored: 0.0    \
        }
      when 1 # 寡黙モード。
        { \
          min: 0.1, \
          max: 0.3, \
          default: 0.1, \
          called: 1.1, \
          self: 0.005, \
          ignored: 0.002 \
        }
      when 2 # 通常モード。
        { \
          min: 0.5, \
          max: 1.1, \
          default: 0.5, \
          called: 1.1, \
          self: 0.3, \
          ignored: 0.2 \
        }
      when 3 # 饒舌モード。
        { \
          min: 0.8, \
          max: 1.1, \
          default: 0.8, \
          called: 1.1, \
          self: 0.8, \
          ignored: 0.3  \
        }
      when 4 # 必ず応答するモード。
        { \
          min: 1.1, \
          max: 1.1, \
          default: 1.1, \
          called: 1.1, \
          self: 0.8, \
          ignored: 0.3  \
        }
      end
    end

    # 単語がこれより多く出現してたら置換などの対象にしない、という
    # ボーダを求めて@wordAdoptBorderに代入。
    def setWordAdoptBorder
      if @wordSet.words.empty?
        @wordAdoptBorder = 0
      else
        msgCts = @wordSet.words.map { |w| w.mids.size }
        msgCts.sort!
        msgCts.reverse!
        @wordAdoptBorder = msgCts[msgCts.size / 50]
      end
    end

    # その単語が置換などの対象になるか
    def canAdoptWord(word)
      word.mids.size < @wordAdoptBorder
    end

    # 発言をベース発言として使用可能か。
    def isUsableBaseMsg(msgN)
      size = @log.size
      return false if msgN >= size # 存在しない発言。
      msg = @log[msgN]
      return unless msg # 空行。削除された発言など。
      return false if !@settings[:teacher_mode] && size > @recentUnusedCt && msgN >= size - @recentUnusedCt # 発言が新しすぎる。（中の人モードでは無効）
      nick = msg.fromNick
      return false if nick == "!" # 自分自身の発言。
      return false if nick == "!input" # inputの発言。
      return false if nick !~ @targetNickReg || nick =~ @forbiddenNickReg # この発言者の発言は使えない。
      return false if @recentBaseMsgNs.include?(msgN) # 最近そのベース発言を使った。
      true
    end

    # mid番目の発言への返事（と思われる発言）について、[発言番号,返事らしさ]を返す。
    # ただし、ベース発言として使用できるものだけが対象。
    # 該当するものが無ければ[nil,0]を返す。
    def responseTo(mid, debug = false)
      return @resEst.responseTo(mid, debug) unless @settings[:teacher_mode]

      if isUsableBaseMsg(mid + 1) && @log[mid].fromNick == "!input"
        [mid + 1, 20]
      else
        [nil, 0]
      end
    end

    # 類似発言検索用のフィルタ
    def similarSearchFilter(msgN)
      !responseTo(msgN).first.nil?
    end

    # sentence中の自分のNickをtargetに置き換える。
    def replaceMyNicks(sentence, target)
      sentence.gsub(@my_nicks_regexp, target).gsub("@username", target).gsub("@botname", @settings[:real_name])
    end

    # 入力文章から既知単語を拾う。
    def pickUpInputWords(input)
      input = replaceMyNicks(input, " ")
      words = []
      @wordSearcher.searchWords(input).each do |w|
        words.push([w, true]) #[単語, 共通単語発言対象か]
      end
      @wordSearcher.searchWords(@fromNick).each do |w|
        words.push([w, false]) #[単語, 共通単語発言対象か]
      end
      @newInputWords = words.select { |w| canAdoptWord(w[0]) } # 入力に含まれる単語を列挙
      # 入力に単語が無い場合は、時々入力語をランダムに変更
      if @newInputWords.empty? && rand(50).zero?
        word = @wordSet.words.sample
        @newInputWords.push([word, true]) if canAdoptWord(word)
      end
      # 連想される単語を追加
      assoc_words = @newInputWords.map { |w| @associator.associate(w[0].str) }
      assoc_words.compact!
      assoc_words.map! { |s| Word.new(s) }
      words = []
      assoc_words.each do |w|
        words.push([w, true]) #[単語, 注目度]
      end
      @newInputWords.concat(words)
      # 入力語の更新
      return if @newInputWords.empty?
      




      if rand(5).nonzero?
        @inputWords.replace(@newInputWords)
      else
        @inputWords.concat(@newInputWords)
      end
    end

    # 「単語を除く文字数」から発言を採用するかを決める。
    # 「単語だけ」に等しい発言は採用されにくいようにする。
    # 単語が無い発言は確実に採用され、このメソッドは使われない。
    def shouldAdoptSaying(additionalLen)
      case additionalLen
      when 0
        false
      when 1
        rand < 0.125
      when 2, 3
        rand < 0.25
      when 4...7
        rand < 0.75
      else
        true
      end
    end

    # inputWords中の単語を含む各発言について、ブロックを繰り返す。
    # ブロックは発言番号を引数に取る。
    # 発言の順序はランダム。
    def eachMsgContainingWords(input_words)
      input_words.shuffle.each do |word|
        word[0].mids.shuffle.each do |mid|
          yield(mid)
        end
      end
    end

    # 共通の単語を持つ発言と、その返事の発言番号を返す。
    # 適切なものが無ければ、[nil, nil]。
    def getBaseMsgUsingKeyword(inputWords)
      words = []
      inputWords.each do |w|
        if w[1] == true
          words.push(words)
        end
      end
      maxMid = maxResMid = nil
      maxProb = 0
      i = 0
      eachMsgContainingWords(inputWords) do |mid|
        resMid, prob = responseTo(mid, true)
        if resMid
          if prob > maxProb
            maxMid = mid
            maxResMid = resMid
            maxProb = prob
          end
          i += 1
          break if i >= 5
        end
      end
      dprint("共通単語発言", @log[maxMid].body) if maxMid
      [maxMid, maxResMid]
    end

    # 類似発言と、その返事の発言番号を返す。
    # 適切なものが無ければ、[nil, nil]。
    def getBaseMsgUsingSimilarity(sentence)
      maxMid = maxResMid = nil
      maxProb = 0
      i = 0
      @simSearcher.eachSimilarMsg(sentence) do |mid|
        resMid, prob = responseTo(mid, true)
        if resMid
          if prob > maxProb
            maxMid = mid
            maxResMid = resMid
            maxProb = prob
          end
          i += 1
          break if i >= 5
        end
      end
      dprint("類似発言", @log[maxMid].body, maxProb) if maxMid
      [maxMid, maxResMid]
    end

    # msgN番の発言を使ったベース発言の文字列。
    def getBaseMsgStr(msg_n)
      str = @log[msg_n].body
      str.replace($1) if str =~ /^(.*)[＜＞]/ && $1.size >= str.size / 2 # 文の後半に[＜＞]が有れば、その後ろはカット。
      str
    end

    # base内の既知単語をnewWordsで置換したものを返す。
    # toForceがfalseの場合、短すぎる文章になってしまった場合はnilを返す。
    def replaceWords(base, new_words, toForce)
      words = []
      new_words.each do |w|
        if w[1] == true
          words.push(w[0])
        end
      end
      new_words = words
      # baseを単語の前後で分割してpartsにする。
      parts = [base]
      @wordSet.words.each do |word|
        next if word.str.empty?
        next unless @wordSearcher.hasWord(base, word) && canAdoptWord(word)
        newParts = []
        parts.each_with_index do |part, i|
          if (i % 2).zero?
            word_regexp = /^(.*?)#{Regexp.escape(word.str)}(.*)$/
            while part =~ word_regexp
              newParts.push($1, word.str)
              part = $2
            end
          end
          newParts.push(part)
        end
        parts = newParts
      end
      # 先頭から2番目以降の単語の直前でカットしたりしなかったり。
      wordCt = (parts.size - 1) / 2
      if parts.size > 1
        cutPos = rand(wordCt) * 2 + 1
        parts.replace(parts[cutPos..-1].unshift("")) if cutPos > 1
      end
      # 単語を除いた文章が短すぎるものはある確率で却下。
      if wordCt.nonzero? && !shouldAdoptSaying(sigma(0...parts.size) { |i| (i % 2).zero? ? parts[i].size : 0 })
        return nil
      end
      # 単語を置換。
      new_words.shuffle.each do |new_word|
        new_word_str = new_word.str
        old_word_str = parts[rand(wordCt) * 2 + 1]
        0.upto(wordCt - 1) do |j|
          parts[j * 2 + 1] = new_word_str if parts[j * 2 + 1] == old_word_str
        end
        break if rand < 0.5
      end
      output = parts.join
      # 閉じ括弧が残った場合に開き括弧を補う。
      # 入れ子になってたりしたら知らない。
      case output
      when /^[^「」]*」/
        output.replace("「#{output}")
      when /^[^（）]*）/
        output.replace("（#{output}")
      when /^[^()]*\)/
        output.replace("(#{output}")
      end
      output
    end

    # 自由発言の選び方を記録する。
    def recordThought(pattern, simMid, resMid, words, output)
      words_ = []
      words.each do |ws|
        words_.push(ws[0])
      end
      words = words_
      @thoughtFile.puts [@log.size - 1, pattern, simMid, resMid, words.map(&:str).join(","), output].join("\t")
    end

    # 自由に発言する。
    def speakFreely(fromNick, origInput, mustRespond)
      input = origInput
      return if input == nil || fromNick == nil
      @lastSpeachInput = origInput
      output = nil
      simMsgN, baseMsgN = getBaseMsgUsingSimilarity(input) # まず、類似性を使ってベース発言を求める。
      if !@newInputWords.empty?
        if baseMsgN
          output = replaceWords(getBaseMsgStr(baseMsgN), @inputWords, mustRespond)
          recordThought(1, simMsgN, baseMsgN, @newInputWords, output) if output
        else
          simMsgN, baseMsgN = getBaseMsgUsingKeyword(@newInputWords)
          output = getBaseMsgStr(baseMsgN) if baseMsgN
          recordThought(2, simMsgN, baseMsgN, @newInputWords, output) if output
        end
      elsif baseMsgN
        output = getBaseMsgStr(baseMsgN)
        unless @wordSearcher.searchWords(output).empty?
          output = mustRespond ? replaceWords(output, @inputWords, true) : nil
        end
        recordThought(3, simMsgN, baseMsgN, @inputWords, output) if output
      elsif mustRespond && !@inputWords.empty?
        simMsgN, baseMsgN = getBaseMsgUsingKeyword(@inputWords) # 最新でない入力語も使ってキーワード検索。
        output = getBaseMsgStr(baseMsgN) if baseMsgN
        recordThought(4, simMsgN, baseMsgN, @inputWords, output) if output
      end
      if mustRespond && !output
        log_size = @log.size
        2000.times do
          msgN = rand(log_size)
          next unless isUsableBaseMsg(msgN)
          baseMsgN = msgN
          output = getBaseMsgStr(baseMsgN)
          break
        end
      end
      return unless output


      if output == origInput
        return
      end

      # 最近使ったベース発言を更新
      @recentBaseMsgNs.shift
      @recentBaseMsgNs.push(baseMsgN)
      if output.scan("'").length == 1
        output = output.gsub("'", "")
      end
      output = replaceMyNicks(output, fromNick) # 発言中の自分のNickを相手のNickに変換
      output = output.split(@brainSpaceMark)
      output = output[0]
      speak(origInput, output) # 実際に発言。
    end

    # 自由発話として発言する。
    def speak(input, output)
      puts "#{@newInputWords}"
      puts "#{@inputWords}"
      @lastSpeachOutput = output
      studyMsg("!", output) # 自分の発言を記憶する。
      @client.outputInfo("「#{input}」に反応した。") if @settings[:teacher_mode]
      @attention.onSelfSpeak(@wordSearcher.searchWords(output))
      if output =~ /!command (.+)/ #チャンネル移動などのコマンド
        result = @client.command(output)
        speakFreely(@fromNick, @lastSpeach, true) if result == false #コマンドが無効なら発言する
      else
        @client.speak(output)
      end
    end

    # 定型コマンドを処理。
    # 入力が定型コマンドであれば応答メッセージを返す。
    # そうでなければnilを返す。ただし、終了コマンドだったら:exitを返す。
    def processCommand(input)
      if input =~ /設定を更新/
        loadSettings
        return "設定を更新しました。"
      end
      return nil if @settings[:disable_commands] # コマンドが禁止されている場合
      case input
      when /黙れ|黙りなさい|黙ってろ|沈黙モード/
        return changeMode(0) ? "沈黙モードに切り替える。" : ""
      when /寡黙モード/
        return changeMode(1) ? "寡黙モードに切り替える。" : ""
      when /通常モード/
        return changeMode(2) ? "通常モードに切り替える。" : ""
      when /饒舌モード/
        return changeMode(3) ? "饒舌モードに切り替える。" : ""
      when /休んで良いよ|終了しなさい/
        save
        @client.exit
        return :exit
      when /([\x21-\x7e]+)の(?:もの|モノ|物)(?:まね|真似)/ # 半角文字を抽出する正規表現
        begin
          @targetNickReg = Regexp.new($1, Regexp::IGNORECASE)
          return "#{$1}のものまねを開始する。"
        rescue RegexpError
          return "正規表現が間違っている。"
        end
      when /(?:もの|モノ|物)(?:まね|真似).*(?:解除|中止|終了|やめろ|やめて)/
        @targetNickReg = /(?!)/
        return "物まねを解除する。"
      end
      # 定型コマンドではない。
      return nil unless input =~ /覚えさせた|教わった/ && input.include?("誰") && input =~ /「(.+?)」/
      wordStr = $1
      if (wordIdx = @wordSet.words.index(Word.new(wordStr)))
        author = @wordSet.words[wordIdx].author
        if !author.empty?
          "#{author}さんに。＞#{wordStr}"
        else
          "不確定だ。＞#{wordStr}"
        end
      else
        "その単語は記憶していない。"
      end
    end

    # 通常の発言を学習。
    def studyMsg(fromNick, input)
      return if @settings[:disable_studying]
      if @settings[:teacher_mode]
        @fromNick = fromNick
        @extractor.processLine(input) # 単語の抽出のみ。
      else
        @log.addMsg(fromNick, input)
      end
    end

    # 学習内容を手動保存
    def save
      @wordSet.save
    end

    # ログに発言が追加された。
    def onAddMsg
      msg = @log[-1]
      @fromNick = msg.fromNick unless msg.fromNick == "!"
      @extractor.processLine(msg.body) unless @settings[:teacher_mode] # 中の人モードでは、単語の抽出は別にやる。
      # @extractor以外のオブジェクトは自力で@logを監視しているので、
      # ここで何かする必要は無い。
    end

    # ログがクリアされた。
    def onClearLog
    end

    # 単語が追加された
    def onAddWord(wordStr)
      return unless @wordSet.addWord(wordStr, @fromNick)

      if @client
        @client.outputInfo("単語「#{wordStr}」を記憶した。")
      else
        puts "単語「#{wordStr}」を記憶した。"
      end
      @wordSet.save if @autoSave
    end

    # 接続を開始した
    def onBeginConnecting
      warn "接続開始..."
    end

    # 自分が入室した
    def onSelfJoin
      updateStatus
    end

    # 他人が入室した
    def onOtherJoin(fromNick)
    end

    # 他人が発言した。
    def onOtherSpeak(from_nick, input, should_ignore = false)
      return if input == nil || from_nick == nil
      onAddWord(from_nick)
      @newInputWords << from_nick
      input = input.force_encoding(Encoding::UTF_8)
      called = @myNicks.any? { |n| input.include?(n) }
      output = called ? processCommand(input) : nil # 発言。
      if output
        @client.speak(output) if output != :exit && !output.empty?
      else # 定型コマンドではない。
        @lastSpeachInput = input
        pickUpInputWords(input)
        studyMsg(from_nick, input)
        fromNickData = @wordSet.words.select { |word| word.str == from_nick }
        prob = @attention.onOtherSpeak(from_nick, input, called)
        dprint("発言率", prob, @attention.to_s) # 発言率を求める。

        if input =~ /> (.+) => (.+)/
          @log.addMsg("!input", $1)
          @log.addMsg("!teacher", $2)
          @client&.outputInfo("反応「#{$1}→→#{$2}」を学習した。")
        elsif input =~ /> (.+)/
          onAddWord($1)
        end
        speakFreely(from_nick, input, prob > 1.0) if (!should_ignore && rand < prob) || prob > 1.0 # 自由発話。
      end
      onForget
    end

    # 他人が発言した。
    def onOtherSpeakDontReply(from_nick, input)
      return if input == nil || from_nick == nil
      onAddWord(from_nick)
      @newInputWords << from_nick
      input = input.force_encoding(Encoding::UTF_8)
      called = @myNicks.any? { |n| input.include?(n) }
      output = called ? processCommand(input) : nil # 発言。
      if output
        @client.speak(output) if output != :exit && !output.empty?
      else # 定型コマンドではない。
        @lastSpeachInput = input
        pickUpInputWords(input)
        studyMsg(from_nick, input)
        fromNickData = @wordSet.words.select { |word| word.str == from_nick }
        prob = @attention.onOtherSpeak(from_nick, input, called)
        dprint("発言率", prob, @attention.to_s) # 発言率を求める。

        if input =~ /> (.+) => (.+)/
          @log.addMsg("!input", $1)
          @log.addMsg("!teacher", $2)
          @client&.outputInfo("反応「#{$1}→→#{$2}」を学習した。")
        elsif input =~ /> (.+)/
          onAddWord($1)
        end
      end
      onForget
    end

    #チャンネル移動コマンドのタイミングを学習
    #Discordで呼び出されたとき、同じタイミングで同じチャンネルに行くように学習
    def onDiscMove(channelid, channelname, username)
      @log.addMsg(username, "!command disc_move #{channelid} #{channelname}")
    end

    def onForget
      if @log.size >= @forget
      	@log.deleteLead
      	@wordSet.deleteFix
      end
    end

    # 制御発言（infoでの発言）があった。
    def onControlMsg(str)
      str = str.force_encoding(Encoding::UTF_8)
      return if @settings[:disable_studying] || !@settings[:teacher_mode]
      if str =~ /^(.+) => (.+)$/
        input = $1
        output = $2
      elsif str =~ /^(.+) =>\R(.+)$/m
        input = $1
        output = $2
      elsif str =~ /^res (.+) for (.+)$/
        input = $2
        output = $1
      elsif str =~ /^res (.+)$/
        input = @lastSpeachInput
        output = $1
      elsif str =~ /^word (.+)$/
        onAddWord($1)
      else
        input = @lastSpeachInput
        output = str
      end
      if input
        @log.addMsg("!input", input)
        @log.addMsg("!teacher", output)
        @client&.outputInfo("反応「#{input}→→#{output}」を学習した。")
      end
    end

    # 沈黙がしばらく続いた。
    def onSilent
      prob = @attention.onSilent
      if rand < prob && @lastSpeachInput
        speakFreely(@fromNick, @lastSpeachInput, 1.1) # 自発発言。
        # 自発発言では、発言が無い限り、同じ発言を対象にしつづける。
        # このせいで全然しゃべらなくなるのを防ぐため、時々mustRespondをONにする。
      end
    end
    def myNicks
      @myNicks
    end
    def mode
      @mode
    end
  end
end
