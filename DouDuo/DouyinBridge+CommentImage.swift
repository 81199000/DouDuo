import Foundation

// 评论发图的前两步：向抖音要 ImageX 临时凭证，再把图传上去。
// 第三步（发评论时带上 image_uri_list 等字段）还没接，等探针在登录态下把前两步跑通再做。

private struct DYUploadAuthResp: Decodable {
    let status: Int
    let code: Int?
    let msg: String?
    let ak: String?
    let sk: String?
    let token: String?
    let sid: String?
    let now: Double?
}

extension DouyinBridge {
    /// 评论图片的上传凭证（GET /aweme/v1/web/comment/upload/auth/）。凭证几分钟就过期，每次发图现取，不缓存、不写日志。
    func commentUploadCredential() async throws -> DYImageXCredential {
        let d = try await call(Self.commentUploadAuthJS, args: [:], attempts: 1)
        let r = try JSONDecoder().decode(DYUploadAuthResp.self, from: d)
        if r.code == 8 { throw DYError.bad("抖音未登录：登录后才能发图片评论") }
        guard r.status == 200 else { throw DYError.blocked(r.msg ?? "HTTP \(r.status)") }
        guard (r.code ?? -1) == 0,
              let ak = r.ak, !ak.isEmpty, let sk = r.sk, !sk.isEmpty,
              let token = r.token, !token.isEmpty, let sid = r.sid, !sid.isEmpty
        else { throw DYError.bad(r.msg?.isEmpty == false ? r.msg! : "抖音没给图片上传凭证（\(r.code ?? -1)）") }
        return DYImageXCredential(accessKeyID: ak, secretAccessKey: sk, sessionToken: token, serviceID: sid,
                                  serverTime: r.now.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
    }

    /// 取凭证并上传一张评论图片，返回发评论要用的 uri / 宽高 / 格式。
    /// data 是编码好的图片文件（不超过 10MB）；measured 是本地量的宽高和格式，ImageX 没回时兜底。
    func uploadCommentImage(_ data: Data, fileName: String, measured: DYImageXUploadResult? = nil) async throws -> DYImageXUploadResult {
        guard data.count <= DYImageXRequests.maxBytes else { throw DYImageXError.tooLarge }
        let me = try await selfProfile()
        let cred = try await commentUploadCredential()
        return try await DYImageXUploader.upload(data, fileName: fileName, userID: me.uid, cred: cred,
                                                 measured: measured, userAgent: DouyinWeb.userAgent)
    }

    static let commentUploadAuthJS = #"""
    const r = await req('GET', '/aweme/v1/web/comment/upload/auth/?' + q({ content_type: '0' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null,
      ak: d.access_key || null, sk: d.secret_key || null, token: d.session_token || null,
      sid: d.service_id ? String(d.service_id) : null, now: Number(d.current_time) || 0 });
    """#
}
