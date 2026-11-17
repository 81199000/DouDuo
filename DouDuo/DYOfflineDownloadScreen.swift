import SwiftUI

struct DYOfflineDownloadScreen: View {
    let candidateSource: ((Int) async throws -> [DYAweme])?
    var interactionBridge: DouyinBridge? = nil

    @ObservedObject private var downloads = DYOfflineDownloads.shared
    @AppStorage(DYOfflineDownloads.automaticDownloadKey) private var automaticDownload = false
    @AppStorage(DYOfflineDownloads.downloadTargetKey) private var targetCount = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var downloadButtonHeight = 54.0
    @State private var requestedCount = 50
    @State private var showLibrary = false
    @State private var libraryPresentation = UUID()
    @State private var confirmDownload = false
    @State private var confirmStop = false
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section {
                libraryRow
                if downloads.savedCount > 0 {
                    LabeledContent("视频时长", value: playableDuration)
                        .accessibilityIdentifier("offline.duration")
                }
            }

            Section {
                Picker("下载数量", selection: $targetCount) {
                    ForEach(DYOfflineDownloads.downloadCounts, id: \.self) { Text("\(DYFormat.count($0)) 条").tag($0) }
                }
                .accessibilityIdentifier("offline.count")
                Toggle("自动下载", isOn: $automaticDownload)
                    .accessibilityIdentifier("offline.automatic")
            } footer: {
                Text("自动下载仅在 Wi-Fi 下补足所选数量。")
            }

            if !downloading, let result = downloads.result, !result.success {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title).font(.subheadline.weight(.semibold))
                        Text(result.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if downloads.savedCount > 0 {
                Section {
                    Button(downloads.removing ? "正在删除…" : "删除全部离线视频", role: .destructive) {
                        confirmRemoval = true
                    }
                    .disabled(downloading || downloads.removing)
                    .accessibilityIdentifier("offline.delete")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        if let deadline = downloads.playableUntil {
                            Text("预计清理时间 \(DYFormat.dateTime(deadline))")
                                .accessibilityIdentifier("offline.expiration")
                        }
                        Text("刷完后保留 3 天，连续 7 天未刷也会清理。")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .background(Color.ddBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            downloadButton
        }
        .navigationTitle("离线视频")
        .navigationBarTitleDisplayMode(.inline)
        .task { await downloads.refreshRetention() }
        .onChange(of: targetCount, initial: true) { _, count in
            if !DYOfflineDownloads.downloadCounts.contains(count) { targetCount = DYOfflineDownloads.defaultDownloadTarget }
        }
        .onChange(of: downloading) { _, active in
            if !active { confirmStop = false }
        }
        .fullScreenCover(isPresented: $showLibrary, onDismiss: { DDPlayback.shared.endOfflineLibrary(libraryPresentation) }) {
            DYOfflineLibraryScreen(interactionBridge: interactionBridge, presentation: libraryPresentation)
        }
        .alert("下载离线视频？", isPresented: $confirmDownload, presenting: requestedCount) { requested in
            Button("开始下载") {
                if let candidateSource {
                    downloads.start(count: requested, candidateSource: candidateSource)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { requested in
            let count = min(requested, downloads.remainingCapacity)
            let quantity = count < requested ? "剩余 \(DYFormat.count(count)) 条下载名额" : "\(DYFormat.count(count)) 条视频"
            Text("\(quantity)，预计占用 \(DYOfflineDownloads.estimatedSize(for: count))。")
        }
        .alert("停止下载？", isPresented: $confirmStop) {
            Button("停止下载", role: .destructive, action: downloads.cancel)
            Button("取消", role: .cancel) {}
        }
        .alert("删除全部离线视频？", isPresented: $confirmRemoval) {
            Button("删除", role: .destructive) { Task { await downloads.removeAll() } }
            Button("取消", role: .cancel) {}
        }
    }

    private var libraryRow: some View {
        let savedCount = "\(DYFormat.count(downloads.savedCount)) 条"
        return Button {
            showLibrary = true
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text("离线视频")
                } icon: {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 4)
                Text(savedCount)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("离线视频")
        .accessibilityValue(savedCount)
        .accessibilityIdentifier("offline.library")
    }

    private var downloadButton: some View {
        VStack {
            Button {
                if downloading {
                    confirmStop = true
                } else {
                    requestedCount = targetCount
                    confirmDownload = true
                }
            } label: {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let boundary = width * downloadedFraction
                    let transitionHalfWidth = min(12, boundary, width - boundary)
                    let solidWidth = boundary - transitionHalfWidth
                    ZStack {
                        Color.blue.mask(alignment: .leading) {
                            HStack(spacing: 0) {
                                Rectangle().frame(width: solidWidth)
                                LinearGradient(
                                    colors: [.black, .black.opacity(0.84), .black.opacity(0.5), .black.opacity(0.16), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: transitionHalfWidth * 2)
                            }
                        }
                        downloadTitle.foregroundStyle(.primary)
                        downloadTitle.foregroundStyle(.white)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: solidWidth)
                            }
                    }
                }
                .frame(height: downloadButtonHeight)
                .clipShape(.capsule)
                .glassEffect(.regular.interactive(downloadButtonEnabled), in: .capsule)
                .contentShape(.capsule)
                .opacity(downloadButtonEnabled ? 1 : 0.45)
                .animation(reduceMotion || !downloading ? nil : .easeInOut(duration: 0.28), value: downloads.progress?.saved)
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!downloadButtonEnabled)
            .accessibilityLabel(downloading ? "停止下载" : downloadButtonText)
            .accessibilityValue(downloadProgressDescription)
            .accessibilityIdentifier(downloading ? "offline.stop" : "offline.estimate")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(downloading ? (downloads.progress == nil ? "offline.preparing" : "offline.progress") : "offline.downloadControl")
        .frame(maxWidth: 480)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var downloadTitle: some View {
        Text(downloadButtonText)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var downloadButtonText: String {
        if let progress = downloads.progress {
            return "正在下载 \(DYFormat.count(progress.saved)) / \(DYFormat.count(progress.total)) 条"
        }
        if downloads.preparing { return "正在准备下载" }
        return downloads.remainingCapacity > 0 ? "下载" : "已达下载上限"
    }

    private var downloadButtonEnabled: Bool {
        downloading || (downloads.remainingCapacity > 0 && !downloads.removing && candidateSource != nil
            && DYOfflineDownloads.downloadCounts.contains(targetCount))
    }

    private var downloadedFraction: Double {
        guard downloading else { return 1 }
        guard let progress = downloads.progress, progress.total > 0 else { return 0 }
        return min(1, Double(progress.saved) / Double(progress.total))
    }

    private var downloadProgressDescription: String {
        guard let progress = downloads.progress else { return downloads.preparing ? "正在准备下载" : "" }
        return "已下载 \(DYFormat.count(progress.saved)) 条，共 \(DYFormat.count(progress.total)) 条"
    }

    private var downloading: Bool { downloads.preparing || downloads.progress != nil }

    private var playableDuration: String {
        DYOfflineDownloads.playableDurationText(downloads.totalPlayableDuration) ?? "—"
    }
}
