import SwiftUI
import UIKit

/// 视频挂的商品（小黄车）：信息区里一颗胶囊，显示商品图 + 标题 + 销量。
/// 点按：先尝试交给抖音 App（官方商品页是 Universal Link，装了抖音就直接在 App 里打开下单）；
/// 没装抖音 / 系统不接手时，在 App 内打开抖音官方商城网页（ecom.douyin.com，网页本身就能下单）。
struct DYProductPill: View {
    let product: DYAweme.Product
    var foreground: Color = .white
    @State private var webTarget: DYWebTarget?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "cart.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.status.warning.color(for: scheme))
                if let s = product.image, let u = URL(string: s) {
                    CachedAsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(product.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                if let sales = product.sales, sales > 0 {
                    Text("已售\(DYProductPill.salesText(sales))")
                        .font(.caption2)
                        .foregroundStyle(foreground.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.38)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 280, alignment: .leading)
        .accessibilityLabel("商品：\(product.title)")
        .accessibilityIdentifier("douyin.video.product")
        .fullScreenCover(item: $webTarget) { t in DouyinWebScreen(start: t.url) }
    }

    static func salesText(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1f万", Double(n) / 10_000) : String(n)
    }

    private func open() {
        guard let url = URL(string: product.detailURL) else { return }
        DYLiveModel.log("DDPRODUCT tap id=\(product.id)")
        // universalLinksOnly：只有抖音 App 认领这个链接时才跳 App，否则回调 false，不会去 Safari
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            DYLiveModel.log("DDPRODUCT app=\(opened)")
            if !opened { webTarget = DYWebTarget(url: url) }
        }
    }
}
