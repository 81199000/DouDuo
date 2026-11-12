import SwiftUI

/// 直播交互区的环境光背景。画面本身仍由现有播放器绘制。
/// Layout A 的交互区在画面下方，光从折痕（上沿）向下淡出。
/// Layout B 的交互区在画面右方，光从折痕（左沿）向右淡出。
/// 封面只走现有 ImageCache；模糊在封面变化时做一次，不在 body 里重算。
struct DouyinLiveAmbientBackground: View {
    /// 已有房间封面。没有缓存时才经 ImageCache 取缩略图。
    var coverURL: URL?
    var axis: DYLiveAmbientAxis
    /// 账号或会话代际。换账号后旧任务即使拿到同一张封面，也不能写回当前画面。
    var isolationID: String = ""
    /// 预览和测试直接给图。有图时不再读取 coverURL，也不会发起加载。
    var artwork: UIImage?

    @State private var displayed: UIImage?
    @State private var displayedKey = ""

    var body: some View {
        // MARK: - ambient-body
        let fade = DYLiveAmbientTreatment.fade(for: axis)
        ZStack {
            treatmentColor(DYLiveAmbientTreatment.fallback)
            if let displayed, displayedKey == sourceToken {
                reflection(displayed, fade: fade)
                    .id(displayedKey)
                    .transition(.opacity)
            }
            Color.black.opacity(DYLiveAmbientTreatment.plateOpacity)
            maskGradient(DYLiveAmbientTreatment.veilStops, fade: fade, color: .black)
        }
        .animation(.easeInOut(duration: DYLiveAmbientTreatment.transitionDuration), value: displayedKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // MARK: - ambient-body-end
        .task(id: sourceToken) { await refreshArtwork() }
    }

    private var sourceToken: String {
        let artworkID: String
        if let artwork {
            artworkID = "artwork:\(ObjectIdentifier(artwork).hashValue)"
        } else if let coverURL {
            artworkID = "cover:\(coverURL.absoluteString)"
        } else {
            artworkID = "fallback"
        }
        return DYLiveAmbientIdentity.token(isolationID: isolationID, artwork: artworkID)
    }

    // MARK: - ambient-refresh
    private func refreshArtwork() async {
        let token = sourceToken
        let requestedCover = artwork == nil ? coverURL : nil
        let requestedArtwork = artwork
        guard !DYLiveAmbientIdentity.isFallback(token) else {
            publish(nil, token: token)
            return
        }
        if displayedKey == token, displayed != nil { return }
        if let cached = DYLiveAmbientBlurStore.shared.peek(token) {
            publish(cached.uiImage(), token: token)
            return
        }
        guard let source = await Self.sourceImage(coverURL: requestedCover, artwork: requestedArtwork) else {
            publish(nil, token: token)
            return
        }
        guard stillCurrent(token) else { return }
        guard let bitmap = DYLiveAmbientBitmap.scaled(from: source, maxPixel: DYLiveAmbientTreatment.sourceMaxPixel) else { return }
        let soft = await Task.detached(priority: .utility) {
            DYLiveAmbientBlur.soften(bitmap)
        }.value
        guard stillCurrent(token) else { return }
        let kept = DYLiveAmbientBlurStore.shared.resolve(key: token) { soft }
        publish(kept.uiImage(), token: token)
    }

    /// 只接受这次任务自己的房间和账号。过期或已取消的结果直接丢掉。
    private func publish(_ image: UIImage?, token: String) {
        guard stillCurrent(token) else { return }
        displayed = image
        displayedKey = token
    }

    private func stillCurrent(_ token: String) -> Bool {
        DYLiveAmbientIdentity.shouldApply(requested: token, current: sourceToken, cancelled: Task.isCancelled)
    }

    /// 内存里已有原图或缩略图就直接用。未命中时只走一次 `loadThumb`，
    /// 由 ImageCache 合并同一 URL 正在进行的下载，这里不再另开请求。
    private static func sourceImage(coverURL: URL?, artwork: UIImage?) async -> UIImage? {
        if let artwork { return artwork }
        guard let coverURL else { return nil }
        let maxPixel = DYLiveAmbientTreatment.sourceMaxPixel
        if let thumb = ImageCache.shared.memoryThumb(coverURL, maxPixel: maxPixel) { return thumb }
        if let cached = ImageCache.shared.memoryCached(coverURL) { return cached }
        return await ImageCache.shared.loadThumb(coverURL, maxPixel: maxPixel)
    }
    // MARK: - ambient-refresh-end

    private func reflection(_ image: UIImage, fade: DYLiveAmbientFade) -> some View {
        ZStack {
            field(image)
                .mask(maskGradient(DYLiveAmbientTreatment.artworkStops, fade: fade, color: .white))
            field(image)
                .scaleEffect(x: axis == .horizontal ? -1 : 1, y: axis == .vertical ? -1 : 1)
                .mask(maskGradient(DYLiveAmbientTreatment.reflectionStops, fade: fade, color: .white))
                .opacity(DYLiveAmbientTreatment.reflectionOpacity)
        }
        .compositingGroup()
    }

    private func field(_ image: UIImage) -> some View {
        // 铺满只负责裁切后的绘制。Color.clear 占住父级给出的尺寸，避免封面比例把交互区撑出窗格。
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.low)
                    .scaledToFill()
            }
            .clipped()
    }

    private func maskGradient(_ stops: [DYLiveAmbientStop], fade: DYLiveAmbientFade, color: Color) -> LinearGradient {
        let ends = endpoints(fade)
        return LinearGradient(
            stops: stops.map {
                Gradient.Stop(color: color.opacity(Double($0.opacity)), location: $0.location)
            },
            startPoint: ends.start,
            endPoint: ends.end)
    }

    private func endpoints(_ fade: DYLiveAmbientFade) -> (start: UnitPoint, end: UnitPoint) {
        (point(fade.start), point(fade.end))
    }

    private func point(_ edge: DYLiveAmbientEdge) -> UnitPoint {
        switch edge {
        case .minY: return .top
        case .maxY: return .bottom
        case .minX: return UnitPoint(x: 0, y: 0.5)
        case .maxX: return UnitPoint(x: 1, y: 0.5)
        }
    }

    private func treatmentColor(_ color: DYLiveAmbientRGB) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }
}

// MARK: - ambient-treatment

enum DYLiveAmbientIdentity {
    private static let separator = "\u{1e}"

    static func token(isolationID: String, artwork: String) -> String {
        isolationID + separator + artwork
    }

    static func isFallback(_ token: String) -> Bool {
        token.hasSuffix(separator + "fallback")
    }

    /// 请求发出时的身份必须仍是当前身份，任务也没有取消。
    static func shouldApply(requested: String, current: String, cancelled: Bool) -> Bool {
        !cancelled && requested == current
    }
}

enum DYLiveAmbientAxis: Equatable {
    /// Layout A：交互区在下，沿垂直方向从折痕淡出。
    case vertical
    /// Layout B：交互区在右，沿水平方向从折痕淡出。
    case horizontal
}

enum DYLiveAmbientEdge: Equatable {
    case minX
    case maxX
    case minY
    case maxY
}

struct DYLiveAmbientFade: Equatable {
    var start: DYLiveAmbientEdge
    var end: DYLiveAmbientEdge
}

struct DYLiveAmbientStop: Equatable {
    var location: CGFloat
    var opacity: CGFloat
}

struct DYLiveAmbientRGB: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

enum DYLiveAmbientTreatment {
    /// 模糊源的长边上限。环境光不需要封面细节。
    static let sourceMaxPixel = 72
    /// 房间切换时的交叉淡入，只播一次。
    static let transitionDuration: Double = 0.45
    /// 整层压暗。折痕到外侧的明暗差交给 artwork 和 veil，不再靠一块更重的纯黑。
    static let plateOpacity: CGFloat = 0.58
    /// 折痕一侧的低分辨率色光。只在封面变化时叠一次。
    static let reflectionOpacity: CGFloat = 0.46
    static let minimumTextContrast: CGFloat = 4.5
    static let fallback = DYLiveAmbientRGB(red: 0.067, green: 0.067, blue: 0.074)

    /// 0 是贴着画面的折痕，1 是交互区外侧。折痕一侧留更多封面色。
    static let artworkStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.88),
        DYLiveAmbientStop(location: 0.42, opacity: 0.52),
        DYLiveAmbientStop(location: 1, opacity: 0.16),
    ]
    static let reflectionStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.95),
        DYLiveAmbientStop(location: 0.48, opacity: 0.12),
        DYLiveAmbientStop(location: 1, opacity: 0),
    ]
    static let veilStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.04),
        DYLiveAmbientStop(location: 1, opacity: 0.34),
    ]

    static func axis(for layout: DYLiveAdaptiveLayout) -> DYLiveAmbientAxis? {
        switch layout {
        case .layoutA: return .vertical
        case .layoutB: return .horizontal
        case .existing: return nil
        }
    }

    static func fade(for axis: DYLiveAmbientAxis) -> DYLiveAmbientFade {
        switch axis {
        case .vertical:
            return DYLiveAmbientFade(start: .minY, end: .maxY)
        case .horizontal:
            return DYLiveAmbientFade(start: .minX, end: .maxX)
        }
    }

    static func artworkOpacity(at location: CGFloat) -> CGFloat {
        opacity(at: location, stops: artworkStops)
    }

    static func backdrop(artwork: DYLiveAmbientRGB?, location: CGFloat) -> DYLiveAmbientRGB {
        let black = DYLiveAmbientRGB(red: 0, green: 0, blue: 0)
        var pixel = fallback
        if let artwork {
            pixel = over(pixel, artwork, opacity: artworkOpacity(at: location))
            let reflection = opacity(at: location, stops: reflectionStops) * reflectionOpacity
            pixel = over(pixel, artwork, opacity: reflection)
        }
        pixel = over(pixel, black, opacity: plateOpacity)
        pixel = over(pixel, black, opacity: opacity(at: location, stops: veilStops))
        return pixel
    }

    static func whiteTextContrast(artwork: DYLiveAmbientRGB?, location: CGFloat) -> CGFloat {
        whiteTextContrast(on: backdrop(artwork: artwork, location: location))
    }

    static func whiteTextContrast(on color: DYLiveAmbientRGB) -> CGFloat {
        (1 + 0.05) / (relativeLuminance(color) + 0.05)
    }

    static func opacity(at location: CGFloat, stops: [DYLiveAmbientStop]) -> CGFloat {
        let t = min(1, max(0, location))
        guard let first = stops.first else { return 0 }
        if t <= first.location { return first.opacity }
        guard let last = stops.last else { return 0 }
        if t >= last.location { return last.opacity }
        for index in stops.indices.dropFirst() {
            let left = stops[index - 1]
            let right = stops[index]
            if t <= right.location {
                let span = right.location - left.location
                let u = span > 0 ? (t - left.location) / span : 0
                return left.opacity + (right.opacity - left.opacity) * u
            }
        }
        return last.opacity
    }

    private static func over(_ base: DYLiveAmbientRGB, _ color: DYLiveAmbientRGB, opacity: CGFloat) -> DYLiveAmbientRGB {
        let t = min(1, max(0, opacity))
        return DYLiveAmbientRGB(
            red: base.red * (1 - t) + color.red * t,
            green: base.green * (1 - t) + color.green * t,
            blue: base.blue * (1 - t) + color.blue * t)
    }

    private static func linear(_ channel: CGFloat) -> CGFloat {
        if channel <= 0.04045 { return channel / 12.92 }
        return pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func relativeLuminance(_ color: DYLiveAmbientRGB) -> CGFloat {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}

struct DYLiveAmbientBitmap: Equatable, Sendable {
    var width: Int
    var height: Int
    var rgba: [UInt8]
}

enum DYLiveAmbientBlur {
    static func boxBlur(_ source: DYLiveAmbientBitmap, radius: Int) -> DYLiveAmbientBitmap {
        guard radius > 0, source.width > 0, source.height > 0, source.rgba.count == source.width * source.height * 4 else {
            return source
        }
        let horizontal = blur(source, radius: radius, horizontal: true)
        return blur(horizontal, radius: radius, horizontal: false)
    }

    /// 三次盒式模糊叠成柔和色块。只应在封面变化时调用。
    static func soften(_ source: DYLiveAmbientBitmap) -> DYLiveAmbientBitmap {
        guard source.width > 0, source.height > 0 else { return source }
        let radius = max(2, min(source.width, source.height) / 5)
        var image = source
        for _ in 0..<3 {
            image = boxBlur(image, radius: radius)
        }
        return image
    }

    private static func blur(_ source: DYLiveAmbientBitmap, radius: Int, horizontal: Bool) -> DYLiveAmbientBitmap {
        let width = source.width
        let height = source.height
        var out = [UInt8](repeating: 0, count: source.rgba.count)
        let span = horizontal ? width : height
        let lines = horizontal ? height : width
        let window = radius * 2 + 1
        for line in 0..<lines {
            func sample(_ index: Int) -> (Int, Int, Int, Int) {
                let clamped = min(span - 1, max(0, index))
                let pixel = horizontal ? (line * width + clamped) * 4 : (clamped * width + line) * 4
                return (
                    Int(source.rgba[pixel]),
                    Int(source.rgba[pixel + 1]),
                    Int(source.rgba[pixel + 2]),
                    Int(source.rgba[pixel + 3]))
            }
            var sumR = 0
            var sumG = 0
            var sumB = 0
            var sumA = 0
            for index in -radius...radius {
                let pixel = sample(index)
                sumR += pixel.0
                sumG += pixel.1
                sumB += pixel.2
                sumA += pixel.3
            }
            for index in 0..<span {
                let pixel = horizontal ? (line * width + index) * 4 : (index * width + line) * 4
                out[pixel] = UInt8(sumR / window)
                out[pixel + 1] = UInt8(sumG / window)
                out[pixel + 2] = UInt8(sumB / window)
                out[pixel + 3] = UInt8(sumA / window)
                if index + 1 < span {
                    let remove = sample(index - radius)
                    let add = sample(index + radius + 1)
                    sumR += add.0 - remove.0
                    sumG += add.1 - remove.1
                    sumB += add.2 - remove.2
                    sumA += add.3 - remove.3
                }
            }
        }
        return DYLiveAmbientBitmap(width: width, height: height, rgba: out)
    }
}

/// 同一张封面只模糊一次。容量很小，只留最近几间房。
final class DYLiveAmbientMemo<Value> {
    private var stored: [String: Value] = [:]
    private var order: [String] = []
    private(set) var renders = 0
    let limit: Int

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func peek(_ key: String) -> Value? {
        guard let hit = stored[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    func resolve(key: String, render: () -> Value) -> Value {
        if let hit = peek(key) { return hit }
        renders += 1
        let value = render()
        stored[key] = value
        order.append(key)
        while stored.count > limit, let oldest = order.first {
            order.removeFirst()
            stored[oldest] = nil
        }
        return value
    }
}

// MARK: - ambient-treatment-end

private final class DYLiveAmbientBlurStore {
    static let shared = DYLiveAmbientBlurStore()
    private let memo = DYLiveAmbientMemo<DYLiveAmbientBitmap>(limit: 4)

    func peek(_ key: String) -> DYLiveAmbientBitmap? { memo.peek(key) }

    func resolve(key: String, render: () -> DYLiveAmbientBitmap) -> DYLiveAmbientBitmap {
        memo.resolve(key: key, render: render)
    }
}

extension DYLiveAmbientBitmap {
    static func scaled(from image: UIImage, maxPixel: Int) -> DYLiveAmbientBitmap? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth >= 1, pixelHeight >= 1 else { return nil }
        let cap = CGFloat(max(1, maxPixel))
        let ratio = min(1, cap / max(pixelWidth, pixelHeight))
        let width = max(1, Int((pixelWidth * ratio).rounded()))
        let height = max(1, Int((pixelHeight * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let small = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cg = small.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drew = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        for index in stride(from: 3, to: rgba.count, by: 4) { rgba[index] = 255 }
        return DYLiveAmbientBitmap(width: width, height: height, rgba: rgba)
    }

    func uiImage() -> UIImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

#if DEBUG
private enum DYLiveAmbientPreviewArt {
    static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
        return renderer.image { context in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }
}

private struct DYLiveAmbientPreview: View {
    var axis: DYLiveAmbientAxis
    var artwork: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DouyinLiveAmbientBackground(axis: axis, artwork: artwork)
            VStack(alignment: .leading, spacing: 6) {
                Text("主播名称").font(.headline)
                Text("评论在封面上保持可读").font(.subheadline)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
    }
}

struct DouyinLiveAmbientBackground_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            DYLiveAmbientPreview(axis: .vertical, artwork: DYLiveAmbientPreviewArt.solid(1, 0.92, 0.15))
                .previewDisplayName("A 亮色")
            DYLiveAmbientPreview(axis: .horizontal, artwork: DYLiveAmbientPreviewArt.solid(0.1, 0.45, 1))
                .previewDisplayName("B 亮色")
            DYLiveAmbientPreview(axis: .vertical, artwork: DYLiveAmbientPreviewArt.solid(0.02, 0.02, 0.03))
                .previewDisplayName("A 暗色")
            DYLiveAmbientPreview(axis: .horizontal, artwork: nil)
                .previewDisplayName("B 无封面")
        }
        .frame(width: 390, height: 280)
        .previewLayout(.sizeThatFits)
    }
}
#endif
