import SwiftUI

struct DYFeedPager<Page: View>: View {
    let items: [DYAweme]
    @Binding var currentID: String?
    @Binding var scrollID: String?
    @Binding var userScrolling: Bool
    @Binding var scrollEndTask: Task<Void, Never>?
    var pageAxes: Axis.Set = .vertical
    /// 第二个参数 = 这一条是不是当前条，用分页器自己读到的 currentID 算。
    @ViewBuilder let page: (DYAweme, Bool) -> Page

    @State private var mounted: [String] = []
    @State private var shiftTask: Task<Void, Never>?
    @State private var jumpToken = 0
    static var shiftDelay: TimeInterval { 0.3 }

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            ScrollView(.vertical) {
                ZStack(alignment: .top) {
                    Color.clear.frame(width: geo.size.width, height: h * CGFloat(max(items.count, 1)))
                    ForEach(slots, id: \.item.id) { slot in
                        Group {
                            if slot.mounted {
                                page(slot.item, slot.item.id == currentID)
                            } else {
                                DYPagerPlaceholder(item: slot.item, showsCover: true)
                            }
                        }
                        .frame(width: geo.size.width, height: h)
                        .clipped()
                        .offset(y: CGFloat(slot.index) * h)
                        .id(slot.item.id)
                    }
                }
                .frame(width: geo.size.width, height: h * CGFloat(max(items.count, 1)), alignment: .top)
                .background(DYPagingSpeedBridge(ids: items.map(\.id), currentID: $currentID, jumpToken: jumpToken))
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                scrollEndTask?.cancel()
                if !userScrolling { userScrolling = true }
            }
            .onEnded { _ in
                scrollEndTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    userScrolling = false
                }
            })
        .onAppear {
            scrollID = currentID
            if let id = currentID { DDAudioFloor.commit(id, via: "appear") }
            mounted = window(around: currentID)
            jumpToken &+= 1
        }
        .onChange(of: currentID) { _, id in
            if let id { DDAudioFloor.commit(id, via: "current") }
            if let id, !mounted.contains(id) { mounted.append(id) }
            scheduleShift()
            jumpToken &+= 1
        }
        .onChange(of: items.map(\.id)) { _, _ in
            if let id = currentID, !mounted.contains(id) { mounted.append(id) }
            scheduleShift()
            jumpToken &+= 1
        }
        .onChange(of: scrollID) { _, id in
            guard let id, id == currentID else { return }
            jumpToken &+= 1
        }
    }

    private struct Slot { let item: DYAweme; let index: Int; let mounted: Bool }

    private var slots: [Slot] {
        guard let id = currentID, let i = items.firstIndex(where: { $0.id == id }) else {
            return items.prefix(2).enumerated().map { Slot(item: $1, index: $0, mounted: mounted.contains($1.id)) }
        }
        let lo = max(0, i - 2), hi = min(items.count - 1, i + 2)
        guard lo <= hi else { return [] }
        return (lo...hi).map { k in
            let it = items[k]
            return Slot(item: it, index: k, mounted: k == i || mounted.contains(it.id))
        }
    }

    private func window(around id: String?) -> [String] {
        guard let id, let i = items.firstIndex(where: { $0.id == id }) else { return items.prefix(2).map(\.id) }
        return items[max(0, i - 1)...min(items.count - 1, i + 1)].map(\.id)
    }

    private func scheduleShift() {
        shiftTask?.cancel()
        shiftTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.shiftDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let next = window(around: currentID)
            if next != mounted { mounted = next }
        }
    }
}
