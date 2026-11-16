import Foundation
import ImageIO
import UIKit

// 评论发图：向抖音要 ImageX 临时凭证，把图传上去；发评论时再带上 image_uri_list 等字段（见 publishComment）。

/// 选好、处理好、等着发的一张评论图片
struct DYCommentImageDraft: Equatable {
    let data: Data
    let fileName: String
    let measured: DYImageXUploadResult
    let preview: UIImage
}

enum DYCommentImagePrep {
    /// 网页评论框的限制：单张不超过 10MB，宽高各不超过 10000
    static let maxEdge = 10_000
    /// 需要重新编码时缩到这个边长以内（手机原图动辄 4000 多像素，评论里用不上）
    static let reencodeEdge = 2_560

    /// 把相册给的原始文件变成能传的图。JPEG / PNG 且没超限的原样用；HEIC、GIF、超限的转成 JPEG。解不出来返回 nil。
    nonisolated static func prepare(_ raw: Data) -> DYCommentImageDraft? {
        guard let src = CGImageSourceCreateWithData(raw as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, pw > 0, ph > 0
        else { return nil }
        func thumb(_ edge: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // 把拍照方向转正
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ] as CFDictionary)
        }
        guard let small = thumb(240) else { return nil }
        let preview = UIImage(cgImage: small)
        let type = (CGImageSourceGetType(src) as String?) ?? ""
        let passthrough: [String: String] = ["public.jpeg": "jpeg", "public.png": "png"]
        if let format = passthrough[type], raw.count <= DYImageXRequests.maxBytes, max(pw, ph) <= maxEdge {
            return DYCommentImageDraft(data: raw, fileName: "comment." + (format == "jpeg" ? "jpg" : "png"),
                                       measured: DYImageXUploadResult(uri: "", width: pw, height: ph, format: format), preview: preview)
        }
        for (edge, quality) in [(reencodeEdge, 0.85), (reencodeEdge, 0.6), (1_600, 0.7)] as [(Int, CGFloat)] {
            guard let cg = thumb(edge), let data = UIImage(cgImage: cg).jpegData(compressionQuality: quality) else { continue }
            if data.count <= DYImageXRequests.maxBytes {
                return DYCommentImageDraft(data: data, fileName: "comment.jpg",
                                           measured: DYImageXUploadResult(uri: "", width: cg.width, height: cg.height, format: "jpeg"),
                                           preview: preview)
            }
        }
        return nil
    }
}

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
