#!/usr/bin/env python3
"""Execute production scan/lock/cache lifecycle against a cancellable local web stub."""
from pathlib import Path
import tempfile, subprocess, os
source=(Path(__file__).resolve().parents[1]/'DouDuo/DouyinMessages.swift').read_text()
a=source.index('@MainActor\nenum DYChatOpener')
b=source.index('    /// 打开一个会话',a)
code='''import Foundation
struct DYConversationRow: Codable, Equatable { let id: String }
@MainActor final class DYMessageCache {
 static let shared = DYMessageCache()
 var accountScope = "account-a"
}
@MainActor final class WKWebView {
 enum World { case page }
 var isLoading = false
 var cancelled = false
 var collecting = false
 var complete = false
 var scans = 0
 var panels = 0
 var panelRows = 1
 func evaluateJavaScript(_ script: String) async throws -> Any? {
  if script.contains("__ddStrangerScan = null") { cancelled = true }
  return NSNumber(value: 1)
 }
 func callAsyncJavaScript(_ script: String, arguments: [String: Any], contentWorld: World) async throws -> Any? {
  if script == "window.__ddStrangerScan = token;" { cancelled = false; return nil }
  if script.contains("MOCK_PANEL") { panels += 1; return NSNumber(value: panelRows) }
  if script.contains("MOCK_COLLECT") {
   scans += 1; collecting = true
   defer { collecting = false }
   while !complete && !cancelled { try? await Task.sleep(for: .milliseconds(10)); await Task.yield() }
   if cancelled { throw CancellationError() }
   return "[{\\"id\\":\\"local\\"}]"
  }
  return nil
 }
}
'''+source[a:b].replace('private static','static')+'''
 static func jsString(_ value: String) -> String { "\\\"" + value + "\\\"" }
 static let openStrangerPanelJS = "MOCK_PANEL"
 static let collectStrangerJS = "MOCK_COLLECT"
 static var cleanups = 0
 static func collapseStranger(_ web: WKWebView) async { cleanups += 1 }
}
@main struct Tests {
 @MainActor static func main() async {
  let web = WKWebView()
  let scan = Task { await DYChatOpener.strangerRows(web) }
  while !web.collecting { await Task.yield() }
  let start = Date()
  await DYChatOpener.cancelStrangerScan()
  let rows = await scan.value
  precondition(rows == nil)
  precondition(Date().timeIntervalSince(start) < 0.25)
  precondition(DYChatOpener.cleanups == 1)
  let opened = await DYChatOpener.exclusive { !web.collecting }
  precondition(opened, "scan must finish before chat mutates the DOM")
  web.complete = true
  let first = await DYChatOpener.strangerRows(web)
  let count = web.scans
  let cached = await DYChatOpener.strangerRows(web)
  precondition(first == cached && first?.count == 1 && web.scans == count)
  DYChatOpener.cachedAt = .distantPast
  _ = await DYChatOpener.strangerRows(web)
  precondition(web.scans == count + 1)
  let other = WKWebView()
  let oldAccount = Task { await DYChatOpener.strangerRows(other) }
  while !other.collecting { await Task.yield() }
  DYMessageCache.shared.accountScope = "account-b"
  let current = WKWebView(); current.complete = true
  let fresh = await DYChatOpener.strangerRows(current)
  let stale = await oldAccount.value
  precondition(stale == nil && fresh?.count == 1)
  precondition(other.cancelled && current.scans == 1)
  DYChatOpener.visibleChatWeb = current
  DYChatOpener.cachedAt = .distantPast
  let skipped = await DYChatOpener.strangerRows(current)
  precondition(skipped == nil && current.scans == 1)
  let empty = WKWebView(); empty.panelRows = 0
  let emptyRows = await DYChatOpener.strangerRows(empty)
  let emptyCached = await DYChatOpener.strangerRows(empty)
  precondition(emptyRows == [] && emptyCached == [] && empty.panels == 1)
  print("PASS production Swift lifecycle: interruption, cleanup-before-open, cache reuse/expiry, cross-account scan isolation, no scan over visible chat")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='scan-lifecycle-',dir=os.environ['TMPDIR']) as d:
 p=Path(d);(p/'Tests.swift').write_text(code)
 subprocess.run(['swiftc','-parse-as-library',str(p/'Tests.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=10)
