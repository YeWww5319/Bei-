import Foundation
import ActivityKit

/// 灵动岛 / 锁屏歌词（Live Activity）的 app 侧控制器。
///
/// 🔴 可用性隔离：主 app 部署目标是 iOS 15，而 ActivityKit 要 iOS 16.1+。
/// 本类本身不带 @available，iOS 15 的调用方（PlayerStore）可以直接引用；
/// 所有真正碰 Activity 的代码都收进 @available 标注的内部 Box，
/// 控制器只用 AnyObject 持有它，对外方法内部先 guard #available 再转发。
///
/// 同步策略（由 PlayerStore 在歌词换行 / 播放暂停时调用 sync）：
/// - 没有活动且当前行非空 → 启动；有活动 → 状态变了才 update；
/// - 切歌（title 变化）→ 结束旧活动、启动新活动；
/// - 暂停不结束活动，只把 isPlaying 更新成 false，岛上保留暂停态；
/// - stopAll 时调 endAll 彻底结束。
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    /// 持有 Activity 实例的盒子 —— Activity 泛型只出现在盒子内部。
    @available(iOS 16.1, *)
    private final class Box {
        var activity: Activity<AuroraLyricAttributes>?
    }

    private var boxObject: AnyObject?
    /// 上次已发送的状态：没变化就不发 update，避免每 0.25s 白刷一次。
    private var lastState: AuroraLyricAttributes.ContentState?
    /// 当前活动对应的歌名，用于识别切歌。
    private var activeTitle: String?

    @available(iOS 16.1, *)
    private var box: Box {
        if let existing = boxObject as? Box { return existing }
        let created = Box()
        boxObject = created
        return created
    }

    /// 同步一次歌词状态。line 为空（还没唱到第一行）时不启动新活动。
    func sync(title: String, artist: String, line: String, nextLine: String, isPlaying: Bool) {
        guard #available(iOS 16.1, *) else { return }
        guard !title.isEmpty, !line.isEmpty else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = AuroraLyricAttributes.ContentState(
            title: title, artist: artist, line: line,
            nextLine: nextLine, isPlaying: isPlaying)

        // 切歌：旧活动先结束，下面按无活动处理重新启动。
        if let activeTitle, activeTitle != title {
            endCurrentActivity(finalState: lastState)
        }

        guard state != lastState else { return }

        if let activity = box.activity {
            lastState = state
            Task { await Self.update(activity, with: state) }
        } else {
            let activity = Self.start(state: state)
            box.activity = activity
            if activity != nil {
                activeTitle = title
                lastState = state
            }
        }
    }

    /// 结束全部活动（停止播放 / 清空队列时调用）。
    func endAll() {
        guard #available(iOS 16.1, *) else { return }
        endCurrentActivity(finalState: lastState)
        boxObject = nil
        lastState = nil
        activeTitle = nil
    }

    @available(iOS 16.1, *)
    private func endCurrentActivity(finalState: AuroraLyricAttributes.ContentState?) {
        guard let activity = box.activity else { return }
        box.activity = nil
        activeTitle = nil
        lastState = nil
        Task { await Self.end(activity, with: finalState) }
    }

    // MARK: - Activity 操作（16.2+ 用 ActivityContent，16.1.x 用旧 contentState API）

    @available(iOS 16.1, *)
    private static func start(state: AuroraLyricAttributes.ContentState) -> Activity<AuroraLyricAttributes>? {
        let attributes = AuroraLyricAttributes()
        if #available(iOS 16.2, *) {
            return try? Activity.request(attributes: attributes,
                                         content: ActivityContent(state: state, staleDate: nil),
                                         pushType: nil)
        } else {
            return try? Activity.request(attributes: attributes,
                                         contentState: state,
                                         pushType: nil)
        }
    }

    @available(iOS 16.1, *)
    private static func update(_ activity: Activity<AuroraLyricAttributes>,
                               with state: AuroraLyricAttributes.ContentState) async {
        if #available(iOS 16.2, *) {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        } else {
            await activity.update(using: state)
        }
    }

    @available(iOS 16.1, *)
    private static func end(_ activity: Activity<AuroraLyricAttributes>,
                            with state: AuroraLyricAttributes.ContentState?) async {
        if #available(iOS 16.2, *) {
            if let state {
                await activity.end(ActivityContent(state: state, staleDate: nil),
                                   dismissalPolicy: .immediate)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        } else {
            await activity.end(dismissalPolicy: .immediate)
        }
    }
}
