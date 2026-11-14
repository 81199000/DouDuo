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
