import Foundation
import CryptoKit

// 评论发图的图片上传（火山 ImageX），照网页版评论输入框用的上传器实现：
//   1. GET  imagex.bytedanceapi.com/?Action=ApplyImageUpload   —— 用临时凭证做 AWS4 签名，换上传地址
//   2. POST https://<UploadHosts[0]>/upload/v1/<StoreUri>       —— 传文件本体，头里带 CRC32
//   3. POST imagex.bytedanceapi.com/?Action=CommitImageUpload  —— 提交，拿到图片 Uri / 宽高 / 格式
// 临时凭证来自抖音接口 /aweme/v1/web/comment/upload/auth/（见 DouyinBridge+CommentImage.swift）。
// 本文件只依赖 Foundation + CryptoKit，不碰界面和网页桥，scripts/test_imagex_upload.py 会单独编译它跑测试。

/// ImageX 临时凭证。只在内存里用：不落盘、不进日志。
struct DYImageXCredential: Equatable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String
    let serviceID: String
    /// 服务端时间 − 本机时间（秒）。本机钟差超过一分钟时签名会被拒，用它校正；差得不多就是 0。
    let clockOffset: TimeInterval

    init(accessKeyID: String, secretAccessKey: String, sessionToken: String, serviceID: String,
         serverTime: Date? = nil, localTime: Date = Date()) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.serviceID = serviceID
        if let serverTime {
            let gap = serverTime.timeIntervalSince(localTime)
            clockOffset = abs(gap) > 60 ? gap : 0
        } else {
            clockOffset = 0
        }
    }

    func signingDate(_ now: Date = Date()) -> Date { now.addingTimeInterval(clockOffset) }
}

/// 上传完成后 ImageX 给的图片信息；发评论时原样填进 image_uri_list / image_widths / image_heights / image_formats。
struct DYImageXUploadResult: Equatable {
    let uri: String
    let width: Int
    let height: Int
    let format: String
}

/// 第 1 步换回来的上传地址
struct DYImageXUploadAddress: Equatable {
    let host: String
    let storeURI: String
    let auth: String
    let sessionKey: String
    let extraHeaders: [String: String]
}

enum DYImageXError: LocalizedError, Equatable {
    case tooLarge
    case empty
    case http(step: String, status: Int)
    case server(step: String, code: String, message: String)
    case malformed(step: String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: "图片超过 10MB，抖音不收"
        case .empty: "图片是空的"
        case .http(let step, let status): "图片上传失败（\(step) HTTP \(status)）"
        case .server(let step, let code, let message): "图片上传失败（\(step) \(code)\(message.isEmpty ? "" : "：" + message)）"
        case .malformed(let step): "图片上传失败（\(step) 返回的数据看不懂）"
        }
    }
}

// MARK: - AWS4 签名

/// AWS Signature V4。ImageX 网关用的就是这一套（region cn-north-1，service imagex）。
/// 传进来的头里，除排除表之外都参与签名——网页上传器只签它自己设的 x-amz-* 头（不含 host），这里照做。
enum DYAWS4 {
    static let algorithm = "AWS4-HMAC-SHA256"
    private static let unsignable: Set<String> = [
        "authorization", "content-type", "content-length", "user-agent", "presigned-expires", "expect", "x-amzn-trace-id",
    ]

    /// 20261117T015300Z
    static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// RFC 3986：只有字母、数字和 - _ . ~ 不转义
    static func encode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                out += "%" + (b < 16 ? "0" : "") + String(b, radix: 16, uppercase: true)
            }
        }
        return out
    }

    /// 键按字节序排好、键值都转义后拼成 a=1&b=2
    static func canonicalQuery(_ params: [String: String]) -> String {
        params.map { (encode($0.key), encode($0.value)) }
            .sorted { $0.0 == $1.0 ? $0.1.utf8.lexicographicallyPrecedes($1.1.utf8) : $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func signable(_ headers: [String: String]) -> [(name: String, value: String)] {
        headers.map { (name: $0.key.lowercased(), value: $0.value) }
            .filter { $0.name.hasPrefix("x-amz-") || !unsignable.contains($0.name) }
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    static func signedHeaders(_ headers: [String: String]) -> String {
        signable(headers).map(\.name).joined(separator: ";")
    }

    static func canonicalRequest(method: String, path: String, query: [String: String], headers: [String: String]) -> String {
        let signed = signable(headers)
        let canonicalHeaders = signed.map { h in
            let value = h.value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return "\(h.name):\(value)"
        }.joined(separator: "\n")
        let bodyHash = headers.first { $0.key.lowercased() == "x-amz-content-sha256" }?.value ?? sha256Hex(Data())
        return [
            method.uppercased(),
            path.isEmpty ? "/" : path,
            canonicalQuery(query),
            canonicalHeaders + "\n",
            signed.map(\.name).joined(separator: ";"),
            bodyHash,
        ].joined(separator: "\n")
    }

    /// 返回 Authorization 头的值。headers 里必须已经放好 X-Amz-Date（值与 amzDate 一致）。
    static func authorization(method: String, path: String, query: [String: String], headers: [String: String],
                              accessKeyID: String, secretAccessKey: String, region: String, service: String,
                              amzDate: String) -> String {
        let day = String(amzDate.prefix(8))
        let scope = [day, region, service, "aws4_request"].joined(separator: "/")
        let request = canonicalRequest(method: method, path: path, query: query, headers: headers)
        let toSign = [algorithm, amzDate, scope, sha256Hex(Data(request.utf8))].joined(separator: "\n")
        var key = hmac(Data(("AWS4" + secretAccessKey).utf8), day)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hex(hmac(key, toSign))
        return "\(algorithm) Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders(headers)), Signature=\(signature)"
    }
}

// MARK: - CRC32

enum DYCRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// 上传头 Content-CRC32 要的写法：8 位小写十六进制，不足补零
    static func hex(_ data: Data) -> String {
        let s = String(checksum(data), radix: 16)
        return String(repeating: "0", count: 8 - s.count) + s
    }
}

// MARK: - 三个请求怎么拼、回包怎么读（纯函数，方便单测）

enum DYImageXRequests {
    static let gateway = "https://imagex.bytedanceapi.com"
    static let region = "cn-north-1"
    static let service = "imagex"
    static let apiVersion = "2018-08-01"
    /// 网页版选图时的上限
    static let maxBytes = 10 * 1024 * 1024

    private static func signedGatewayRequest(method: String, query: [String: String], body: Data?,
                                             cred: DYImageXCredential, now: Date) -> URLRequest {
        let date = DYAWS4.amzDate(cred.signingDate(now))
        var headers = ["X-Amz-Date": date, "x-amz-security-token": cred.sessionToken]
        if let body { headers["X-Amz-Content-Sha256"] = DYAWS4.sha256Hex(body) }
        headers["Authorization"] = DYAWS4.authorization(
            method: method, path: "/", query: query, headers: headers,
            accessKeyID: cred.accessKeyID, secretAccessKey: cred.secretAccessKey,
            region: region, service: service, amzDate: date)
        var req = URLRequest(url: URL(string: gateway + "/?" + DYAWS4.canonicalQuery(query))!)
        req.httpMethod = method
        req.timeoutInterval = 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// 第 1 步：申请上传地址。nonce 是随便一串字母数字（网页版每次随机）。
    static func apply(cred: DYImageXCredential, fileSize: Int, nonce: String, now: Date = Date()) -> URLRequest {
        let query = [
            "Action": "ApplyImageUpload", "Version": apiVersion, "ServiceId": cred.serviceID,
            "NeedFallback": "true", "FileSize": String(fileSize), "s": nonce,
        ]
        return signedGatewayRequest(method: "GET", query: query, body: nil, cred: cred, now: now)
    }

    static func parseApply(_ data: Data) throws -> DYImageXUploadAddress {
        let root = try object(data, step: "申请")
        try throwIfError(root, step: "申请")
        guard let address = (root["Result"] as? [String: Any])?["UploadAddress"] as? [String: Any],
              let host = (address["UploadHosts"] as? [String])?.first, !host.isEmpty,
              let store = (address["StoreInfos"] as? [[String: Any]])?.first,
              let uri = store["StoreUri"] as? String, !uri.isEmpty,
              let auth = store["Auth"] as? String, !auth.isEmpty,
              let sessionKey = address["SessionKey"] as? String, !sessionKey.isEmpty
        else { throw DYImageXError.malformed(step: "申请") }
        var extra: [String: String] = [:]
        if let h = address["UploadHeader"] as? [String: Any] {
            for (k, v) in h { if let s = v as? String { extra[k] = s } }
        }
        return DYImageXUploadAddress(host: host, storeURI: uri, auth: auth, sessionKey: sessionKey, extraHeaders: extra)
    }

    /// 第 2 步：把文件本体传到存储节点
    static func upload(address: DYImageXUploadAddress, data: Data, fileName: String, userID: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(address.host)/upload/v1/\(address.storeURI)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        for (k, v) in address.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(address.auth, forHTTPHeaderField: "Authorization")
        req.setValue(DYCRC32.hex(data), forHTTPHeaderField: "Content-CRC32")
        req.setValue(DYAWS4.encode(userID), forHTTPHeaderField: "X-Storage-U")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("attachment; filename=\"\(DYAWS4.encode(fileName))\"", forHTTPHeaderField: "Content-Disposition")
        return req
    }

    /// 存储节点成功时回 {"code":2000,...}
    static func checkUpload(_ data: Data) throws {
        let root = try object(data, step: "传图")
        let code = (root["code"] as? NSNumber)?.intValue ?? -1
        guard code == 2000 else {
            throw DYImageXError.server(step: "传图", code: String(code), message: (root["message"] as? String) ?? "")
        }
    }

    /// 第 3 步：提交
    static func commit(cred: DYImageXCredential, sessionKey: String, now: Date = Date()) -> URLRequest {
        let query = ["Action": "CommitImageUpload", "Version": apiVersion, "ServiceId": cred.serviceID]
        let body = (try? JSONSerialization.data(withJSONObject: ["SessionKey": sessionKey])) ?? Data()
        return signedGatewayRequest(method: "POST", query: query, body: body, cred: cred, now: now)
    }

    /// 宽高、格式以 ImageX 回的为准；它没回时用调用方自己量的（fallback）。
    static func parseCommit(_ data: Data, fallback: DYImageXUploadResult? = nil) throws -> DYImageXUploadResult {
        let root = try object(data, step: "提交")
        try throwIfError(root, step: "提交")
        guard let result = root["Result"] as? [String: Any],
              var info = (result["Results"] as? [[String: Any]])?.first
        else { throw DYImageXError.malformed(step: "提交") }
        if let plugin = (result["PluginResult"] as? [[String: Any]])?.first {
            info.merge(plugin) { _, new in new }
        }
        guard let uri = (info["Uri"] as? String) ?? (info["ImageUri"] as? String), !uri.isEmpty else {
            throw DYImageXError.malformed(step: "提交")
        }
        let width = (info["ImageWidth"] as? NSNumber)?.intValue ?? fallback?.width ?? 0
        let height = (info["ImageHeight"] as? NSNumber)?.intValue ?? fallback?.height ?? 0
        let format = (info["ImageFormat"] as? String) ?? fallback?.format ?? ""
        return DYImageXUploadResult(uri: uri, width: width, height: height, format: format)
    }

    private static func object(_ data: Data, step: String) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DYImageXError.malformed(step: step)
        }
        return root
    }

    private static func throwIfError(_ root: [String: Any], step: String) throws {
        guard let error = (root["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any] else { return }
        let code = (error["Code"] as? String) ?? (error["CodeN"] as? NSNumber)?.stringValue ?? "?"
        throw DYImageXError.server(step: step, code: code, message: (error["Message"] as? String) ?? "")
    }
}

// MARK: - 真正发请求

enum DYImageXUploader {
    /// 把一张图传到 ImageX。data 是已经编码好的图片文件（JPEG / PNG / WebP …），不超过 10MB。
    /// measured 是调用方自己量的宽高和格式，ImageX 没回这些字段时拿来兜底。
    /// origin / userAgent 让请求和网页里发出的一样（接口是给 www.douyin.com 页面用的）。
    static func upload(_ data: Data, fileName: String, userID: String, cred: DYImageXCredential,
                       measured: DYImageXUploadResult? = nil,
                       origin: String = "https://www.douyin.com", userAgent: String? = nil,
                       session: URLSession = .shared) async throws -> DYImageXUploadResult {
        guard !data.isEmpty else { throw DYImageXError.empty }
        guard data.count <= DYImageXRequests.maxBytes else { throw DYImageXError.tooLarge }

        func send(_ request: URLRequest, body: Data? = nil, step: String) async throws -> Data {
            var req = request
            req.setValue(origin, forHTTPHeaderField: "Origin")
            req.setValue(origin + "/", forHTTPHeaderField: "Referer")
            if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            let (payload, response): (Data, URLResponse)
            if let body {
                (payload, response) = try await session.upload(for: req, from: body)
            } else {
                (payload, response) = try await session.data(for: req)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                // 网关报错时 body 里有错误码，比光一个状态码有用
                if let _ = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    if step == "传图" { try DYImageXRequests.checkUpload(payload) }
                    else if step == "申请" { _ = try DYImageXRequests.parseApply(payload) }
                    else { _ = try DYImageXRequests.parseCommit(payload) }
                }
                throw DYImageXError.http(step: step, status: status)
            }
            return payload
        }

        let nonce = String(UInt64.random(in: 0...UInt64.max), radix: 36)
        let applied = try await send(DYImageXRequests.apply(cred: cred, fileSize: data.count, nonce: nonce), step: "申请")
        let address = try DYImageXRequests.parseApply(applied)

        let uploaded = try await send(
            DYImageXRequests.upload(address: address, data: data, fileName: fileName, userID: userID),
            body: data, step: "传图")
        try DYImageXRequests.checkUpload(uploaded)

        let committed = try await send(DYImageXRequests.commit(cred: cred, sessionKey: address.sessionKey), step: "提交")
        return try DYImageXRequests.parseCommit(committed, fallback: measured)
    }
}

// MARK: - 自测（不联网）

#if DEBUG || DY_IMAGEX_MAIN
enum DYImageXLogicTests {
    static let fixedCred = DYImageXCredential(accessKeyID: "AKTESTKEY", secretAccessKey: "c2VjcmV0LWZvci10ZXN0cw==",
                                              sessionToken: "STS2token/with+odd=chars", serviceID: "svc123")
    static let fixedNow = Date(timeIntervalSince1970: 1_794_851_580)

    static func run() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        func header(_ r: URLRequest, _ name: String) -> String { r.value(forHTTPHeaderField: name) ?? "" }

        // AWS 官方签名测试集 get-vanilla
        let aws = DYAWS4.authorization(
            method: "GET", path: "/", query: [:],
            headers: ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"],
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1", service: "service", amzDate: "20150830T123600Z")
        check(aws == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
              "AWS get-vanilla 签名不对：\(aws)")

        check(DYAWS4.amzDate(fixedNow) == "20261116T175300Z", "时间格式不对：\(DYAWS4.amzDate(fixedNow))")
        check(DYAWS4.encode("a b*c/d~e_f-g.h'(!)") == "a%20b%2Ac%2Fd~e_f-g.h%27%28%21%29", "转义不对")
        check(DYAWS4.encode("图") == "%E5%9B%BE", "中文转义不对")
        check(DYAWS4.canonicalQuery(["s": "x1", "Version": "2018-08-01", "Action": "ApplyImageUpload", "b": "2", "B": "1"])
              == "Action=ApplyImageUpload&B=1&Version=2018-08-01&b=2&s=x1", "query 排序不对")
        check(DYAWS4.signedHeaders(["X-Amz-Date": "d", "Content-Type": "application/json", "x-amz-security-token": "t",
                                    "User-Agent": "ua", "X-Amz-Content-Sha256": "h"])
              == "x-amz-content-sha256;x-amz-date;x-amz-security-token", "参与签名的头不对")

        check(DYCRC32.hex(Data("123456789".utf8)) == "cbf43926", "CRC32 不对")
        check(DYCRC32.hex(Data()) == "00000000", "空数据 CRC32 应补零到 8 位")
        check(DYCRC32.hex(Data([0x1c, 0xa9])).count == 8, "CRC32 必须是 8 位")

        // 申请
        let apply = DYImageXRequests.apply(cred: fixedCred, fileSize: 34567, nonce: "abc123", now: fixedNow)
        check(apply.httpMethod == "GET", "申请应为 GET")
        check(apply.url?.absoluteString
              == "https://imagex.bytedanceapi.com/?Action=ApplyImageUpload&FileSize=34567&NeedFallback=true&ServiceId=svc123&Version=2018-08-01&s=abc123",
              "申请地址不对：\(apply.url?.absoluteString ?? "nil")")
        check(header(apply, "X-Amz-Date") == "20261116T175300Z", "申请缺 X-Amz-Date")
        check(header(apply, "x-amz-security-token") == fixedCred.sessionToken, "申请缺临时凭证 token")
        check(header(apply, "Authorization").contains("Credential=AKTESTKEY/20261116/cn-north-1/imagex/aws4_request, SignedHeaders=x-amz-date;x-amz-security-token, Signature="),
              "申请的签名范围不对：\(header(apply, "Authorization"))")
        check(header(apply, "X-Amz-Content-Sha256").isEmpty, "GET 不该带 body 摘要")

        // 钟差校正
        let skewed = DYImageXCredential(accessKeyID: "a", secretAccessKey: "b", sessionToken: "c", serviceID: "d",
                                        serverTime: fixedNow.addingTimeInterval(3600), localTime: fixedNow)
        check(skewed.clockOffset == 3600, "钟差超过一分钟应校正")
        check(header(DYImageXRequests.apply(cred: skewed, fileSize: 1, nonce: "n", now: fixedNow), "X-Amz-Date") == "20261116T185300Z",
              "校正后的签名时间不对")
        let near = DYImageXCredential(accessKeyID: "a", secretAccessKey: "b", sessionToken: "c", serviceID: "d",
                                      serverTime: fixedNow.addingTimeInterval(20), localTime: fixedNow)
        check(near.clockOffset == 0, "钟差不到一分钟不校正")

        // 申请回包
        let applyOK = Data(#"{"ResponseMetadata":{"RequestId":"r"},"Result":{"UploadAddress":{"StoreInfos":[{"StoreUri":"tos-cn-i-abc/0123abcd","Auth":"SpaceKey/abc/1/:version:v2:sig","UploadID":""}],"UploadHosts":["tos-up.example.com","tos-up2.example.com"],"UploadHeader":{"X-Extra":"1"},"SessionKey":"SESSION=="}}}"#.utf8)
        let address = try? DYImageXRequests.parseApply(applyOK)
        check(address == DYImageXUploadAddress(host: "tos-up.example.com", storeURI: "tos-cn-i-abc/0123abcd",
                                               auth: "SpaceKey/abc/1/:version:v2:sig", sessionKey: "SESSION==", extraHeaders: ["X-Extra": "1"]),
              "申请回包解析不对")
        let applyNullHeader = Data(#"{"Result":{"UploadAddress":{"StoreInfos":[{"StoreUri":"u","Auth":"a"}],"UploadHosts":["h"],"UploadHeader":null,"SessionKey":"k"}}}"#.utf8)
        check((try? DYImageXRequests.parseApply(applyNullHeader))?.extraHeaders == [:], "UploadHeader 为 null 应当能过")
        let applyErr = Data(#"{"ResponseMetadata":{"Error":{"CodeN":100009,"Code":"AccessDenied","Message":"token expired"}}}"#.utf8)
        do { _ = try DYImageXRequests.parseApply(applyErr); check(false, "申请报错应抛出") }
        catch { check(error as? DYImageXError == .server(step: "申请", code: "AccessDenied", message: "token expired"), "申请报错内容不对：\(error)") }
        do { _ = try DYImageXRequests.parseApply(Data("{}".utf8)); check(false, "空回包应抛出") }
        catch { check(error as? DYImageXError == .malformed(step: "申请"), "空回包应算看不懂") }

        // 传图
        if let address {
            let payload = Data("123456789".utf8)
            let up = DYImageXRequests.upload(address: address, data: payload, fileName: "评论 图.jpg", userID: "12345")
            check(up.httpMethod == "POST", "传图应为 POST")
            check(up.url?.absoluteString == "https://tos-up.example.com/upload/v1/tos-cn-i-abc/0123abcd", "传图地址不对：\(up.url?.absoluteString ?? "nil")")
            check(header(up, "Authorization") == "SpaceKey/abc/1/:version:v2:sig", "传图要用申请回来的 Auth")
            check(header(up, "Content-CRC32") == "cbf43926", "传图缺 CRC32")
            check(header(up, "X-Storage-U") == "12345", "传图缺用户 ID")
            check(header(up, "X-Extra") == "1", "申请回来的附加头要带上")
            check(header(up, "Content-Type") == "application/octet-stream", "传图 Content-Type 不对")
            check(header(up, "Content-Disposition") == "attachment; filename=\"%E8%AF%84%E8%AE%BA%20%E5%9B%BE.jpg\"", "文件名要转义")
        }
        check((try? DYImageXRequests.checkUpload(Data(#"{"code":2000,"message":"Success"}"#.utf8))) != nil, "code 2000 应算成功")
        do { try DYImageXRequests.checkUpload(Data(#"{"code":4001,"message":"crc mismatch"}"#.utf8)); check(false, "传图失败应抛出") }
        catch { check(error as? DYImageXError == .server(step: "传图", code: "4001", message: "crc mismatch"), "传图报错内容不对：\(error)") }

        // 提交
        let commit = DYImageXRequests.commit(cred: fixedCred, sessionKey: "SESSION==", now: fixedNow)
        check(commit.httpMethod == "POST", "提交应为 POST")
        check(commit.url?.absoluteString == "https://imagex.bytedanceapi.com/?Action=CommitImageUpload&ServiceId=svc123&Version=2018-08-01",
              "提交地址不对：\(commit.url?.absoluteString ?? "nil")")
        check(commit.httpBody == Data(#"{"SessionKey":"SESSION=="}"#.utf8), "提交 body 不对")
        check(header(commit, "X-Amz-Content-Sha256") == DYAWS4.sha256Hex(commit.httpBody ?? Data()), "提交要带 body 摘要")
        check(header(commit, "Authorization").contains("SignedHeaders=x-amz-content-sha256;x-amz-date;x-amz-security-token, "), "提交的签名头不对")

        let commitOK = Data(#"{"ResponseMetadata":{},"Result":{"Results":[{"Uri":"tos-cn-i-abc/0123abcd","UriStatus":2000}],"RequestId":"r","PluginResult":[{"FileName":"0123abcd","ImageUri":"tos-cn-i-abc/0123abcd","ImageWidth":1080,"ImageHeight":1440,"ImageMd5":"m","ImageFormat":"jpeg","ImageSize":34567,"FrameCnt":1}]}}"#.utf8)
        check((try? DYImageXRequests.parseCommit(commitOK)) == DYImageXUploadResult(uri: "tos-cn-i-abc/0123abcd", width: 1080, height: 1440, format: "jpeg"),
              "提交回包解析不对")
        let commitBare = Data(#"{"Result":{"Results":[{"Uri":"u1"}]}}"#.utf8)
        let measured = DYImageXUploadResult(uri: "", width: 30, height: 40, format: "png")
        check((try? DYImageXRequests.parseCommit(commitBare, fallback: measured)) == DYImageXUploadResult(uri: "u1", width: 30, height: 40, format: "png"),
              "ImageX 没回宽高时应用自己量的")
        do { _ = try DYImageXRequests.parseCommit(Data(#"{"Result":{"Results":[]}}"#.utf8)); check(false, "没有结果应抛出") }
        catch { check(error as? DYImageXError == .malformed(step: "提交"), "没有结果应算看不懂") }

        return failures
    }
}
#endif

#if DY_IMAGEX_MAIN
@main
struct DYImageXLogicMain {
    static func main() {
        let failures = DYImageXLogicTests.run()
        // 给 scripts/test_imagex_upload.py 拿去和它自己用 hmac 算的结果对账
        let apply = DYImageXRequests.apply(cred: DYImageXLogicTests.fixedCred, fileSize: 34567, nonce: "abc123", now: DYImageXLogicTests.fixedNow)
        print("APPLY_AUTH " + (apply.value(forHTTPHeaderField: "Authorization") ?? ""))
        let commit = DYImageXRequests.commit(cred: DYImageXLogicTests.fixedCred, sessionKey: "SESSION==", now: DYImageXLogicTests.fixedNow)
        print("COMMIT_AUTH " + (commit.value(forHTTPHeaderField: "Authorization") ?? ""))
        if failures.isEmpty {
            print("DYImageXLogicTests passed")
        } else {
            for failure in failures { print("FAIL \(failure)") }
            exit(1)
        }
    }
}
#endif
