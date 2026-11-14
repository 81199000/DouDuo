#!/usr/bin/env python3
"""Run the production composer model with an offline editor that can fail writes."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'DouDuo/DYChatComposerModel.swift').read_text()
model = source[source.index('@MainActor'):]
fixture = '''
import Foundation

protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
@MainActor final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String?
}
@MainActor final class WKWebView {
    var draft = ""
    var writes: [String] = []
    var rejectsEdits = false
    var rejectsConfirmation = false
    var sends: [String] = []
}
@MainActor enum DYChatComposerBridge {
    struct Snapshot { let text: String; let canSend: Bool }
    enum Action { case attachment, emoji, send }
    enum EditFailure: String, Error { case bridgeUnavailable, sendUnavailable, sendUnconfirmed }
    enum FixtureError: Error { case unavailable }

    static func read(_ web: WKWebView, id: String, height: CGFloat, bottom: CGFloat) async throws -> Snapshot {
        Snapshot(text: web.draft, canSend: !web.draft.isEmpty)
    }

    static func edit(_ web: WKWebView, id: String, previous: String, text: String) async throws -> Snapshot {
        web.writes.append(text)
        guard !web.rejectsEdits, web.draft == previous else { throw FixtureError.unavailable }
        web.draft = text
        return Snapshot(text: text, canSend: !text.isEmpty)
    }

    static func act(_ web: WKWebView, id: String, action: Action, expected: String, selection: NSRange) async throws -> Snapshot {
        precondition(action == .send && web.draft == expected)
        web.sends.append(expected)
        if web.rejectsConfirmation { throw EditFailure.sendUnconfirmed }
        web.draft = ""
        return Snapshot(text: "", canSend: false)
    }
}

enum DYLiveModel { static func log(_ message: String) {} }

@main struct Tests {
    @MainActor static func main() async {
        let web = WKWebView()
        let model = DYChatComposerModel()
        await model.refresh(web: web, id: "offline")
        web.rejectsEdits = true
        model.edit(text: "", selection: NSRange(location: 0, length: 0))
        model.edit(text: "草稿", selection: NSRange(location: 2, length: 0))
        precondition(model.canSend && model.error == nil && web.writes.isEmpty)

        let other = WKWebView()
        await model.refresh(web: other, id: "other")
        precondition(model.text.isEmpty && other.writes.isEmpty)
        await model.refresh(web: web, id: "offline")
        precondition(model.text == "草稿" && model.error == nil && web.writes.isEmpty)

        await model.perform(.send)
        precondition(model.error != nil && model.text == "草稿" && model.canSend)
        precondition(web.writes == ["草稿"] && web.sends.isEmpty, "Failed synchronization must never dispatch")
        web.rejectsEdits = false
        await model.perform(.send)
        precondition(web.writes == ["草稿", "草稿"] && web.sends == ["草稿"])
        precondition(model.text.isEmpty && !model.canSend && model.error == nil)

        model.edit(text: "确认失败", selection: NSRange(location: 4, length: 0))
        web.rejectsConfirmation = true
        await model.perform(.send)
        precondition(!model.canSend && model.error != nil)
        await model.perform(.send)
        precondition(web.sends == ["草稿", "确认失败"], "Unknown delivery must not dispatch twice")
        await model.refresh(web: other, id: "other")
        await model.refresh(web: web, id: "offline")
        precondition(!model.canSend && model.error != nil)
        model.setAccountScope("other account")
        await model.refresh(web: other, id: "offline")
        precondition(model.text.isEmpty && model.error == nil, "Drafts must not cross accounts")
        print("PASS: local typing, draft restore, sync-before-dispatch, retry, uncertain delivery, account isolation; fake sends only")

    }
}
'''

with tempfile.TemporaryDirectory(prefix='message-composer-model-') as directory:
    path = Path(directory)
    (path / 'Tests.swift').write_text(fixture + model)
    binary = path / 'test'
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'DEBUG', '-module-cache-path', str(path / 'cache'),
                    '-parse-as-library', str(path / 'Tests.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
