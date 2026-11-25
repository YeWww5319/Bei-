import UIKit

/// 🔴 2026-11-25：沉浸式大图顶栏反色用的「顶部亮度」检测。
///
/// 展开态大图占满屏幕顶部，返回 / 更多 / 状态栏都压在图上。原来一律白字，
/// 遇到浅色（白色）封面就糊成一片。这里只取大图**顶部 1/3**（顶栏实际覆盖的区域，
/// 底部还有压暗渐变、不能算进去）做 12×12 采样，算感知亮度；足够白就切黑字。
enum HeroBrightness {
    /// 🔴 2026-11-25(二)：判定浅色大图 → 顶栏/状态栏用黑字。
    ///
    /// 首版只看「顶部 32% 全宽平均值 ≥ 0.70」，白色 Beyond 合照仍被判深色 → 白字糊成一片。
    /// 原因：大图铺满时两侧常被深色人物/边缘占据，把均值拉低；而顶栏按钮实际只压在**中间**
    /// 一条窄带上。改为只采**中间 76% 宽 × 顶部 34% 高**，并同时看均值与中位数：
    /// 大面积白底（均值 0.84 / 中位 0.90）必然判浅色，深色图两种指标都低不会误判。
    static func topIsLight(_ image: UIImage, topFraction: CGFloat = 0.34) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return false }

        let sample = 12
        var pixels = [UInt8](repeating: 0, count: sample * sample * 4)
        guard let ctx = CGContext(data: &pixels,
                                  width: sample, height: sample,
                                  bitsPerComponent: 8, bytesPerRow: sample * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        // CGImage 原点在左下，顶部对应 y = h - cropH；中间 76% 宽避开两侧深色边缘。
        let cropH = max(1, Int(CGFloat(h) * min(max(topFraction, 0.05), 1)))
        let cropW = max(1, Int(CGFloat(w) * 0.76))
        let cropX = (w - cropW) / 2
        guard let top = cg.cropping(to: CGRect(x: cropX, y: h - cropH,
                                               width: cropW, height: cropH)) else {
            return false
        }
        ctx.draw(top, in: CGRect(x: 0, y: 0, width: sample, height: sample))

        var values: [Double] = []
        values.reserveCapacity(sample * sample)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        guard !values.isEmpty else { return false }
        let mean = values.reduce(0, +) / Double(values.count)
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        // 均值够亮 或 中位数很亮（少量深色文字不该把整张白图判成深色）。
        return mean >= 0.66 || median >= 0.78
    }

    /// 🔴 2026-11-25(三)：直接截 UIKit 大图浮层来判亮度 —— 不依赖 CoverImage 的
    /// 加载回调。UIHostingController.rootView 被替换 / 缓存首帧 / 浮层重装时，
    /// SwiftUI 的 onAppear / task / onChange 都可能一次都不触发（真机两张白色封面
    /// 截图顶栏始终白字）。屏幕上真正画出来的像素永远不会骗人。
    ///
    /// 输出 nil 表示当前还不能可靠取样（浮层还没上窗 / 尺寸为 0），调用方稍后重试。
    static func renderedTopIsLight(_ view: UIView, fraction: CGFloat = 0.34) -> Bool? {
        guard view.window != nil,
              view.bounds.width > 8, view.bounds.height > 8 else { return nil }
        // 等比缩到 72pt 宽再算，采样开销与屏幕尺寸无关。
        let width: CGFloat = 72
        let size = CGSize(width: width,
                          height: max(8, width * view.bounds.height / view.bounds.width))
        let renderer = UIGraphicsImageRenderer(size: size)
        let shot = renderer.image { ctx in
            ctx.cgContext.scaleBy(x: size.width / view.bounds.width,
                                  y: size.height / view.bounds.height)
            view.drawHierarchy(in: CGRect(origin: .zero, size: view.bounds.size),
                               afterScreenUpdates: false)
        }
        return topIsLight(shot, topFraction: fraction)
    }
}
