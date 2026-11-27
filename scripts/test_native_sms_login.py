#!/usr/bin/env python3
"""原生手机号登录（DouDuo N / 豹子）：字段必须照 2026-11-28 真机抓到的官方登录页请求，静态检查别被改丢。"""
import pathlib, sys
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
login = (R / "DYNativeLogin.swift").read_text()
pp = (R / "DYPassport.swift").read_text()
ui = (R / "DYAppLogin.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

send = login[login.index("func sendSmsCode"):login.index("private func startSmsCooldown")]
check('("is6Digits", "1")' in send and 'Self.xor5Hex("24")' in send and '("fixed_mix_mode", "1")' in send, "send_code 表单：is6Digits / type=xor5(24) / fixed_mix_mode")
check("bindKey: false" in send, "send_code 不带绑定公钥头（官方也不带）")
sms = login[login.index("func smsLogin"):login.index("func cancel()")]
check('("service", DYPassport.host)' in sms and 'Self.xor5Hex(code)' in sms, "sms_login 表单：service + code=xor5")
check("bindKey: true" in sms, "sms_login 带 bd-ticket-guard-ree-public-key（公钥在这一步绑定）")
check("completeLogin(" in sms and "pushToWebKit()" in sms, "登录后跟扫码一样坐实会话并灌进网页")
check('"+86 " + phone' in login, "手机号按官方格式「+86 1xxxxxxxxxx」再 XOR")
check("DYNativeTicket.prepareLogin()" in login[login.index("func prepareSms"):], "手机号登录前同样生成并登记 App 自己的密钥")
q = pp[pp.index("static func smsQuery"):]
q = q[:q.index("\n    }\n")]
check('"sign"' not in q and '"qs"' not in q and "DYABogus.sign" in q, "send_code/sms_login 的 query 不带 sign/qs，只带 a_bogus")
check('"bd-ticket-guard-web-sign-type": "0"' in pp, "登录绑定头 sign-type=0")
check("nativeLogin.sendSmsCode" in ui and "nativeLogin.smsLogin" in ui, "原生包登录页手机号走原生")
check("@State private var mode: Mode = .code" in ui, "登录页默认手机号（不再一打开就清会话轮询二维码）")
sys.exit(1 if fails else 0)
