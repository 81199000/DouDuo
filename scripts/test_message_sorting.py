#!/usr/bin/env python3
"""Run the production ordering model without WebKit, cookies or account data."""
import os, pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'DouDuo/DouyinMessages.swift').read_text()
model = source[source.index('struct DYConversationRow:'):source.index('enum DYNoticeGroup:')]
tests = r'''
func row(_ id: String, _ time: String = "", pinned: Bool = false, server: Double? = nil) -> DYConversationRow {
 .init(id:id,name:id,avatar:nil,preview:"",time:time,badge:"",index:"0",stranger:false,isPinned:pinned,lastMessageTime:server)
}
let base = ISO8601DateFormatter().date(from:"2026-01-02T12:00:00Z")!
let order = [row("older",server:100),row("newer",server:300),row("pin",pinned:true,server:1),row("middle",server:200)]
precondition(order.sorted(by:DYConversationRow.byTimeDesc).map(\.id) == ["pin","newer","middle","older"])
precondition(row("one","刚刚").sortTime(at:base) == base.timeIntervalSince1970)
precondition(row("one","5分钟前").sortTime(at:base) == base.timeIntervalSince1970-300)
precondition(row("one","2小时前").sortTime(at:base) == base.timeIntervalSince1970-7200)
precondition(row("one","30秒前").sortTime(at:base) == base.timeIntervalSince1970-30)
precondition(row("one","2天前").sortTime(at:base) == Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: base))!.timeIntervalSince1970)
precondition(row("one","昨天 10:00").sortTime(at:base) < row("two","11:00").sortTime(at:base))
precondition(row("one","12/31").sortTime(at:base) < row("two","01/01").sortTime(at:base))
precondition(row("one","2024/12/31").sortTime(at:base) < row("two","2025/01/01").sortTime(at:base))
precondition(row("one","刚刚",server:123).sortTime(at:base) == 123)
precondition(!DYConversationRow.byTimeDesc(row("a","刚刚"),row("a","刚刚")))
precondition(DYConversationRow.byTimeDesc(row("a","5分钟前"),row("b","5分钟前")))
var updated = order; updated[0].lastMessageTime = 400
precondition(updated.sorted(by:DYConversationRow.byTimeDesc).map(\.id) == ["pin","older","newer","middle"])
var anchored = row("anchored", "5分钟前")
anchored.observedAt = base.timeIntervalSince1970
precondition(anchored.sortTime(at:base.addingTimeInterval(86400)) == base.timeIntervalSince1970-300)
anchored.lastMessageTime = 100
precondition(anchored.sortTime(at:base) == 100)
let oldJSON = #"{"id":"legacy","name":"legacy","preview":"","time":"昨天","badge":"","index":"0","stranger":false}"#
precondition((try! JSONDecoder().decode(DYConversationRow.self,from:Data(oldJSON.utf8))).lastMessageTime == nil)
print("PASS message order: pins first, server time, new-message reorder, relative labels, calendar dates, stable ties, legacy cache")
'''
with tempfile.TemporaryDirectory(prefix='message-sort-', dir=os.environ['TMPDIR']) as directory:
    p=pathlib.Path(directory)
    (p/'main.swift').write_text('import Foundation\nstruct DYConversationStreak: Codable, Equatable {}\n'+model+tests)
    subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'tests')],check=True)
    subprocess.run([str(p/'tests')],check=True)
