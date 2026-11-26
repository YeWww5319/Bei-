import Foundation

/// 一首歌的高潮（副歌爆发段）区间，单位秒。
struct ClimaxInfo: Equatable {
    let start: Double
    let end: Double
}

/// 高潮位置估算 —— 纯本地推断，不联网、不依赖音频分析。
///
/// 优先级从高到低：
/// ① 精确表：人工核对过的热门歌副歌起点，最准，优先用；
/// ② 歌词副歌检测：副歌在歌词里必然成段重复，用重复段的首次出现当高潮；
/// ③ 兜底：流行歌副歌大多落在全曲约 1/3 处，长歌才启用，避免短音频乱标。
enum ClimaxEstimator {

    // MARK: - 精确表

    /// (歌名, 歌手, 高潮起点秒)。时间按录音室版核对，现场版/剪辑版会有出入。
    private static let curated: [(title: String, artist: String, start: Double)] = [
        ("可惜没如果", "林俊杰", 70),
        ("不为谁而作的歌", "林俊杰", 75),
        ("修炼爱情", "林俊杰", 65),
        ("背对背拥抱", "林俊杰", 60),
        ("江南", "林俊杰", 62),
        ("她说", "林俊杰", 58),
        ("晴天", "周杰伦", 60),
        ("夜曲", "周杰伦", 50),
        ("搁浅", "周杰伦", 80),
        ("最长的电影", "周杰伦", 70),
        ("七里香", "周杰伦", 66),
        ("青花瓷", "周杰伦", 55),
        ("告白气球", "周杰伦", 52),
    ]

    static func estimate(title: String, artist: String, lyrics: [LyricLine], duration: Double) -> ClimaxInfo? {
        // ① 精确表：时长未知时也能用（end 先按 start+35 给，画段时再按真实时长裁）
        if let hit = curatedMatch(title: title, artist: artist) {
            var end = hit + 35
            if duration > 0 {
                // 段尾不能顶到歌尾（最后 5 秒留给收尾），也不能短于起点
                end = max(hit, min(end, duration - 5))
            }
            return ClimaxInfo(start: hit, end: end)
        }

        // 时长未知时副歌检测和兜底都无从判断，直接放弃
        guard duration > 0 else { return nil }

        // ② 歌词副歌检测
        if let start = chorusStart(lyrics: lyrics, duration: duration) {
            return ClimaxInfo(start: start, end: min(start + 35, duration))
        }

        // ③ 兜底：只对长歌启用，短音频（<90s）结构不稳定，宁可不标
        guard duration >= 90 else { return nil }
        let start = duration * 0.32
        return ClimaxInfo(start: start, end: start + 30)
    }

    // MARK: - 精确表匹配

    private static func curatedMatch(title: String, artist: String) -> Double? {
        let t = normalizeName(title)
        let a = normalizeName(artist)
        guard !t.isEmpty else { return nil }
        for entry in curated where normalizeName(entry.title) == t {
            // 歌手只做包含匹配：音源常写「林俊杰 / JJ Lin」这类组合名，精确相等会漏
            let ea = normalizeName(entry.artist)
            if a.isEmpty || a.contains(ea) || ea.contains(a) {
                return entry.start
            }
        }
        return nil
    }

    /// 歌名/歌手归一化：去空白、去括号后缀（如「晴天 (Live)」）、统一小写。
    private static func normalizeName(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 括号后缀从第一个左括号处截断（中英文括号都算）
        if let idx = t.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            t = String(t[t.startIndex..<idx])
        }
        return t.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .lowercased()
    }

    // MARK: - 歌词副歌检测

    /// 找副歌首次出现的时间：某行在后面再次出现，且紧接着的下一行也跟着一起重复
    /// （连续两行成段重复）—— 单行重复太容易误命中（如语气词行），成段才算副歌。
    private static func chorusStart(lyrics: [LyricLine], duration: Double) -> Double? {
        let texts = lyrics.map { normalizeLyric($0.text) }
        guard lyrics.count >= 4 else { return nil }
        let lo = duration * 0.12
        let hi = duration * 0.70
        for i in 0..<(lyrics.count - 1) {
            let t = lyrics[i].time
            // 太早多半是主歌、太晚已是尾副歌，都不是要提示的「第一次高潮」
            guard t >= 20, t >= lo, t <= hi else { continue }
            guard !texts[i].isEmpty, !texts[i + 1].isEmpty else { continue }
            for j in (i + 1)..<(lyrics.count - 1) where texts[j] == texts[i] && texts[j + 1] == texts[i + 1] {
                return t
            }
        }
        return nil
    }

    /// 歌词行归一化：去空白与标点，只比正文，避免「，」有无造成同句对不上。
    private static func normalizeLyric(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .joined()
    }
}
