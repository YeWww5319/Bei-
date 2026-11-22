import SwiftUI

/// 2026-11-20：播放器动作行「音源」按钮弹出的半屏音源面板。
///
/// 需求：点击弹出弹窗显示音源，可对音源开关、调整顺序。
/// 复用 `SourceStore.setEnabled` / `reorder`，数据与实际解析优先级完全一致。
/// 🔴 2026-11-21：嵌在 `CompactPanelOverlay` 里，横条/背景/圆角由外层统一提供；
///    列表高度按音源行数自适应。深色模式跟随 App 主题（去掉强制浅色）。
/// 🔴 2026-11-21（二）：右上角「排序」改成「检测音源」按钮（重新体检全部音源），
///    底部优先级说明按用户要求移除。
/// 🔴 2026-11-22：排序改成「长按行直接拖动」——不再要「排序/完成」按钮；仅把顶栏行高度加大一点，其余尺寸沿用旧版。
/// 🔴 2026-11-22（二）：修左右边距（ScrollView 无 List 自带 inset）；
///    拖动状态拆到每行独立视图 → 每帧只有被拖的那行重算，父视图只在跨行时更新插入线，根治卡顿。
struct SourcePickerSheet: View {
    @ObservedObject private var store = SourceStore.shared
    @State private var isChecking = false
    let onDismiss: () -> Void

    /// 每行高度（含分隔线），既是视觉高度也是拖动换算行距的标尺。
    private let rowHeight: CGFloat = 60

    // MARK: 长按拖动排序状态（父视图只持有跨行才变的量）
    /// 只用 id 保存顺序；行内容一律从 store 按 id 实时取，避免状态不同步。
    @State private var orderedIDs: [String] = []
    /// 正在拖动的行 id（nil = 未在拖动）。
    @State private var draggingID: String?
    /// 插入指示线目标下标（-1 = 不显示）。
    @State private var insertionIndex: Int = -1

    var body: some View {
        VStack(spacing: 0) {
            // 顶部拖拽指示条（点击也能关闭）——恢复旧版尺寸
            Button { onDismiss() } label: {
                Capsule()
                    .fill(AppStyle.stroke)
                    .frame(width: 38, height: 5)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // 顶栏：字号/间距沿用旧版，🔴 仅把这一行的高度加大一点（上下各 12pt）
            HStack {
                Text("音源")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppStyle.primaryText)
                Spacer(minLength: 8)
                if !store.sources.isEmpty {
                    Button {
                        guard !isChecking else { return }
                        isChecking = true
                        Task {
                            await SourceHealth.shared.checkAll()
                            await MainActor.run { isChecking = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isChecking {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 13, height: 13)
                            }
                            Text(isChecking ? "检测中" : "检测音源")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(AppStyle.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isChecking)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // 列表：长按某行即可拖动排序（松手提交）
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(orderedIDs.enumerated()), id: \.element) { index, id in
                        sourceRow(id: id, index: index)
                    }
                }
                // 🔴 2026-11-22：ScrollView 不像 List 自带 inset，手动补 16pt 左右边距
                .padding(.horizontal, 16)
            }
            .compatScrollContentBackground(.hidden)
            // 🔴 高度贴合内容：行数 × 行高（最多给 6 行，再多交给面板整体高度）
            .frame(height: min(CGFloat(max(1, store.sources.count)) * rowHeight + 8, rowHeight * 6 + 8))
        }
        // 🔴 背景透明，交给外层面板按深浅模式绘制。
        .background(Color.clear)
        .onAppear { syncOrderFromStore(force: true) }
        // store 里增删音源时同步本地顺序（拖动中不同步，避免打断手势）
        .onReceive(store.$sources) { _ in
            syncOrderFromStore(force: false)
        }
    }

    // MARK: - 顺序同步

    /// 以 store.sources 的顺序为准同步 orderedIDs。
    /// - force：首次出现强制重建。
    /// - 非强制时：拖动中不动；已存在的 id 保持当前顺序，仅补齐新增/移除的 id。
    private func syncOrderFromStore(force: Bool) {
        guard draggingID == nil || force else { return }
        let ids = store.sources.map(\.id)
        if force {
            orderedIDs = ids
            return
        }
        let valid = Set(ids)
        var merged = orderedIDs.filter { valid.contains($0) }
        for id in ids where !merged.contains(id) { merged.append(id) }
        if merged != orderedIDs { orderedIDs = merged }
    }

    // MARK: - 行

    @ViewBuilder
    private func sourceRow(id: String, index: Int) -> some View {
        if let source = store.sources.first(where: { $0.id == id }) {
            SourcePickerRowView(
                source: source,
                index: index,
                totalCount: orderedIDs.count,
                rowHeight: rowHeight,
                showInsertLine: draggingID != nil && draggingID != id && insertionIndex == index,
                onDragStart: { draggingID = $0; insertionIndex = index },
                onDragMove: { insertionIndex = $0 },
                onDragEnd: { finishDrag() },
                onToggle: { store.setEnabled(!source.enabled, id: source.id) }
            )
        }
    }

    /// 松手：按插入线位置把行移到目标下标，整体重排后一次性写回 store。
    private func finishDrag() {
        defer {
            draggingID = nil
            insertionIndex = -1
        }
        guard let id = draggingID,
              let from = orderedIDs.firstIndex(of: id),
              insertionIndex >= 0, insertionIndex != from else { return }

        var ids = orderedIDs
        let moved = ids.remove(at: from)
        ids.insert(moved, at: insertionIndex)
        orderedIDs = ids

        let ordered = ids.compactMap { sid in store.sources.first { $0.id == sid } }
        if ordered.count == store.sources.count {
            store.reorder(ordered)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// 单个音源行：把拖动状态（dragOffset / isDragging）放在这里，
/// 每帧拖动只重算这一行；父视图只在跨行时收到一次 `onDragMove`。
/// 🔴 2026-11-22（三）：拖动手势只挂在左侧「把手」上，不再吞整行的触摸 ——
///    否则滚动列表和点开关都被手势抢走（用户反馈「不能上滑、开关点不动」）。
private struct SourcePickerRowView: View {
    let source: ThirdPartySource
    let index: Int
    let totalCount: Int
    let rowHeight: CGFloat
    let showInsertLine: Bool
    let onDragStart: (String) -> Void
    let onDragMove: (Int) -> Void
    let onDragEnd: () -> Void
    let onToggle: () -> Void

    @ObservedObject private var health = SourceHealth.shared
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    /// 已上报给父视图的目标下标，避免每帧重复回调触发父视图重算。
    @State private var reportedTarget = -1

    var body: some View {
        HStack(spacing: 10) {
            // 🔴 拖拽把手：只有这一小块区域挂长按手势，不吞列表滚动 / 开关点击。
            dragHandle
            healthDot
            VStack(alignment: .leading, spacing: 3) {
                Text(source.isBundled ? "默认音源" : source.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppStyle.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(AppStyle.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .tint(AppStyle.accent)
        }
        .padding(.vertical, 4)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDragging ? AppStyle.accent.opacity(0.14) : Color.clear)
        )
        .overlay(alignment: .top) {
            // 插入指示线：不占高度，避免布局跳动
            if showInsertLine {
                Rectangle()
                    .fill(AppStyle.accent)
                    .frame(height: 2)
            }
        }
        .offset(y: isDragging ? dragOffset : 0)
        .scaleEffect(isDragging ? 1.02 : 1)
        .zIndex(isDragging ? 10 : 0)
    }

    /// 左侧拖拽把手（三条横线），长按 0.25s 进入拖动。
    /// 手势只作用在这 24pt 宽的区域，列表其余部分照常滚动 / 点开关。
    private var dragHandle: some View {
        VStack(spacing: 3) {
            ForEach(0..<3) { _ in
                Capsule()
                    .fill(AppStyle.tertiaryText.opacity(0.55))
                    .frame(width: 14, height: 2)
            }
        }
        .frame(width: 24, height: 40)
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    switch value {
                    case .first(true):
                        isDragging = true
                        dragOffset = 0
                        reportedTarget = index
                        onDragStart(source.id)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    case .second(true, let drag):
                        guard let drag = drag else { return }
                        dragOffset = drag.translation.height
                        let steps = Int((dragOffset / rowHeight).rounded())
                        let target = min(max(index + steps, 0), max(totalCount - 1, 0))
                        if target != reportedTarget {
                            reportedTarget = target
                            onDragMove(target)
                        }
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    guard isDragging else { return }
                    isDragging = false
                    dragOffset = 0
                    onDragEnd()
                }
        )
    }

    @ViewBuilder
    private var healthDot: some View {
        switch health.status(for: source.id) {
        case .ok:
            Circle().fill(Color.green).frame(width: 9, height: 9)
        case .bad:
            Circle().fill(Color.red).frame(width: 9, height: 9)
        case .checking:
            ProgressView().scaleEffect(0.6).frame(width: 9, height: 9).tint(AppStyle.tertiaryText)
        case .unknown:
            Color.clear.frame(width: 9, height: 9)
        }
    }

    private var detail: String {
        let support = source.supportedQualityLabels
        let supportText = support.isEmpty ? "默认 \(source.quality)" : "支持 \(support.joined(separator: "·"))"
        if source.isScript { return "JS 脚本 · \(supportText)" }
        let host = URL(string: source.template)?.host ?? "地址无效"
        return "\(host) · \(supportText)"
    }
}
