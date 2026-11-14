#!/usr/bin/env python3
"""Exercise the production hide watermark and backward-compatible cache schema offline."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'DouDuo/DouyinMessages.swift').read_text()
model = source[source.index('struct DYConversationRow:'):source.index('enum DYNoticeGroup:')]
snapshot = source[source.index('    struct Snapshot:'):source.index('    var snapshot =')]
tests = r'''
func row(_ preview: String = "same", time: String = "刚刚", badge: String = "", stamp: Double? = nil,
         messageID: String? = nil) -> DYConversationRow {
    .init(id:"a",name:"A",avatar:nil,preview:preview,time:time,badge:badge,index:"0",stranger:false,
          lastMessageTime:stamp,lastMessageID:messageID)
}
let hidden = row(stamp:100,messageID:"one")
precondition(!row(time:"10分钟前",stamp:100,messageID:"one").hasNewMessage(since:hidden))
var renamed = hidden; renamed.isPinned = true
precondition(!renamed.hasNewMessage(since:hidden))
precondition(row(stamp:101,messageID:"two").hasNewMessage(since:hidden))
precondition(row(stamp:100,messageID:"two").hasNewMessage(since:hidden))
precondition(!row("old page",stamp:99,messageID:"older").hasNewMessage(since:hidden))
precondition(!row(badge:"",stamp:100,messageID:"one").hasNewMessage(since:row(badge:"3",stamp:100,messageID:"one")))
precondition(row("new preview").hasNewMessage(since:row()))
precondition(row(badge:"2").hasNewMessage(since:row(badge:"1")))
precondition(!row(time:"昨天").hasNewMessage(since:row(time:"10:00")))
var saved = Snapshot(); saved.hiddenConversations = ["a": hidden]; saved.conversations = [hidden]
let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(saved))
precondition(decoded.hiddenConversations?["a"] == hidden)
precondition(decoded.conversations == [hidden], "Hiding retains the conversation/history reference")
let legacy = #"{"v":2,"pages":{},"counts":{},"friends":[],"conversations":[]}"#
let old = try JSONDecoder().decode(Snapshot.self, from: Data(legacy.utf8))
precondition(old.hiddenConversations == nil, "Older account caches remain readable")
let otherAccount = Snapshot()
precondition(otherAccount.hiddenConversations == nil, "A fresh account has no inherited hidden rows")
print("PASS message hiding: new-message restore, stable metadata, old-page guard, legacy cache, persistence, account isolation")
'''
with tempfile.TemporaryDirectory(prefix='message-hide-', dir=os.environ['TMPDIR']) as directory:
    p = pathlib.Path(directory)
    stubs = 'import Foundation\nstruct DYConversationStreak: Codable, Equatable {}\nstruct DYCachedNoticePage: Codable {}\nstruct DYFriend: Codable {}\n'
    (p / 'main.swift').write_text(stubs + model + snapshot + tests)
    subprocess.run(['swiftc', str(p / 'main.swift'), '-o', str(p / 'tests')], check=True)
    subprocess.run([str(p / 'tests')], check=True)
