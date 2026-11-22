import Foundation

// 「一类」网页接口（老板 2026-11-22 点名先做）：批量管理、收藏夹、收藏合集/音乐、通知删除与点赞名单、
// 评论翻译、关注请求、短链。
// 路径、参数、请求体全部照网页版自己的调用（2026-11-22 从 douyin_web 脚本逐个核对，见 docs/api-inventory.md）。
// 写操作只在用户点了按钮之后才发，不自动重试；回归脚本只在本地假环境里跑，不打真接口。

/// 收藏夹（collects）
struct DYCollectsFolder: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let name: String
    let cover: String?
    let total: Int
    /// 0 公开 / 1 私密
    var secret: Int? = nil
}

/// 收藏的合集（mix）
struct DYMixInfo: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let name: String
    let cover: String?
    let episodes: Int
    let author: String
}

/// 收藏的音乐
struct DYMusicInfo: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let title: String
    let author: String
    let cover: String?
    let duration: Int
    let playURL: String?
}

/// 点赞名单里的人
struct DYPlainUser: Identifiable, Decodable, Equatable, Hashable {
    let uid: String
    let secUid: String
    let name: String
    let avatar: String?
    var id: String { uid.isEmpty ? secUid : uid }
}

/// 批量操作结果：部分失败时 fatalIDs 列出没处理掉的
struct DYBatchResult {
    let result: DYActionResult
    let failedIDs: [String]
}

private struct DYBatchResp: Decodable {
    let status: Int
    let statusCode: Int?
    let msg: String?
    var failed: [String]? = nil
}

private struct DYPageResp<T: Decodable>: Decodable {
    let status: Int
    let code: Int?
    let msg: String?
    let items: [T]
    let cursor: String
    let hasMore: Bool
}

private struct DYTextResp: Decodable {
    let status: Int
    let code: Int?
    let msg: String?
    let text: String?
}

private struct DYCollectsResp: Decodable {
    let status: Int
    let statusCode: Int?
    let msg: String?
    var folder: DYCollectsFolder? = nil
}

extension DouyinBridge {
    // MARK: 通用

    private func writeCall(_ js: String, _ args: [String: Any], tag: String) async throws -> DYManageResp {
        await ensureWriteReady()
        let d = try await call(js, args: args, attempts: 1)
        let r = try JSONDecoder().decode(DYManageResp.self, from: d)
        DYLiveModel.log("DDSEND \(tag) status=\(r.status) code=\(r.statusCode.map(String.init) ?? "nil") msg=\(r.msg ?? "-")")
        return r
    }

    private func page<T: Decodable>(_ js: String, _ args: [String: Any], _: T.Type) async throws -> (items: [T], cursor: String, hasMore: Bool) {
        let d = try await call(js, args: args, attempts: 2)
        let p = try JSONDecoder().decode(DYPageResp<T>.self, from: d)
        if p.code == 8 || (p.msg ?? "").contains("未登录") { throw DYError.bad("抖音未登录：请在「我的」中登录后重试") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        if let c = p.code, c != 0 { throw DYError.bad(p.msg?.isEmpty == false ? p.msg! : "抖音返回 \(c)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 网页版每批最多 50 条，按批发，汇总失败的 id
    private func batch(_ js: String, ids: [String], extra: [String: Any] = [:], tag: String) async throws -> DYBatchResult {
        var failed: [String] = []
        var last: DYActionResult = .ok
        var anyOK = false
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            await ensureWriteReady()
            var args = extra
            args["ids"] = chunk.joined(separator: ",")
            let d = try await call(js, args: args, attempts: 1)
            let r = try JSONDecoder().decode(DYBatchResp.self, from: d)
            DYLiveModel.log("DDSEND \(tag) n=\(chunk.count) status=\(r.status) code=\(r.statusCode.map(String.init) ?? "nil") failed=\(r.failed?.count ?? 0)")
            let res = Self.manageResult(DYManageResp(status: r.status, statusCode: r.statusCode, msg: r.msg))
            switch res {
            case .ok: anyOK = true; failed += r.failed ?? []
            case .notLoggedIn: return DYBatchResult(result: .notLoggedIn, failedIDs: ids)
            case .failed: failed += chunk; last = res
            }
        }
        return DYBatchResult(result: anyOK ? .ok : last, failedIDs: failed)
    }

    // MARK: 我的 · 批量管理

    /// 删除作品 / 改可见范围（aweme/delete/multi，action_type：0 删除 1 公开 2 私密 3 好友可见）
    func manageMyWorks(_ ids: [String], action: DYWorkAction) async throws -> DYBatchResult {
        try await batch(Self.deleteMultiJS, ids: ids, extra: ["action": String(action.rawValue)], tag: "works-\(action)")
    }

    /// 批量取消喜欢（cancel/item/digg/multi，item_type_map：普通 0 / 西瓜 1）
    func cancelLikes(_ items: [DYAweme]) async throws -> DYBatchResult {
        try await batch(Self.cancelDiggMultiJS, ids: items.map(\.id), extra: ["typeMap": Self.typeMap(items)], tag: "unlike-multi")
    }

    /// 批量取消收藏视频（aweme/cancel/collect/multi）
    func cancelCollects(_ items: [DYAweme]) async throws -> DYBatchResult {
        try await batch(Self.cancelCollectMultiJS, ids: items.map(\.id), extra: ["typeMap": Self.typeMap(items)], tag: "uncollect-multi")
    }

    /// 批量取消收藏合集（mix/cancel/collect/multi）
    func cancelMixCollects(_ ids: [String]) async throws -> DYBatchResult {
        try await batch(Self.cancelMixMultiJS, ids: ids, tag: "unmix-multi")
    }

    /// aweme_type 107 = 西瓜视频 → 1，其余 0（网页版 774598 模块）
    static func typeMap(_ items: [DYAweme]) -> String {
        let m = Dictionary(items.map { ($0.id, $0.awemeType == 107 ? 1 : 0) }, uniquingKeysWith: { a, _ in a })
        let d = (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    // MARK: 收藏夹

    func collectsFolders(cursor: String) async throws -> (items: [DYCollectsFolder], cursor: String, hasMore: Bool) {
        try await page(Self.collectsListJS, ["cursor": cursor], DYCollectsFolder.self)
    }

    func collectsVideos(_ folderID: String, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        try await page(Self.collectsVideosJS, ["fid": folderID, "cursor": cursor], DYAweme.self)
    }

    /// 新建（action 1）/ 改名或改私密（0）/ 删除（2）收藏夹（collects/maintain）
    func maintainFolder(id: String?, action: Int, name: String = "", secret: Bool = false) async throws -> (DYActionResult, DYCollectsFolder?) {
        await ensureWriteReady()
        let d = try await call(Self.collectsMaintainJS,
                               args: ["fid": id ?? "", "action": String(action), "name": name, "secret": secret ? "1" : "0"], attempts: 1)
        let r = try JSONDecoder().decode(DYCollectsResp.self, from: d)
        DYLiveModel.log("DDSEND collects-maintain action=\(action) status=\(r.status) code=\(r.statusCode.map(String.init) ?? "nil")")
        return (Self.manageResult(DYManageResp(status: r.status, statusCode: r.statusCode, msg: r.msg)), r.folder)
    }

    /// 把视频放进收藏夹（collects/video/move，item_type 2；会顺带收藏这条）
    func moveToFolder(_ awemeIDs: [String], folder: DYCollectsFolder) async throws -> DYActionResult {
        let r = try await writeCall(Self.collectsMoveJS, ["ids": awemeIDs.joined(separator: ","), "fid": folder.id, "fname": folder.name],
                                    tag: "collects-move")
        return Self.manageResult(r)
    }

    // MARK: 合集 / 音乐

    func collectedMixes(cursor: String) async throws -> (items: [DYMixInfo], cursor: String, hasMore: Bool) {
        try await page(Self.mixListCollectionJS, ["cursor": cursor], DYMixInfo.self)
    }

    func mixVideos(_ mixID: String, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        try await page(Self.mixAwemeJS, ["mix": mixID, "cursor": cursor], DYAweme.self)
    }

    /// 收藏 / 取消收藏合集（mix/collect，action 1/0）
    func collectMix(_ mixID: String, on: Bool) async throws -> DYActionResult {
        Self.manageResult(try await writeCall(Self.mixCollectJS, ["mix": mixID, "action": on ? "1" : "0"], tag: on ? "mix-collect" : "mix-uncollect"))
    }

    func collectedMusic(cursor: String) async throws -> (items: [DYMusicInfo], cursor: String, hasMore: Bool) {
        try await page(Self.musicListCollectionJS, ["cursor": cursor], DYMusicInfo.self)
    }

    /// 收藏 / 取消收藏音乐（music/collect，type=action=1/0；3007005 = 已收藏过，当成功）
    func collectMusic(_ musicID: String, on: Bool) async throws -> DYActionResult {
        let r = try await writeCall(Self.musicCollectJS, ["mid": musicID, "action": on ? "1" : "0"], tag: on ? "music-collect" : "music-uncollect")
        if r.status == 200, r.statusCode == 3_007_005 { return .ok }
        return Self.manageResult(r)
    }

    // MARK: 通知

    /// 删除一条通知（notice/del，action_type 0 普通；1 = 拒绝关注请求）
    func deleteNotice(_ id: String, rejectFollowRequest: Bool = false) async throws -> DYActionResult {
        Self.manageResult(try await writeCall(Self.noticeDelJS, ["nid": id, "action": rejectFollowRequest ? "1" : "0"], tag: "notice-del"))
    }

    /// 赞了这条作品的人（favorite/list，item_id + 游标）
    func diggUsers(awemeID: String, cursor: String) async throws -> (items: [DYPlainUser], cursor: String, hasMore: Bool) {
        try await page(Self.favoriteListJS, ["aid": awemeID, "cursor": cursor], DYPlainUser.self)
    }

    /// 通过关注请求（私密账号；commit/follow/request/approve，from_user_id）
    func approveFollowRequest(uid: String) async throws -> DYActionResult {
        Self.manageResult(try await writeCall(Self.approveFollowJS, ["uid": uid], tag: "follow-approve"))
    }

    // MARK: 翻译 / 弹幕 / 短链

    /// 评论翻译（comment/translate，回 traslate_comment——抖音自己拼错，照抄）
    func translateComment(_ c: DYComment, to lang: String = "zh") async throws -> String {
        let d = try await call(Self.commentTranslateJS, args: ["cid": c.id, "text": c.text, "lang": lang], attempts: 2)
        let r = try JSONDecoder().decode(DYTextResp.self, from: d)
        guard r.status == 200, r.code == 0, let t = r.text, !t.isEmpty else { throw DYError.bad(r.msg ?? "翻译失败") }
        return t
    }

    /// 任意文字翻译（text/translate）
    func translateText(_ s: String, to lang: String = "zh") async throws -> String {
        let d = try await call(Self.textTranslateJS, args: ["text": s, "lang": lang], attempts: 2)
        let r = try JSONDecoder().decode(DYTextResp.self, from: d)
        guard r.status == 200, r.code == 0, let t = r.text, !t.isEmpty else { throw DYError.bad(r.msg ?? "翻译失败") }
        return t
    }

    /// 抖音短链（web_shorten，belong=aweme）：v.douyin.com/xxx/
    func shortLink(for url: URL) async throws -> String {
        let d = try await call(Self.shortenJS, args: ["target": url.absoluteString], attempts: 2)
        let r = try JSONDecoder().decode(DYTextResp.self, from: d)
        guard r.status == 200, let t = r.text, t.hasPrefix("http") else { throw DYError.bad(r.msg ?? "短链生成失败") }
        return t
    }

    // MARK: - JS

    static let deleteMultiJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ aweme_ids: ids, action_type: action }).toString();
    const r = await req('POST', '/aweme/v1/web/aweme/delete/multi/?' + q({}), body);
    const d = parse(r.t) || {};
    const failed = (d.delete_fail_items || []).map(x => String(x.item_id || '')).filter(Boolean);
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null, failed });
    """#

    static let cancelDiggMultiJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ aweme_ids: ids, item_type_map: typeMap }).toString();
    const r = await req('POST', '/aweme/v1/web/cancel/item/digg/multi/?' + q({}), body);
    const d = parse(r.t) || {};
    const failed = (d.fail_items || d.delete_fail_items || []).map(x => String(x.item_id || x.aweme_id || '')).filter(Boolean);
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null, failed });
    """#

    static let cancelCollectMultiJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ aweme_ids: ids, aweme_type_map: typeMap }).toString();
    const r = await req('POST', '/aweme/v1/web/aweme/cancel/collect/multi/?' + q({}), body);
    const d = parse(r.t) || {};
    const failed = (d.fail_items || d.delete_fail_items || []).map(x => String(x.item_id || x.aweme_id || '')).filter(Boolean);
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null, failed });
    """#

    static let cancelMixMultiJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ mix_ids: ids }).toString();
    const r = await req('POST', '/aweme/v1/web/mix/cancel/collect/multi/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null, failed: [] });
    """#

    static let collectsListJS = #"""
    const r = await req('GET', '/aweme/v1/web/collects/list/?' + q({ cursor: cursor, count: '20' }));
    const d = parse(r.t) || {};
    const items = (d.collects_list || []).filter(Boolean).map(c => ({
      id: String(c.collects_id_str || c.collects_id || ''), name: c.collects_name || '',
      cover: first(c.collects_cover), total: Number(c.total_number || 0), secret: typeof c.status === 'number' ? (c.status === 1 ? 1 : 0) : null
    })).filter(c => c.id);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: String(d.cursor ?? 0), hasMore: !!d.has_more });
    """#

    static let collectsVideosJS = #"""
    const r = await req('GET', '/aweme/v1/web/collects/video/list/?' + q({ collects_id: fid, cursor: cursor, count: '18' }));
    const d = parse(r.t) || {};
    const items = (d.aweme_list || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: String(d.cursor ?? 0), hasMore: !!d.has_more });
    """#

    // 网页版：collects_id / action / collects_name / secret 都在 query 里，请求体为空
    static let collectsMaintainJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const p = { action: action };
    if (fid) p.collects_id = fid;
    if (name) p.collects_name = name;
    if (action !== '2') p.secret = secret;
    const r = await req('POST', '/aweme/v1/web/collects/maintain/?' + q(p), '');
    const d = parse(r.t) || {};
    const c = d.collects_info || null;
    const folder = c ? { id: String(c.collects_id_str || c.collects_id || ''), name: c.collects_name || name, cover: first(c.collects_cover), total: Number(c.total_number || 0) } : null;
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null, folder: folder && folder.id ? folder : null });
    """#

    // 网页版：参数全在 query（paramsSerializer arrayFormat:none），item_type 2 = 视频
    static let collectsMoveJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const r = await req('POST', '/aweme/v1/web/collects/video/move/?' + q({
      item_ids: ids, item_type: '2', to_collects_id: fid, collects_name: fname, update_collects_sort: 'true', move_collects_list: fid
    }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#

    static let mixListCollectionJS = #"""
    const r = await req('GET', '/aweme/v1/web/mix/listcollection/?' + q({ cursor: cursor, count: '20' }));
    const d = parse(r.t) || {};
    const items = (d.mix_infos || []).filter(m => m && !(m.status && m.status.status === 4)).map(m => ({
      id: String(m.mix_id || ''), name: m.mix_name || '', cover: first(m.cover_url),
      episodes: Number((m.statis && m.statis.updated_to_episode) || 0), author: (m.author && m.author.nickname) || ''
    })).filter(m => m.id);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: String(d.cursor ?? 0), hasMore: !!d.has_more });
    """#

    static let mixAwemeJS = #"""
    const r = await req('GET', '/aweme/v1/web/mix/aweme/?' + q({ mix_id: mix, cursor: cursor, count: '20' }));
    const d = parse(r.t) || {};
    const items = (d.aweme_list || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: String(d.cursor ?? 0), hasMore: !!d.has_more });
    """#

    static let mixCollectJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const r = await req('GET', '/aweme/v1/web/mix/collect/?' + q({ mix_id: mix, action: action }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#

    static let musicListCollectionJS = #"""
    const r = await req('GET', '/aweme/v1/web/music/listcollection/?' + q({ cursor: String(Math.max(Number(cursor) || 0, 0)), count: '20' }));
    const d = parse(r.t) || {};
    const items = (d.mc_list || []).filter(Boolean).map(m => ({
      id: String(m.id_str || m.id || m.mid || ''), title: m.title || '', author: m.author || m.owner_nickname || '',
      cover: first(m.cover_medium) || first(m.cover_thumb), duration: Number(m.duration || 0),
      playURL: (m.play_url && ((m.play_url.url_list || [])[0] || m.play_url.uri)) || null
    })).filter(m => m.id);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: String(d.cursor ?? 0), hasMore: !!d.has_more });
    """#

    static let musicCollectJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ music_id: mid, type: action, action: action }).toString();
    const r = await req('POST', '/aweme/v1/web/music/collect/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#

    static let noticeDelJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ action_type: action, notice_id_str: nid }).toString();
    const r = await req('POST', '/aweme/v1/web/notice/del/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#

    static let favoriteListJS = #"""
    const r = await req('GET', '/aweme/v1/web/favorite/list/?' + q({ item_id: aid, count: '50', min_cursor: '0', max_cursor: cursor }));
    const d = parse(r.t) || {};
    const items = (d.user_list || []).filter(Boolean).map(x => { const u = x.user_info || x.user || x; return {
      uid: u.uid ? String(u.uid) : '', secUid: u.sec_uid || '', name: u.remark_name || u.nickname || '', avatar: first(u.avatar_thumb) || first(u.avatar_medium) }; })
      .filter(u => u.uid || u.secUid);
    const next = String(d.max_cursor ?? d.cursor ?? 0);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: next,
      hasMore: d.has_more != null ? !!d.has_more : (items.length >= 50 && next !== '0' && next !== cursor) });
    """#

    static let approveFollowJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ from_user_id: uid }).toString();
    const r = await req('POST', '/aweme/v1/web/commit/follow/request/approve/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#

    // 网页版：参数全在 query，请求体为空
    static let commentTranslateJS = #"""
    const r = await req('POST', '/aweme/v1/web/comment/translate/?' + q({ comment_id: cid, target_language: lang, comment_text: text, comment_text_extra: '[]' }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, text: d.traslate_comment || d.translate_comment || null });
    """#

    static let textTranslateJS = #"""
    const r = await req('GET', '/aweme/v1/web/text/translate/?' + q({ source_text: text, target_language: lang }));
    const d = parse(r.t) || {};
    const t = (d.translation || [])[0];
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, text: (t && t.translation) || null });
    """#

    static let shortenJS = #"""
    const r = await req('GET', '/aweme/v1/web/web_shorten/?' + q({ target: target, belong: 'aweme', persist: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.code ?? d.status_code ?? null, msg: d.message || d.status_msg || null, text: typeof d.data === 'string' ? d.data : null });
    """#
}

/// 作品批量操作（aweme/delete/multi 的 action_type）
enum DYWorkAction: Int, CustomStringConvertible {
    case delete = 0, makePublic = 1, makePrivate = 2, friendsOnly = 3
    var description: String {
        switch self {
        case .delete: "delete"
        case .makePublic: "public"
        case .makePrivate: "secret"
        case .friendsOnly: "friend"
        }
    }
    var title: String {
        switch self {
        case .delete: "删除"
        case .makePublic: "设为公开"
        case .makePrivate: "设为私密"
        case .friendsOnly: "仅好友可见"
        }
    }
}
