#!/usr/bin/env python3
"""Execute production Swift send/reconciliation/recovery against local transport seams.
No simulator, account requests, or real writes. UI wiring guards supplement behavior tests.
"""
import os, pathlib, re, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
extras = (root/'DouDuo/DouyinExtras.swift').read_text()
feed = (root/'DouDuo/DouyinFeedView.swift').read_text()
relogin = (root/'DouDuo/DYRelogin.swift').read_text()
def section(s, begin, end):
    return s[s.index(begin):s.index(end, s.index(begin))]
models = section(feed, 'struct DYComment:', '/// 评论里的一张图') + section(feed, 'struct DYCommentImage:', '\n}', ) + '\n}'
methods = section(extras, '    func publishComment(', '    /// 删除评论')
recovery = section(relogin, '@MainActor\nenum DYRelogin', '\nstruct DYReloginSheet')
verify_method = section(relogin, '    @MainActor private func verify()', '\n}\n\nextension View').replace('private func verify', 'func verify')
send_method = section(feed, '    private func send() async {', '    private func row(').replace('private func send()', 'func send()')
messages = (root/'DouDuo/DouyinMessages.swift').read_text()
reply_method = section(messages, '    private func sendReply() async {', '    private func showToast(').replace('private func sendReply()', 'func sendReply()')
# View structs permit implicit self; the harness stores their @State equivalents in a class.
send_method = send_method.replace('DYRelogin.start { showRelogin = true }', 'DYRelogin.start { [self] in showRelogin = true }')
reply_method = reply_method.replace('DYRelogin.start { showRelogin = true }', 'DYRelogin.start { [self] in showRelogin = true }')
response_match = re.search(r'private struct DYPublishResp[^\n]+', extras)
once_flag = re.search(r'@MainActor final class DYOnceFlag[^\n]+', extras)[0]
assert response_match
response = response_match[0]
swift = r'''
import Foundation
struct DYImageXUploadResult { let uri: String; let width: Int; let height: Int; let format: String }
struct DYUser { let name: String; let secUid: String; let uid: String }
enum DYError: Error { case bad(String) }
struct DYLoginExpired: Error {}
@MainActor enum DYLiveModel { static var lines = [String](); static func log(_ s: String) { lines.append(s) } }
@MainActor final class DYAccountStore { static let shared = DYAccountStore(); var clears = 0, remembers = 0; func signOut() async { clears += 1 }; func remember(_ u: DYUser) async { remembers += 1 } }
@MainActor final class DouyinBridge {
 static let publishJS = "publish"
 var ready = true, writes = 0
 var profile: DYUser? = DYUser(name: "same", secUid: "self", uid: "100")
 var payload = "", tops = [DYComment](), floors = [String:[DYComment]](), readFloors = [String](), readDelayMs = 0
 func ensureWriteReady() async -> Bool { ready }
 func reload() {}
 func uploadCommentImage(_ data: Data, fileName: String, measured: Int) async throws -> DYImageXUploadResult { DYImageXUploadResult(uri:"private",width:1,height:1,format:"jpeg") }
 func selfProfile() async throws -> DYUser { guard let profile else { throw DYError.bad("missing") }; return profile }
 func call(_ s: String, args: [String:Any], attempts: Int) async throws -> Data { writes += 1; try? await Task.sleep(for:.milliseconds(150)); return Data(payload.utf8) }
 func fetchComments(_ a: String, cursor: Int) async throws -> (items:[DYComment], cursor:Int, hasMore:Bool) { if readDelayMs > 0 { try? await Task.sleep(for:.milliseconds(readDelayMs)) }; return (tops,0,false) }
 func fetchReplies(_ a: String, commentID: String, cursor: Int) async throws -> (items:[DYComment], cursor:Int, hasMore:Bool) { readFloors.append(commentID); return (floors[commentID] ?? [],0,false) }
'''+methods+r'''
}
'''+models+'\n'+response+'\n'+once_flag+'\n'+recovery+r'''
@MainActor final class RecoveryScreen {
 let bridge: DouyinBridge
 var busy = false, message = ""
 var verified = false
 init(_ b: DouyinBridge) { bridge = b }
 func onVerified(_ ok: Bool) { verified = ok }
'''+verify_method+r'''
}
struct DraftImage { let data = Data(); let fileName = "image"; let measured = 1 }
struct Video { let id = "video" }
struct Notice { let id = "notice"; let awemeID: String? = "video"; let cid: String? = "222"; let parentCid: String? = "111" }
@MainActor final class Composer {
 let bridge: DouyinBridge
 let aweme = Video()
 var draft = " exact text ", replyDraft = " exact reply ", imageLoading = false, sending = false, replySending = false
 var imageDraft: DraftImage? = DraftImage(), imageUploaded: DYImageXUploadResult?
 var replyTo: DYComment?, replyParent: String? = "111", inputFocused = true, replyFocused = true, showRelogin = false
 var items = [DYComment](), replies = [String:[DYComment]](), total = 0, replied = Set<String>()
 var sendErr: String?, replyErr: String?, replying: Notice? = Notice()
 var hasCommentContent: Bool { !draft.isEmpty || imageDraft != nil }
 init(_ b: DouyinBridge) { bridge = b }
 func clearCommentImage() { imageDraft = nil; imageUploaded = nil }
 func closeReply() { replying = nil; replyDraft = "" }
 func showToast(_ text: String) {}
'''+send_method+reply_method+r'''
}
@main struct Tests {
 @MainActor static func main() async {
  var failures = 0, checks = 0
  func check(_ b: Bool, _ name: String) { checks += 1; if b { print("PASS " + name) } else { failures += 1; print("FAIL " + name) } }
  func candidate(text: String = "exact text", sec: String? = "self", age: Double = 0.1, parent: String? = nil) -> DYComment {
   DYComment(id:"123456",text:text,name:"same",avatar:nil,digg:0,time:Date().timeIntervalSince1970+age,replies:1,ip:nil,sec:sec,parent:parent)
  }
  func bridge(_ code: String = "null", _ cid: String? = nil) -> DouyinBridge {
   let b=DouyinBridge(); b.payload = "{\"status\":200,\"code\":"+code+",\"comment\":"+(cid.map { "{\"id\":\""+$0+"\",\"text\":\"exact text\",\"name\":\"same\",\"digg\":0,\"time\":1,\"replies\":0}" } ?? "null")+"}"; return b
  }
  func accepted(_ b: DouyinBridge, text: String = "exact text", reply: String? = nil, to: String? = nil, image: DYImageXUploadResult? = nil) async -> Bool {
   do { _ = try await b.publishComment("video",text:text,replyID:reply,replyToReplyID:to,image:image); return true } catch { return false }
  }
  let unready=bridge("0","123"); unready.ready=false
  let unreadyAccepted=await accepted(unready)
  check(!unreadyAccepted && unready.writes==0,"native not-ready blocks every write")
  for cid in ["", "0", "undefined", "null", "local-fake"] {
   check(!(await accepted(bridge("0",cid))),"invalid acknowledgement ID rejected: "+cid)
  }
  check(!(await accepted(bridge("null","123"))),"missing business code is not success")
  check(await accepted(bridge("0","123")),"explicit code zero with real ID accepted")
  let mine=bridge(); mine.tops=[candidate()]
  check(await accepted(mine),"recent exact self comment may reconcile")
  let sameSecond=bridge(); sameSecond.tops=[candidate(age:-0.01)]
  check(!(await accepted(sameSecond)),"pre-send own comment in same second cannot reconcile")
  let sdkBlocked=bridge(); sdkBlocked.payload="{\"status\":-4,\"code\":null}"; sdkBlocked.tops=[candidate()]
  check(!(await accepted(sdkBlocked)),"JS readiness rejection never reconciles as sent")
  for (label,c) in [("other author",candidate(sec:"other")),("unknown author",candidate(sec:nil)),("old own comment",candidate(age:-90)),("prefix text",candidate(text:"exact text plus")),("whitespace change",candidate(text:"exacttext")),("future time",candidate(age:300)),("other floor",candidate(parent:"999"))] {
   let b=bridge(); b.tops=[c]; check(!(await accepted(b)),label+" cannot reconcile")
  }
  let noIdentity=bridge(); noIdentity.profile=nil; noIdentity.tops=[candidate()]
  check(!(await accepted(noIdentity)),"missing self identity stays unknown")
  let wrongFloor=bridge(); wrongFloor.tops=[candidate()]; wrongFloor.floors["999"]=[candidate()]
  check(!(await accepted(wrongFloor,reply:"111")) && wrongFloor.readFloors==["111"],"reply does not search other floors or top level")
  let wrongNested=bridge(); wrongNested.floors["111"]=[candidate(parent:"111")]
  check(!(await accepted(wrongNested,reply:"111",to:"222")),"nested reply requires exact target metadata")
  let image=DYImageXUploadResult(uri:"private-image",width:1,height:1,format:"jpeg")
  let oldImage=bridge(); var c=candidate(age:-90); c.images=[DYCommentImage(thumb:"t",full:"f",w:1,h:1)]; oldImage.tops=[c]
  check(!(await accepted(oldImage,image:image)),"old image comment cannot reconcile")
  let pureImage=bridge(); var pure=candidate(text:""); pure.images=c.images; pureImage.tops=[pure]
  check(!(await accepted(pureImage,text:"",image:image)),"pure image ambiguous reconciliation stays unknown")
  // 回查读接口被压住时，界面必须在时限内结束，不能一直转圈
  DouyinBridge.reconcileTimeout = 0.3
  let slow=bridge(); slow.readDelayMs=3000; slow.tops=[candidate()]
  let t0=Date(); let slowAccepted=await accepted(slow)
  check(!slowAccepted && Date().timeIntervalSince(t0) < 1.5 && slow.writes==1,"stalled reconcile ends within timeout as unknown, no resend")
  DouyinBridge.reconcileTimeout = 8
  // 403 空响应且回查无果：按被拦截处理（进入恢复选择），不清登录、不重发
  let blocked=DouyinBridge(); blocked.payload="{\"status\":403,\"code\":null,\"comment\":null}"
  var blockedIsRecovery=false
  do { _ = try await blocked.publishComment("video",text:"exact text") } catch is DYLoginExpired { blockedIsRecovery=true } catch {}
  check(blockedIsRecovery && blocked.writes==1 && DYAccountStore.shared.clears==0,"403 empty response routes to recovery without retry or sign-out")
  let blockedButPosted=DouyinBridge(); blockedButPosted.payload=blocked.payload; blockedButPosted.tops=[candidate()]
  check(await accepted(blockedButPosted),"403 that actually posted is still confirmed by strict reconcile")
  let rejected=bridge("8"); check(!(await accepted(rejected)) && rejected.writes==1,"code8 rejected without retry")
  var presented=false
  DYRelogin.start { presented=true }
  try? await Task.sleep(for:.milliseconds(30))
  check(presented && DYAccountStore.shared.clears==0,"code8 recovery preserves login without explicit consent")
  let composer=Composer(bridge("8")); composer.replyTo=candidate()
  await composer.send()
  check(composer.draft==" exact text " && composer.imageDraft != nil && composer.imageUploaded != nil && composer.replyTo != nil && composer.replyParent=="111" && composer.showRelogin,"production comment composer keeps text, image, upload, and reply target on code8")
  let noticeComposer=Composer(bridge("8")); await noticeComposer.sendReply()
  check(noticeComposer.replyDraft==" exact reply " && noticeComposer.replying != nil && noticeComposer.showRelogin && noticeComposer.replied.isEmpty,"production notice reply keeps draft and target on code8")
  let unknownComposer=Composer(bridge()); await unknownComposer.send()
  check(unknownComposer.draft==" exact text " && unknownComposer.imageDraft != nil && unknownComposer.items.isEmpty,"unknown result preserves composer and adds no fake comment")
  let recoveryBridge=bridge(); recoveryBridge.profile=nil
  let screen=RecoveryScreen(recoveryBridge); await screen.verify()
  check(!screen.verified && DYAccountStore.shared.remembers==0,"recovery callback rejects unreadable self profile regardless of old cookie")
  recoveryBridge.profile=DYUser(name:"same",secUid:"self",uid:"100"); await screen.verify()
  check(screen.verified && DYAccountStore.shared.remembers==1,"recovery callback succeeds only after actual self profile read")
  check(!DYLiveModel.lines.joined().contains("exact text"),"phase logs omit comment body")
  print("Swift behavior checks=\(checks) failures=\(failures)")
  if failures>0 { exit(1) }
 }
}
'''
with tempfile.TemporaryDirectory(prefix='comment-recovery-', dir=os.environ['TMPDIR']) as d:
    p=pathlib.Path(d); (p/'Tests.swift').write_text(swift)
    subprocess.run(['swiftc','-parse-as-library',str(p/'Tests.swift'),'-o',str(p/'tests')],check=True)
    result = subprocess.run([str(p/'tests')])
    if result.returncode: raise SystemExit(result.returncode)
# Supplemental UI wiring: only the confirmed-success path may clear composer state.
for filename, marker, end, draft in [('DouyinFeedView.swift','} catch is DYLoginExpired','private func row','draft'),('DouyinMessages.swift','} catch is DYLoginExpired','private func showToast','replyDraft')]:
    s=(root/'DouDuo'/filename).read_text(); block=section(s,marker,end)
    assert not re.search(r'\b'+draft+r'\s*=',block), 'recovery must preserve draft'
    assert 'clearCommentImage()' not in block and 'closeReply()' not in block
    assert '登录已失效' not in block
assert 'DYLoginState.hasSession()' not in relogin, 'cookie presence cannot validate recovery'
assert '.confirmationDialog(' in relogin, 'destructive cleanup requires explicit confirmation'
assert 'DouyinWebScreen' in relogin, 'preserved-session validation must be reachable'
print('PASS recovery UI wiring, draft retention, explicit cleanup consent')
