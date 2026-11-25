import UIKit

/// 🔴 2026-11-25：沉浸式大图顶栏反色用的「顶部亮度」检测。
///
/// 展开态大图占满屏幕顶部，返回 / 更多 / 状态栏都压在图上。原来一律白字，
/// 遇到浅色（白色）封面就糊成一片。这里只取大图**顶部 1/3**（顶栏实际覆盖的区域，
/// 底部还有压暗渐变、不能算进去）做 12×12 采样，算感知亮度；足够白就切黑字。
enum HeroBrightness {
    /// 顶部平均感知亮度 ≥ 0.70 判为浅色大图 → 顶栏/状态栏用黑字。
    static func topIsLight(_ image: UIImage, topFraction: CGFloat = 0.32) -> Bool {
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
        // CGImage 原点在左下，顶部对应 y = h - cropH。裁出顶部再铺满采样格，
        // 这样不必关心 CGContext 像素行序 —— 整格都是顶部区域。
        let cropH = max(1, Int(CGFloat(h) * min(max(topFraction, 0.05), 1)))
        guard let top = cg.cropping(to: CGRect(x: 0, y: h - cropH, width: w, height: cropH)) else {
            return false
        }
        ctx.draw(top, in: CGRect(x: 0, y: 0, width: sample, height: sample))

        var sum: Double = 0
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            count += 1
        }
        guard count > 0 else { return false }
        return sum / Double(count) >= 0.70
    }
}
