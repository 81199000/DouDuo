import SwiftUI
import WebKit

@MainActor
final class DYChatComposerModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var ready = false
    @Published private(set) var canSend = false
    @Published private(set) var working = false
    @Published private(set) var error: String?
    @Published var isEditing = false
    var height: CGFloat = 44
    var bottomInset: CGFloat { isEditing ? 8 : 24 }

    private weak var web: WKWebView?
    private var conversationID = ""
    private var acknowledgedText = ""
    private var selection = NSRange(location: 0, length: 0)
    private var editRevision = 0
    private var writeTask: Task<Bool, Never>?

    func refresh(web: WKWebView, id: String) async {
        if conversationID != id {
            writeTask?.cancel()
            writeTask = nil
            conversationID = id
            self.web = web
            text = ""
            acknowledgedText = ""
            ready = false
            canSend = false
            error = nil
            selection = NSRange(location: 0, length: 0)
            editRevision += 1
        }
        guard writeTask == nil, !working, text == acknowledgedText else { return }
        let revision = editRevision
        guard let snapshot = try? await DYChatComposerBridge.read(web, id: id, height: height, bottom: bottomInset),
              conversationID == id, editRevision == revision, writeTask == nil else { return }
        if text != snapshot.text {
            text = snapshot.text
            selection = NSRange(location: (text as NSString).length, length: 0)
        }
        acknowledgedText = snapshot.text
        if canSend != snapshot.canSend { canSend = snapshot.canSend }
        if !ready { ready = true }
    }

    func edit(text: String, selection: NSRange) {
        guard ready else { return }
        guard self.text != text || self.selection != selection else { return }
        self.text = text
        self.selection = selection
        editRevision += 1
        error = nil
        scheduleWrite()
    }

    private func scheduleWrite() {
        guard writeTask == nil, let web, !conversationID.isEmpty else { return }
        let id = conversationID
        writeTask = Task { [weak self] in
            guard let self else { return false }
            defer { if self.conversationID == id { self.writeTask = nil } }
            while !Task.isCancelled, self.conversationID == id {
                let revision = self.editRevision
                let target = self.text
                do {
                    let result = try await DYChatComposerBridge.edit(web, id: id, previous: self.acknowledgedText,
                        text: target, selection: self.selection)
                    guard self.conversationID == id, !Task.isCancelled else { return false }
                    self.acknowledgedText = result.text
                    self.canSend = result.canSend
                    if self.editRevision == revision { return true }
                } catch {
                    guard self.conversationID == id else { return false }
                    self.error = "草稿同步未完成，请重试。"
                    self.canSend = false
                    return false
                }
            }
            return false
        }
    }

    func retry() { error = nil; scheduleWrite() }

    func isConnected(to id: String?) -> Bool { ready && id == conversationID }

    func copyAndRecover() async {
        guard let web, !working else { return }
        let id = conversationID
        UIPasteboard.general.string = text
        guard let snapshot = try? await DYChatComposerBridge.read(web, id: id, height: height, bottom: bottomInset), conversationID == id else { return }
        text = snapshot.text
        acknowledgedText = snapshot.text
        canSend = snapshot.canSend
        error = nil
    }

    func flush() async -> Bool {
        if let writeTask { return await writeTask.value }
        return error == nil && text == acknowledgedText
    }

    func perform(_ action: DYChatComposerBridge.Action) async {
        guard !working, ready, let web else { return }
        working = true
        defer { working = false }
        let id = conversationID
        if let writeTask {
            guard await writeTask.value else { return }
        }
        guard conversationID == id, error == nil, text == acknowledgedText else { return }
        do {
            let result = try await DYChatComposerBridge.act(web, id: id, action: action, expected: acknowledgedText)
            guard conversationID == id else { return }
            text = result.text
            acknowledgedText = result.text
            canSend = result.canSend
        } catch {
            guard conversationID == id else { return }
            self.error = "操作未完成，请重试。"
        }
    }
}
