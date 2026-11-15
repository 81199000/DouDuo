#!/usr/bin/env python3
"""Execute production geometry; open/half-open/narrow panes must remain centered."""
from pathlib import Path
import re, os, subprocess
root=Path(__file__).resolve().parents[1]
s=(root/'DouDuo/DouyinDuoLayout.swift').read_text()
f=re.search(r'    static func closedPortraitVideoOffset\(.*?\n    }',s,re.S).group()
code='import Foundation\nenum M {\n'+f+'\n}\n'+'''let pane = CGSize(width: 466, height: 678)
precondition(M.closedPortraitVideoOffset(viewport: pane, videoAspect: 0.5625, fills: false, isDuo: true, isClosed: true) < 0)
for p in [pane, CGSize(width:669,height:951), CGSize(width:430,height:800)] {
 precondition(M.closedPortraitVideoOffset(viewport:p, videoAspect:0.5625, fills:false, isDuo:true, isClosed:false) == 0)
}
precondition(M.closedPortraitVideoOffset(viewport:pane, videoAspect:1.77, fills:false, isDuo:true, isClosed:true) == 0)
precondition(M.closedPortraitVideoOffset(viewport:pane, videoAspect:0.5625, fills:true, isDuo:true, isClosed:true) == 0)
print("PASS closed-only alignment; unfolded portrait, narrow split panes, landscape and fill unchanged")
'''
p=Path(os.environ['TMPDIR'])/'closed-video-alignment.swift';p.write_text(code)
subprocess.run(['swift',str(p)],check=True)
assert '.onHingeChange' in s and 'context.hinge?.status == .closed' in s
# 回归闸门：铰链状态只能在根视图读一次再经环境下发。每个视频页各自 onHingeChange 时，
# 只有启动那一页收到回调，滑出来的新页永远居中（1.5.0 / 1.5.1 真机「合屏没靠左」）。
mod = re.search(r'struct DYClosedPortraitAlignment.*?\n}\n', s, re.S).group()
assert 'onHingeChange' not in mod and '@Environment(\\.dyHingeClosed)' in mod, 'DYClosedPortraitAlignment 不许自己监听铰链'
app = (root/'DouDuo/DouDuoApp.swift').read_text()
assert '.modifier(DYHingeStateRoot())' in app, 'App 根视图必须挂 DYHingeStateRoot'
print("PASS hinge state read once at app root")
