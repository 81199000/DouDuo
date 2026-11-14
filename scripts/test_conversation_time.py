#!/usr/bin/env python3
"""Compile real conversation time parser with a fixed clock; no network/account writes."""
from pathlib import Path
import os, subprocess
root = Path(__file__).resolve().parents[1]
s = (root/'DouDuo/DouyinMessages.swift').read_text()
a=s.index('extension DYConversationRow {'); b=s.index('\nenum DYNoticeGroup:',a)
code='import Foundation\nstruct DYConversationRow { let id: String; let time: String; var observedAt: Double? = nil }\n'+s[a:b]+r'''
let cal = Calendar.current
let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 30))!
func t(_ s: String) -> Double { DYConversationRow.parseTime(s, now: now) }
precondition(t("刚刚") > t("20:00"))
precondition(t("20:00") > t("昨天 23:00"))
precondition(t("昨天 23:00") > t("前天 23:59"))
precondition(t("前天 23:59") > t("11/01"))
precondition(t("前天") == cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now))!.timeIntervalSince1970)
precondition(t("2026/11/13 08:30") == t("昨天 08:30"))
precondition(t("2天前") == t("前天"))
precondition(t("garbage") == 0 && t("2026/99/01") == 0)
precondition(t("12/31") < t("11/01"))
let rows = ["前天", "昨天", "刚刚", "11/01"].enumerated().map { DYConversationRow(id: String($0.offset), time: $0.element, observedAt: now.timeIntervalSince1970) }
let sorted = rows.sorted(by: DYConversationRow.byTimeDesc)
precondition(sorted.map(\.time) == ["刚刚", "昨天", "前天", "11/01"])
for r in rows { precondition(!DYConversationRow.byTimeDesc(r, r)) }
print("PASS conversation sorting: fixed capture clock, today/yesterday/day-before/date/relative, invalid dates, strict comparator")
'''
p=Path(os.environ['TMPDIR'])/'conversation-time-regression.swift'
p.write_text(code)
subprocess.run(['swift', str(p)],check=True)
