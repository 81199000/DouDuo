import SwiftUI
import WebKit

struct DYStorageScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var usage: DYStorageFiles.Usage?
    @State private var scanning = false
    @State private var clearing = false
    @State private var confirming = false
    @State private var scanFailed = false
    @State private var cleanupSucceeded: Bool?

    var body: some View {
        Form {
            if let usage {
                Section {
                    overview(usage)
                        .listRowBackground(Color.clear)
                }
            }
            if let usage {
                Section {
                    storageRow("App 大小", bytes: usage.app, total: usage.total, color: DYStorageRing.appColor)
                    // 暂不提供离线视频，不显示这一行
                    ForEach(DYStorageFiles.Category.allCases.filter { $0 != .offline }, id: \.self) { category in
                        let row = storageRow(title(category), bytes: usage.categories[category, default: 0],
                                             total: usage.total, color: DYStorageRing.color(for: category))
                        if category == .other, !usage.otherAreas.isEmpty {
                            DisclosureGroup {
                                ForEach(DYStorageFiles.OtherArea.allCases, id: \.self) { area in
                                    if let bytes = usage.otherAreas[area], bytes > 0 {
                                        LabeledContent(area.rawValue, value: size(bytes))
                                    }
                                }
                            } label: {
                                row
                            }
                            .accessibilityIdentifier("storage.other.details")
                        } else {
                            row.accessibilityIdentifier("storage.bytes." + category.rawValue)
                        }
                    }
                } header: {
                    Text("占用明细")
                } footer: {
                    Text("文稿与数据 \(size(usage.data))。App 内估算包含缓存和临时文件，iOS 储存空间可能采用不同的统计范围。")
                }
            } else if !scanFailed {
                ProgressView("正在统计储存空间")
            }

            if scanFailed {
                Button("统计失败，重试", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(scanning || clearing)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .background(Color.ddBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) { cleanupBar }
        .navigationTitle("储存空间")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .alert("清理缓存？", isPresented: $confirming) {
            Button("清理缓存", role: .destructive) {
                Task { await clear() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除缓存和诊断日志，保留登录、消息和设置。")
        }
    }

    private func overview(_ usage: DYStorageFiles.Usage) -> some View {
        VStack(spacing: 14) {
            DYStorageRing(usage: usage, totalLabel: size(usage.total), clearing: clearing)
            VStack(spacing: 8) {
                if let capacity = usage.deviceCapacity, capacity > 0 {
                    let share = Double(usage.total) / Double(capacity)
                    Text("占手机总容量的 \(percent(share))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("storage.device-share")
                    ProgressView(value: min(share, 1))
                        .tint(.accentColor)
                        .frame(maxWidth: 220)
                        .accessibilityHidden(true)
                } else {
                    Text("暂时无法读取手机总容量")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if usage.isPartial {
                Text("部分目录无法读取，当前仅显示已统计的占用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("storage.partial")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func storageRow(_ title: String, bytes: Int64, total: Int64, color: Color) -> some View {
        let ratio = Double(bytes) / Double(max(total, 1))
        let labelLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
        return LabeledContent {
            Text(size(bytes))
                .monospacedDigit()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                labelLayout {
                    Text(title)
                    Text(percent(ratio))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cleanupBar: some View {
        VStack(spacing: 8) {
            if let cleanupSucceeded, !clearing {
                Label {
                    Text(cleanupSucceeded ? "缓存已清理" : "部分缓存未能清理，请重试。")
                } icon: {
                    Image(systemName: cleanupSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(cleanupSucceeded ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("storage.result")
                .transition(.opacity)
            }
            Button {
                confirming = true
            } label: {
                Text(clearing ? "正在清理…" : "清理缓存")
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glassProminent)
            .tint(Color(red: 1, green: 59.0 / 255, blue: 48.0 / 255))
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(scanning || clearing)
            .accessibilityIdentifier("storage.clear")
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: cleanupSucceeded)
    }

    private func refresh() async {
        guard !clearing, !scanning else { return }
        scanning = true
        defer { scanning = false }
        await updateUsage()
    }

    private func updateUsage() async {
        do {
            usage = try await DYStorageFiles.shared.scan()
            scanFailed = false
        } catch is CancellationError {
            return
        } catch {
            scanFailed = true
        }
    }

    private func clear() async {
        guard !clearing, !scanning else { return }
        clearing = true
        cleanupSucceeded = nil
        defer { clearing = false }

        let videos = await DYVideoCache.shared.clearForStorage()
        let images = await ImageCache.shared.clear()
        let chatImages = await DYChatImageCache.shared.clear()
        let previews = await DYChatSnapshotCache.shared.clear()
        let logs = await DDLogWriter.clear()
        URLCache.shared.removeAllCachedResponses()
        await WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: .distantPast
        )

        await updateUsage()
        cleanupSucceeded = videos && images && chatImages && previews && logs
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private func size(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func percent(_ ratio: Double) -> String {
        let style: FloatingPointFormatStyle<Double>.Percent = .percent.precision(.fractionLength(0...2))
        if ratio > 0 && ratio < 0.0001 {
            return "<\(0.0001.formatted(style))"
        }
        return ratio.formatted(style)
    }

    private func title(_ category: DYStorageFiles.Category) -> String {
        switch category {
        case .video: "视频缓存"
        case .offline: "离线视频"
        case .images: "消息预览"
        case .web: "网页数据"
        case .diagnostics: "诊断日志"
        case .other: "其他 App 数据"
        }
    }
}
