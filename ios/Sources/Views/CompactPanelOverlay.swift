import SwiftUI

/// 🔴 2026-11-21：音质 / 音源 的「贴合内容高度」底部面板。
///
/// 背景：iOS 15 的 `.sheet` 容器恒为整屏、且背景不透明（白底），
/// 叠上半透明遮罩就成了「大片灰白」（用户连续反馈）。所以这两个弹窗
/// 🔴 2026-11-21（二）改用 `.overlay` 挂在播放页上（同主题选择器已有模式），
/// 半透明/透明层直接盖在播放页上，不再有 sheet 白底。
///
/// 视觉（用户要求）：
/// - 上面：完全透明，露出播放页原样，不再有灰白遮罩；点面板外关闭。
/// - 下面：卡片背景（AppStyle.surface）一直铺到屏幕底，home indicator 区与弹窗同色。
///
/// 深浅色：面板背景用 `AppStyle.surface`（dynamic），深色模式自动变深色卡片。
///
/// 🔴 2026-11-22：新增「顶部抓取区下滑关闭」——只在卡片顶部 topGrabHeight 内开始的下滑
///    才响应（用 startLocation 判定 + simultaneousGesture），不干扰列表滚动与音源长按排序。
struct CompactPanelOverlay<Content: View>: View {
    let onDismiss: () -> Void
    let content: Content

    /// 顶部可下拉关闭的区域高度（覆盖横条 + 标题行）。列表区在此之下，不受手势影响。
    private let topGrabHeight: CGFloat = 90
    /// 下拉超过该距离即关闭，否则回弹。
    private let dismissThreshold: CGFloat = 90
    /// 卡片实时下拉位移。
    @State private var panelOffset: CGFloat = 0

    /// 底部安全区高度（home indicator），从 key window 读，兜底 34pt。
    private static var bottomInset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let win = ws.windows.first(where: { $0.isKeyWindow }) {
                return max(8, win.safeAreaInsets.bottom)
            }
        }
        return 34
    }

    init(onDismiss: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 🔴 上方：完全透明，露出播放页，不再有灰白遮罩；
            //    Color.clear 不参与命中，用 contentShape 兜住点击关闭。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            // 内容卡片：高度完全由内容决定，只圆上方两角、底部贴屏幕底
            VStack(spacing: 0) {
                content
                // home indicator 安全区留白（铺卡片色，和弹窗一体）
                Color.clear.frame(height: Self.bottomInset)
            }
            .frame(maxWidth: .infinity)
            .background(AppStyle.surface)
            .clipShape(CompactPanelTopCorners(radius: 20))
            .offset(y: panelOffset)
            // 🔴 用 simultaneousGesture：和列表滚动 / 长按排序手势共存；
            //    仅当手势起点在顶部抓取区、且向下拖时才移动卡片。
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        guard value.startLocation.y <= topGrabHeight else { return }
                        panelOffset = max(0, value.translation.height)
                    }
                    .onEnded { _ in
                        guard panelOffset > 0 else { return }
                        if panelOffset >= dismissThreshold {
                            onDismiss()
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { panelOffset = 0 }
                        }
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 🔴 参考主题选择器：overlay 默认 bottom 对齐点在安全区上沿，
        //    整层忽略底部安全区，卡片才能真正铺到屏幕最底（含 home indicator），
        //    否则下面会露出一条播放页底色 = 用户说的「下面灰白」。
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 只圆上方两角（SwiftUI 无内置部分圆角，用 Shape 精确控制）。
private struct CompactPanelTopCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: radius))
        p.addQuadCurve(to: CGPoint(x: radius, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width - radius, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: radius),
                       control: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}
