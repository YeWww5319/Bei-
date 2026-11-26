import Foundation
import ActivityKit

/// 灵动岛 / 锁屏歌词的 Live Activity 属性定义。
///
/// 🔴 本文件被两个 target 共用：主 app（AuroraMusic，负责启动/更新/结束活动）
/// 和 widget 扩展（AuroraWidgets，负责灵动岛与锁屏的 UI 渲染）。
/// 两边必须用同一份定义，Activity 才能正确匹配，所以放在 Shared 目录，
/// project.yml 里两个 target 的 sources 都包含它，不要在别处复制一份。
///
/// 歌名/歌手/歌词行都放在 ContentState（动态内容）而不是静态属性里：
/// 切歌时控制器会结束旧活动再开新的，状态里带全量信息，更新时不用区分来源。
struct AuroraLyricAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 歌名（展示用，已去 .mp3 等后缀）
        var title: String
        /// 歌手
        var artist: String
        /// 当前歌词行
        var line: String
        /// 下一歌词行（空字符串 = 没有下一行）
        var nextLine: String
        /// 是否正在播放（false = 暂停态，岛上显示暂停图标）
        var isPlaying: Bool
    }
}
