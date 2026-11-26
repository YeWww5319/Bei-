import SwiftUI
import WidgetKit
import ActivityKit

/// 灵动岛 / 锁屏歌词扩展：只承载 Live Activity 的 UI，不含普通小组件。
/// 数据由主 app 通过 LiveActivityController 推送（见 AuroraLyricAttributes）。
@main
struct AuroraWidgets: WidgetBundle {
    var body: some Widget {
        AuroraLyricActivity()
    }
}

struct AuroraLyricActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AuroraLyricAttributes.self) { context in
            // 锁屏 / 横幅形态
            LockScreenLyricView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开形态
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 3) {
                        Text(context.state.line)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)
                        if !context.state.nextLine.isEmpty {
                            Text(context.state.nextLine)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// 锁屏歌词条：左图标 + 歌名/当前行/下一行 + 右侧播放状态。
private struct LockScreenLyricView: View {
    let state: AuroraLyricAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.9))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Text(state.line)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !state.nextLine.isEmpty {
                    Text(state.nextLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
