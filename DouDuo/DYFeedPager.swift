import SwiftUI

/// 推荐流的竖向分页器：默认 / 简洁 / 极简 / 经典四种界面共用这一份。
///
/// ⚠️ 关键：**滚动位置只在本视图内部存在，不再每帧写回模型**。
/// 以前 `scrollPosition(id: $scrollID)` 直接绑在模型的 @Published 上，滚动过程中
/// SwiftUI 每帧都会回写一次 → 整个首页（含所有已实例化的视频页）每帧重算一遍。
/// 真机实测 body 每秒重算 900–2900 次：经典布局单次重算最贵（toolbar / 安全区 / 液态玻璃），
/// 直接掉到 30–50fps；极简布局单次便宜，才显得「丝滑」。
/// 现在只有真正停下翻页（或程序切换当前条）时才写一次 currentID。
struct DYFeedPager<Page: View>: View {
    let items: [DYAweme]
    @Binding var currentID: String?
    @Binding var userScrolling: Bool
    @Binding var scrollEndTask: Task<Void, Never>?
    @ViewBuilder let page: (DYAweme) -> Page

    /// 只在分页器内部使用的滚动位置
    @State private var scrollID: String?
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    page(item)
                        .containerRelativeFrame(.vertical)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
            // 固定「更快」收尾（0.10s）；系统开了「减少动态效果」时自动退回系统分页。
            .background(DYPagingSpeedBridge(ids: items.map(\.id), currentID: $currentID))
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID, anchor: .center)
        .onAppear { scrollID = currentID }
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                scrollEndTask?.cancel()
                // 只在状态真的变化时写，避免拖动中每帧都触发整屏重算
                if !userScrolling { userScrolling = true }
            }
            .onEnded { _ in
                // 下拉不再触发刷新（顶部点击/轻扫会误判成刷新）；刷新走「更多 → 刷新推荐」。
                scrollEndTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if !Task.isCancelled { userScrolling = false }
                }
            })
        // 滚动中每帧都会触发，这里只做防抖：停下 150ms 才写一次当前条。
        .onChange(of: scrollID) { _, id in commitWhenSettled(id) }
        // 程序切换当前条（刷新推荐 / 不感兴趣 / 自动连播 / 恢复会话）时，把滚动位置跟过去。
        .onChange(of: currentID) { _, id in
            guard let id, !userScrolling, scrollID != id, items.contains(where: { $0.id == id }) else { return }
            scrollID = id
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .onDisappear { settleTask?.cancel() }
    }

    private func commitWhenSettled(_ id: String?) {
        settleTask?.cancel()
        guard let id, items.contains(where: { $0.id == id }) else { return }
        settleTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            if currentID != id { currentID = id }
            userScrolling = false
        }
    }
}
