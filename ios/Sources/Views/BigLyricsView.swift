import SwiftUI
import Dispatch

// MARK: - 全屏歌词页大字歌词流（2026-11-22 周日：从 PlayerView.swift 迁出）
//
// 🔴 为什么单独成文件：PlayerView.swift 已贴近 Swift 类型检查预算，
//    这里新增「上滑中心线放大 + 从这行播放」后体积更大，独立文件可避免
//    "unable to type-check this expression in reasonable time"。
//
// 原行为（保留）：LazyVStack 只渲染可见行；currentIndex 高亮当前演唱行；
//                 打开/切歌时把当前行滚到偏上 anchor(0.38)；点行跳播。
// 新行为（2026-11-22 日）：用户手动上滑歌词时，进入「选行」态 —— 离视口中心最近的
//                 那行放大加粗，旁边出现「从这行播放」按钮；点按钮从该行时间播放并
//                 恢复自动跟随；停止操作 3 秒后自动恢复自动跟随。

/// 每行在命名坐标空间里的 midY —— 用来找「离视口中心最近的行」。
private struct LyricRowFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 选行态的持有者：class + ObservableObject，避免 struct 捕获 self 写 @State 的时序问题。
/// 🔴 无锁：所有写入都在主线程（DragGesture / onPreferenceChange / timer 主线程回调）。
private final class LyricPickState: ObservableObject {
    @Published var isPicking = false
    @Published var pickedIndex: Int? = nil
    /// 🔴 2026-11-23(二)：点「从这行播放」后锁定的高亮行。
    ///    currentIndex 由播放进度驱动，seek 后要等真正唱到那行才更新（用户实测
    ///    「要等唱完才显示下一句高亮」）。锁定后该行立即放大高亮，直到 currentIndex
    ///    追上它才释放，过渡无跳变。
    @Published var lockedIndex: Int? = nil
    private var resumeWork: DispatchWorkItem?

    func begin() {
        // 🔴 DragGesture.onChanged 每帧都调，@Published 同值写入也会发 objectWillChange
        //    → 每次重算整个歌词列表 → 滑动抖动。只在首次进入选行态时写一次。
        if !isPicking { isPicking = true }
        scheduleResume()
    }

    func noteScroll() { scheduleResume() }

    func end() {
        resumeWork?.cancel()
        resumeWork = nil
        isPicking = false
        pickedIndex = nil
    }

    /// 点这行播放：锁定它为高亮行，退出选行态（lockedIndex 保留）。
    func lockAndEnd(_ idx: Int) {
        end()
        if lockedIndex != idx { lockedIndex = idx }
    }

    /// 播放进度**唱过**锁定行（进入下一行）→ 才释放锁定，交回 currentIndex 驱动。
    /// 🔴 2026-11-23(三)三轮根因：之前用 `current >= locked`，而 `seek(to:)` 里
    ///    `refreshLyric(at: target)` 会**同步**把 currentIndex 设成锁定行本身（current == locked），
    ///    onChange 立刻解锁；随后 AVPlayer 异步 seek 的观察器抖动又把 currentIndex 拉回旧行，
    ///    锁已没了 → 高亮回退，要等真正唱到那行才恢复（用户实测「唱完下一句才高亮」）。
    ///    改成严格 `>`：seek 到锁定行时 current == locked 不解锁，高亮稳稳停在点播的那行；
    ///    只有真正唱过它、currentIndex 进入下一行才交回进度驱动。
    func unlockIfReached(_ current: Int?) {
        guard let locked = lockedIndex, let current else { return }
        if current > locked { lockedIndex = nil }
    }

    private func scheduleResume() {
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isPicking = false
            self.pickedIndex = nil
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    deinit { resumeWork?.cancel() }
}

struct BigLyricsView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    var showsTranslation: Bool
    /// 🔴 let 不订阅：逐字填充交给子视图 / 时间驱动，本体不随 4fps 进度重建。
    let playback: PlaybackProgress
    var isPlaying: Bool
    /// 精确播放头（AVPlayer 实时值）。
    var liveTime: (() -> Double)? = nil
    /// 🔴 歌词字号（与「更多 → 歌词字号」共用同一个 AppStorage key）。
    @AppStorage(LyricsFontScale.key) private var lyricsFontScale: Double = 1.0
    /// 点击某行 → 从该行时间点开始播放。
    var onSeek: ((Double) -> Void)? = nil

    @StateObject private var pick = LyricPickState()
    /// 视口高度（GeometryReader 实测）—— 中心线 = height / 2。
    @State private var viewportHeight: CGFloat = 0
    /// 点「从这行播放」/点行跳播时，已经自己滚到目标行了，别让「退出选行态」的
    /// onChange 再滚回旧当前行（否则先跳回旧行、再随 seek 跳到新行，闪一下）。
    @State private var suppressResumeScroll = false

    private static let scrollSpace = "BigLyricsScroll"
    /// 高亮行往上挪一行（与旧版一致）。
    private static let activeAnchor = UnitPoint(x: 0.5, y: 0.38)

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .center, spacing: 26) {
                        if lyrics.isEmpty {
                            Text("纯音乐 · 暂无歌词")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.45))
                        } else {
                            ForEach(Array(lyrics.enumerated()), id: \.element.id) { idx, line in
                                lyricRow(idx: idx, line: line, proxy: proxy)
                            }
                        }
                    }
                    .padding(.vertical, 120)
                }
                // 行 frame 相对这个命名空间 = 相对视口；滚动时 midY 会跟着变。
                .coordinateSpace(name: Self.scrollSpace)
                .mask(LinearGradient(colors: [.clear, .black.opacity(0.85), .black, .black.opacity(0.85), .clear],
                                     startPoint: .top, endPoint: .bottom))
                // 用户手动拖动 → 进入选行态（simultaneous 不抢 ScrollView 自身的滚动）。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { _ in pick.begin() }
                )
                .onPreferenceChange(LyricRowFrameKey.self) { frames in
                    updatePicked(from: frames, height: viewportHeight)
                }
                .onAppear {
                    viewportHeight = outer.size.height
                    scrollToActive(proxy, animated: false)
                }
                .onChange(of: outer.size.height) { viewportHeight = $0 }
                .onChange(of: currentIndex) { new in
                    // 选行态里别自动回滚，否则用户一滑就被拉回当前行。
                    guard !pick.isPicking else { return }
                    // 🔴 2026-11-23(二)：播放进度追上锁定行才释放，高亮交回 currentIndex。
                    pick.unlockIfReached(new)
                    scrollToActive(proxy, animated: true)
                }
                .onChange(of: lyrics) { _ in
                    pick.end()
                    pick.lockedIndex = nil
                    scrollToActive(proxy, animated: false)
                }
                .onChange(of: pick.isPicking) { picking in
                    // 选行态结束：把（新的）当前演唱行滚回偏上位置。
                    if !picking {
                        if suppressResumeScroll {
                            suppressResumeScroll = false   // 已自己滚到目标行，跳过这次
                        } else {
                            scrollToActive(proxy, animated: true)
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: pick.pickedIndex)
    }

    // MARK: - 中心行检测

    private func updatePicked(from frames: [Int: CGFloat], height: CGFloat) {
        guard pick.isPicking, height > 0, !frames.isEmpty else { return }
        let center = height / 2
        var bestIdx: Int? = nil
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for (idx, midY) in frames {
            let d = abs(midY - center)
            if d < bestDist { bestDist = d; bestIdx = idx }
        }
        // 容差半个行高左右，避免回弹/空白时乱选；行距 26 + 行高约 40 → 相邻约 66pt。
        if let idx = bestIdx, bestDist < max(48, height * 0.18) {
            if pick.pickedIndex != idx { pick.pickedIndex = idx }
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy, animated: Bool) {
        // 🔴 2026-11-23(三)：锁定期间一律滚到锁定行，别被 seek 观察器抖动的 currentIndex 拉回旧行。
        let effective = pick.lockedIndex ?? currentIndex
        let id: UUID?
        if let idx = effective, lyrics.indices.contains(idx) {
            id = lyrics[idx].id
        } else {
            id = lyrics.first?.id
        }
        guard let id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(id, anchor: Self.activeAnchor) }
        } else {
            proxy.scrollTo(id, anchor: Self.activeAnchor)
        }
    }

    private func playFromHere(_ line: LyricLine, proxy: ScrollViewProxy) {
        // 🔴 先标记「自己会滚」再 end()，否则退出选行态的 onChange 会滚回旧当前行。
        if pick.isPicking { suppressResumeScroll = true }
        // 🔴 2026-11-23(三)：**先锁定再 seek**。onSeek 内部 refreshLyric(at:) 会同步更新
        //    currentIndex → 触发 onChange → unlockIfReached。若先 seek 后 lock，那次 onChange
        //    发生在 lock 之前（此时锁还没设，无妨），但随后异步 seek 完成回调里又 refreshLyric
        //    一次，可能晚于 lock 到达 → 用 current == locked 误解锁。先 lock 更稳。
        guard let idx = lyrics.firstIndex(where: { $0.id == line.id }) else {
            pick.end()
            onSeek?(line.time)
            Haptics.light()
            return
        }
        pick.lockAndEnd(idx)
        onSeek?(line.time)
        Haptics.light()
        let target = lyrics[idx].id
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(target, anchor: Self.activeAnchor)
        }
    }

    // MARK: - 单行

    private func lyricRow(idx: Int, line: LyricLine, proxy: ScrollViewProxy) -> some View {
        // 🔴 2026-11-23(二)：锁定行优先于 currentIndex —— 点这行播放立刻放大高亮。
        let activeIdx = pick.lockedIndex ?? currentIndex
        let isActive = activeIdx == idx
        let isLocked = pick.lockedIndex == idx        // 点这行播放后立即放大高亮的那一行
        let isNear = activeIdx != nil && abs(idx - activeIdx!) <= 1
        let isPicked = pick.isPicking && pick.pickedIndex == idx
        let scale = CGFloat(max(0.6, min(1.6, lyricsFontScale)))

        // 🔴 2026-11-23(一)：酷狗「滑块播放」样式 —— 中心行整行是一条半透明横条：
        //    左边显示该行时间戳（如 2:25）、中间放大歌词、右边一个播放三角 ▶；
        //    点整条即从该行播放。不再用之前那个 Capsule「从这行播放」按钮。
        let pickedBar = ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(AppStyle.accent.opacity(0.28))
            HStack(spacing: 8) {
                Text(line.time.clockString)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, alignment: .leading)
                    .fixedSize()

                Text(line.text)
                    // 🔴 2026-11-23(四)：滑动选中的歌词字号改成和播放时高亮行完全一致
                    //    （此前是 activeBase+3=25pt semibold，比播放高亮的 22pt bold 大一号）。
                    .font(.system(size: LyricsFontScale.activeBase * scale,
                                  weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .center)

                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 34, alignment: .trailing)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .center)

        return VStack(spacing: 4) {
            if isPicked {
                pickedBar
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Text(line.text)
                    .font(.system(size: textSize(isActive: isActive, isPicked: isLocked) * scale,
                                  weight: isActive ? .bold : .medium))
                    .foregroundStyle(textColor(isActive: isActive, isPicked: isLocked, isNear: isNear))
                    .multilineTextAlignment(.center)
            }

            if showsTranslation, let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: (isActive || isPicked ? LyricsFontScale.translationActiveBase
                                                : LyricsFontScale.translationInactiveBase) * scale))
                    .foregroundStyle((isActive || isPicked) ? .white.opacity(0.78) : .white.opacity(0.3))
                    .multilineTextAlignment(.center)
            }
        }
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .center)
        // 把本行 midY 报给外层，用于找中心线。
        .background(
            GeometryReader { g in
                Color.clear.preference(
                    key: LyricRowFrameKey.self,
                    value: [idx: g.frame(in: .named(Self.scrollSpace)).midY]
                )
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard onSeek != nil else { return }
            // 🔴 2026-11-23(一)：选行态点整条高亮条（含时间/三角）→ 走 playFromHere
            //    （seek + 自己滚到目标行 + Haptics）；非选行态点行 → 保持原来的直接跳播。
            if pick.isPicking {
                playFromHere(line, proxy: proxy)
            } else {
                // 🔴 2026-11-23(二)：非选行态点行也锁定该行，立刻放大高亮（不等唱到）。
                //    同样先锁后 seek（见 playFromHere 注释）。
                if let idx = lyrics.firstIndex(where: { $0.id == line.id }) {
                    pick.lockAndEnd(idx)
                }
                onSeek?(line.time)
                Haptics.light()
            }
        }
        .id(line.id)
    }

    private func textSize(isActive: Bool, isPicked: Bool) -> CGFloat {
        if isPicked { return LyricsFontScale.activeBase + 5 }   // 中心行再放大一档
        if isActive { return LyricsFontScale.activeBase }
        return LyricsFontScale.inactiveBase
    }

    private func textColor(isActive: Bool, isPicked: Bool, isNear: Bool) -> Color {
        if isPicked || isActive { return .white }
        if pick.isPicking { return .white.opacity(0.2) }        // 选行态其它行更暗，突出中心行
        return .white.opacity(isNear ? 0.45 : 0.28)
    }
}
