// 消息 / 作者作品 / 关注 / 评论点赞。全部走签名页 requestJS 的 req()/base/q()。
// 登录看 status_code（8 = 未登录），不读 cookie。写接口只在用户点按钮时发出，日志打 DDSEND。
import Foundation

struct DYNotice: Identifiable, Codable, Equatable {
    let id: String
    let type: Int
    let time: Double
    let name: String
    let avatar: String?
    let action: String
    let detail: String
    let cover: String?
    /// 评论配图缩略图地址（仅评论类通知有），缺字段为空，兼容旧缓存
    var images: [String]? = nil
    let awemeID: String?
    let author: DYAweme.Author?
    var hasRead: Bool
    /// 评论通知：这条评论的 cid；是楼中楼时 parentCid = 一级评论 cid（回复/定位都要用）
    var cid: String? = nil
    var parentCid: String? = nil
    /// 一级评论 cid；旧缓存里一级评论的 parentCid 存成了作品 id（见 noticeJS），这里一律当成没有
    var threadParent: String? {
        guard let p = parentCid, !p.isEmpty, p != awemeID, p != cid else { return nil }
        return p
    }
    /// 被回复的那条（通常是我的评论）原文，列表里灰字引用
    var quote: String? = nil
    /// 赞通知合并的人数（「等 N 人」）；>1 时可点开看全部点赞的人
    var diggCount: Int? = nil
    var isFollowRequest: Bool { type == 98 }

    var isComment: Bool { type == 31 && (cid?.isEmpty == false) && (awemeID?.isEmpty == false) }
    /// @我的（type 45）：评论里 @ 时带 cid，点开定位到那条评论；不给回复入口（拿不到一级评论 id，回错楼会挂空）
    var isMention: Bool { type == 45 }
    var commentFocus: DYCommentFocus? {
        guard isComment || (isMention && cid?.isEmpty == false && awemeID?.isEmpty == false), let cid, let awemeID else { return nil }
        return DYCommentFocus(awemeID: awemeID, cid: cid, parentCid: threadParent)
    }
}

/// 打开视频后要定位的评论：cid 本身；楼中楼时 parentCid 为一级评论
struct DYCommentFocus: Equatable, Hashable {
    let awemeID: String
    let cid: String
    let parentCid: String?
    /// 通知里点「回复」：定位到这条后直接进入「回复 @它」（和在评论区里点它一样，走同一套发送）
    var startReply = false
}

struct DYNoticePage: Decodable {
    let status: Int
    let code: Int?
    let items: [DYNotice]
    let maxTime: Int
    let hasMore: Bool
    let msg: String?
}

struct DYNoticeCount: Decodable {
    let group: Int
    let count: Int
}

/// notice/count 的 interactive_group：网页筛选项 type（"25" 全部含推荐 / "26" 推荐…）→ 接口分组号
struct DYNoticeInteractiveGroup: Decodable {
    let type: String
    let group: Int
}

private struct DYNoticeCountPage: Decodable {
    let status: Int
    let code: Int?
    let groups: [DYNoticeCount]
    var inter: [DYNoticeInteractiveGroup]? = nil
    let msg: String?
}

private struct DYMoreList: Decodable {
    let status: Int
    let code: Int?
    let msg: String?
    let items: [DYAweme]
    let cursor: String
    let hasMore: Bool
}

private struct DYFollowRead: Decodable {
    let status: Int
    let code: Int?
    let follow: Int
    let uid: String?
    let msg: String?
    /// 我是否已拉黑对方（profile/other 的 user.is_block）。缺字段当没拉黑。
    var blocked: Bool? = nil
}

private struct DYFollowWrite: Decodable {
    let status: Int
    let statusCode: Int?
    let followStatus: Int?
    let msg: String?
}

private struct DYDetailPage: Decodable {
    let status: Int
    let code: Int?
    let item: DYAweme?
    let msg: String?
    let shape: DYDetailShape?
}

/// 作品原始形态（诊断用）：网页接口怎么给图文 / 文字帖
private struct DYDetailShape: Decodable {
    let t: Int?; let m: Int?; let dur: Double?; let wh: String?; let play: Int?; let gears: Int?
    let img: Int?; let img0: String?; let music: Bool?; let keys: String?
}

extension DouyinBridge {
    /// 私信头像昵称：同官方私信页的 im/user/info（POST 表单 sec_user_ids=JSON 数组）
    func imUserInfo(secs: [String]) async throws -> [DYIMUser] {
        let d = try await call(Self.imUserInfoJS, args: ["secs": secs.joined(separator: ",")], attempts: 1)
        struct Page: Decodable { let status: Int; let users: [DYIMUser]?; let msg: String? }
        let p = try JSONDecoder().decode(Page.self, from: d)
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return p.users ?? []
    }

    static let imUserInfoJS = #"""
    const ids = String(secs || '').split(',').filter(Boolean);
    const body = 'sec_user_ids=' + encodeURIComponent(JSON.stringify(ids));
    const r = await req('POST', '/aweme/v1/web/im/user/info/?' + q({ version_code: '170400' }), body,
                        { 'content-type': 'application/x-www-form-urlencoded; charset=UTF-8' });
    const d = parse(r.t) || {};
    const list = Array.isArray(d.data) ? d.data : [];
    const users = list.map(u => ({
      uid: String(u.uid || u.user_id || ''), sec: u.sec_uid || '',
      name: u.nickname || u.remark_name || '',
      avatar: ((u.avatar_thumb || u.avatar_small || u.avatar_medium || {}).url_list || [])[0] || '',
      follow: typeof u.follow_status === 'number' ? u.follow_status : null,
      follower: typeof u.follower_status === 'number' ? u.follower_status : null
    })).filter(u => u.uid);
    return JSON.stringify({ status: r.s, users, msg: d.status_msg || (list.length ? null : ('keys=' + Object.keys(d).join('|'))) });
    """#

    func noticeCounts() async throws -> [DYNoticeCount] {
        let d = try await call(Self.noticeCountJS, args: [:], attempts: 1)
        let p = try JSONDecoder().decode(DYNoticeCountPage.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        if let inter = p.inter, !inter.isEmpty {
            DYNoticeGroupMap.update(inter)
            DYLiveModel.log("DDNOTICE groups " + inter.map { "\($0.type)=\($0.group)" }.joined(separator: ","))
        }
        return p.groups
    }

    func notices(group: Int, maxTime: Int, markRead: Bool = false, minTime: Int = 0) async throws -> (items: [DYNotice], maxTime: Int, hasMore: Bool) {
        let d = try await call(Self.noticeListJS, args: ["group": String(group), "maxTime": String(maxTime), "markRead": markRead ? "1" : "0", "minTime": String(minTime)], attempts: 1)
        let p = try JSONDecoder().decode(DYNoticePage.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        DYLiveModel.log("DDNOTICE_FETCH group=\(group) markRead=\(markRead) min=\(minTime) n=\(p.items.count)\(p.msg.map { " msg=\($0)" } ?? "")")
        return (p.items, p.maxTime, p.hasMore)
    }

    /// 点消息进视频。GET，可测。
    func awemeDetail(_ id: String) async throws -> DYAweme {
        let d = try await call(Self.detailJS, args: ["id": id], attempts: 1)
        let p = try JSONDecoder().decode(DYDetailPage.self, from: d)
        if let sh = p.shape {
            DYLiveModel.log("DDDETAILSHAPE id=\(id) type=\(sh.t.map(String.init) ?? "-") media=\(sh.m.map(String.init) ?? "-") dur=\(Int(sh.dur ?? 0))ms wh=\(sh.wh ?? "-") play=\(sh.play ?? 0) gears=\(sh.gears ?? 0) img=\(sh.img ?? 0) img0=\(sh.img0 ?? "-") music=\(sh.music == true) keys=\(sh.keys ?? "")")
        }
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200, let item = p.item, item.play != nil || !item.images.isEmpty else {
            throw DYError.bad(p.msg?.isEmpty == false ? p.msg! : "打不开这条视频")
        }
        return item
    }

    func userPosts(_ sec: String, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        let d = try await call(Self.authorPostJS, args: ["sec": sec, "cursor": cursor], attempts: 1)
        let p = try JSONDecoder().decode(DYMoreList.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 只读关注状态，给按钮初值。不发关注。
    func followState(sec: String) async throws -> (followed: Bool, uid: String?, blocked: Bool) {
        let d = try await call(Self.followReadJS, args: ["sec": sec], attempts: 1)
        let p = try JSONDecoder().decode(DYFollowRead.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return (p.follow > 0, p.uid, p.blocked ?? false)
    }

    /// Resolve a video author and publish the same follow state to every surface.
    func followVideoAuthor(_ author: DYAweme.Author) async throws -> String? {
        var uid = author.uid
        if uid?.isEmpty != false, let sec = author.secUid {
            let state = try await followState(sec: sec)
            if state.followed {
                rememberFollow(author, followed: true)
                return nil
            }
            uid = state.uid
        }
        guard let uid, !uid.isEmpty else { return "暂时无法获取作者信息" }
        switch try await followUser(uid, follow: true) {
        case .ok:
            rememberFollow(author, followed: true)
            return nil
        case .notLoggedIn:
            return "抖音未登录，请先登录"
        case .failed(let message):
            return "关注失败：" + message
        }
    }

    /// 关注 / 取消关注。只在按钮点击时调用，测试不要打这条。
    func followUser(_ uid: String, follow: Bool) async throws -> DYActionResult {
        let d = try await call(Self.followWriteJS, args: ["uid": uid, "type": follow ? "1" : "0"], attempts: 1)
        let r = try JSONDecoder().decode(DYFollowWrite.self, from: d)
        DYLiveModel.log("DDSEND follow uid=\(uid) type=\(follow ? 1 : 0) status=\(r.status) code=\(r.statusCode ?? -1) follow=\(r.followStatus ?? -1) msg=\(r.msg ?? "-")")
        if r.status == 200, (r.statusCode ?? 0) == 0 { return .ok }
        if r.statusCode == 8 || (r.msg ?? "").contains("未登录") { return .notLoggedIn }
        return .failed(r.msg?.isEmpty == false ? r.msg! : "HTTP \(r.status) / code \(r.statusCode ?? -1)")
    }

    /// 评论赞 / 取消赞。只在按钮点击时调用，测试不要打这条。
    func diggComment(_ cid: String, awemeID: String, like: Bool) async throws -> DYActionResult {
        let d = try await call(Self.commentDiggJS, args: ["cid": cid, "id": awemeID, "type": like ? "1" : "0"], attempts: 1)
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        DYLiveModel.log("DDSEND comment-digg cid=\(cid) aweme=\(awemeID) digg_type=\(like ? 1 : 0) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        if r.status == 200, (r.statusCode ?? 0) == 0 { return .ok }
        if r.statusCode == 8 || (r.msg ?? "").contains("未登录") { return .notLoggedIn }
        return .failed(r.msg?.isEmpty == false ? r.msg! : "HTTP \(r.status) / code \(r.statusCode ?? -1)")
    }

    private static let noticeCountJS = #"""
    const r = await req('GET', '/aweme/v1/web/notice/count/?' + q({ is_new_notice: '1', need_social_count: '1' }));
    const d = parse(r.t) || {};
    const raw = d.notice_count || d.notice_count_list || [];
    const groups = raw.map(x => ({ group: Number(x.group ?? x.notice_group ?? 0), count: Number(x.count || 0) }));
    // 网页版用它把「推荐」等筛选项映射到分组号（type 是字符串 "25"/"26"…）
    const inter = (d.interactive_group || []).map(x => ({ type: String(x.type ?? ''), group: Number(x.group || 0) })).filter(x => x.type && x.group);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, groups, inter, msg: d.status_msg || null });
    """#

    private static let noticeListJS = #"""
    const authorOf = u => {
      if (!u || (!u.nickname && !u.sec_uid)) return null;
      // follow = 我→对方 follow_status；follower = 对方→我 follower_status（头像红心 / 「粉丝」标签用）
      return { name: u.nickname || '', avatar: first(u.avatar_thumb) || first(u.avatar_larger), secUid: u.sec_uid || null, uid: u.uid ? String(u.uid) : null,
               follow: typeof u.follow_status === 'number' ? u.follow_status : null, follower: typeof u.follower_status === 'number' ? u.follower_status : null };
    };
    const coverOf = a => {
      if (!a) return null;
      const v = a.video || {};
      return first(v.cover) || first(v.origin_cover) || (a.images && a.images[0] && first(a.images[0])) || null;
    };
    const urlOf = o => first(o) || (o && o.url_list && o.url_list[0]) || null;
    const row = n => {
      const t = Number(n.type || 0);
      const gn = n.general_notice || {};
      const inn = n.interactive_notice || {};
      let name = '', avatar = null, action = gn.title || '通知', detail = gn.content || '', cover = null, awemeID = n.aweme_id ? String(n.aweme_id) : null, author = null, images = null;
      let cid = null, parentCid = null, quote = null, diggCount = 0;
      if (t === 31 && n.comment) {
        const c = n.comment.comment || {};
        const u = c.user || {};
        name = u.nickname || '';
        avatar = first(u.avatar_thumb);
        cid = c.cid ? String(c.cid) : null;
        // 楼中楼：reply_id = 一级评论 cid（网页 comment/list/reply 实测）；一级评论为 '0'
        // 通知里的 comment 没有 reply_id，楼中楼的一级评论在 n.comment.parent_id（一级评论时为 0 或等于自身）
        const pick = v => (v !== undefined && v !== null && String(v) !== '0' && String(v) !== '') ? String(v) : null;
        // ⚠️ 一级评论的通知里 parent_id 是「作品 id」不是评论 id
        // 当成楼中楼去回复 → reply_id=作品 id，抖音回 code=0 但这条挂到不存在的楼下，谁都看不到
        const awemeOf = (c.aweme_id && String(c.aweme_id)) || (n.comment.aweme && n.comment.aweme.aweme_id && String(n.comment.aweme.aweme_id)) || (n.aweme_id ? String(n.aweme_id) : '');
        const notAweme = v => { const x = pick(v); return x && x !== awemeOf ? x : null; };
        const rid = pick(c.reply_id) || pick(n.comment.level1_comment && n.comment.level1_comment.cid) || notAweme(n.comment.parent_id);
        parentCid = rid && rid !== cid ? rid : null;
        quote = (n.comment.reply_comment && n.comment.reply_comment.text) || null;
        action = parentCid ? '回复了你的评论' : '评论了你';
        detail = c.text || gn.content || '';
        cover = coverOf(n.comment.aweme);
        // 评论配图（image_list）：缩略图优先级与评论区一致 medium > thumb > crop > origin
        images = (c.image_list || []).map(x => first(x.medium_url) || first(x.thumb_url) || first(x.crop_url) || first(x.origin_url)).filter(Boolean);
        awemeID = (c.aweme_id && String(c.aweme_id)) || (n.comment.aweme && n.comment.aweme.aweme_id && String(n.comment.aweme.aweme_id)) || awemeID;
        author = authorOf(u);
      } else if (t === 41 && n.digg) {
        const users = n.digg.from_user || [];
        const u = users[0] || {};
        diggCount = Number(n.digg.merge_count || users.length || 0);
        const extra = diggCount > 1 ? ' 等' + diggCount + '人' : '';
        name = (u.nickname || '') + extra;
        avatar = first(u.avatar_thumb);
        action = '赞了你的作品';
        detail = n.digg.content || '';
        cover = coverOf(n.digg.aweme);
        awemeID = (n.digg.aweme && n.digg.aweme.aweme_id && String(n.digg.aweme.aweme_id)) || awemeID;
        author = authorOf(u);
      } else if ((t === 33 || t === 98) && n.follow) {
        // 98 = 关注请求（私密账号）：网页版可「通过 / 拒绝」
        const u = n.follow.from_user || {};
        name = u.nickname || '';
        avatar = first(u.avatar_thumb);
        action = t === 98 ? '请求关注你' : '关注了你';
        detail = n.follow.content || '';
        author = authorOf(u);
      } else if (t === 45 && n.at) {
        // @我的：网页版 at{user_info, sub_type 0/1 发作品时 @ / 2 评论里 @, content, aweme, schema_url 带 cid, comment_status 0=已删}
        const at = n.at;
        const u = at.user_info || {};
        name = u.remark_name || u.nickname || '';
        avatar = first(u.avatar_thumb);
        action = Number(at.sub_type || 0) === 2 ? '在评论中提到了你' : '在发布作品时提到了你';
        detail = (at.comment_status === 0) ? (Number(at.sub_type || 0) === 2 ? '此评论已删除' : '此作品已删除') : (at.content || gn.content || '');
        cover = coverOf(at.aweme);
        awemeID = (n.aweme_id ? String(n.aweme_id) : null) || (at.aweme && at.aweme.aweme_id ? String(at.aweme.aweme_id) : null);
        const m = String(at.schema_url || '').match(/cid=(\d+)/);
        cid = (Number(at.sub_type || 0) === 2 && m) ? m[1] : null;
        author = authorOf(u);
      } else if (t === 9009 || t === 9002 || t === 514 || t === 9067) {
        const u = (inn.from_user && inn.from_user[0]) || {};
        name = u.nickname || inn.author || '';
        avatar = first(u.avatar_thumb) || urlOf(inn.avatar_url);
        action = t === 9009 ? '推荐了你的视频' : (inn.title || gn.title || '推荐了作品');
        detail = inn.content || inn.desc || gn.content || '';
        cover = urlOf(inn.image_url) || coverOf(inn.aweme);
        awemeID = (inn.aweme && inn.aweme.aweme_id && String(inn.aweme.aweme_id)) || awemeID;
        author = authorOf(u);
      } else {
        name = gn.sender_name || '';
        detail = gn.content || '';
        action = gn.title || '通知';
      }
      if (!cover) cover = urlOf(inn.image_url);
      return {
        id: String(n.nid_str || n.nid || (t + '-' + (n.create_time || 0))),
        type: t, time: n.create_time || 0, name, avatar, action, detail, cover, images: (images && images.length) ? images : null, awemeID, author,
        hasRead: !!(n.has_read || n.read_time), cid, parentCid, quote, diggCount: diggCount || null
      };
    };
    const r = await req('GET', '/aweme/v1/web/notice/?' + q({
      is_new_notice: '1', is_mark_read: String(markRead || '0'), count: '10', notice_group: String(group), min_time: String(minTime || 0), max_time: String(maxTime || 0)
    }));
    const d = parse(r.t) || {};
    // 逐条解析：单条脏数据不能炸掉整个列表；解析失败的记进 msg 便于定位
    let items = [];
    let skipped = 0; let skipWhy = '';
    for (const n of (d.notice_list_v2 || d.notice_list || [])) {
      try { items.push(row(n)); } catch (e) { skipped++; skipWhy = String(n.nid_str || '') + ':' + String((e && e.message) || e).slice(0, 120); }
    }
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, items, maxTime: d.max_time || 0, hasMore: !!d.has_more, msg: d.status_msg || (skipped ? ('' + skipped + '条解析失败:' + skipWhy) : null) });
    """#

    private static let detailJS = #"""
    const r = await req('GET', '/aweme/v1/web/aweme/detail/?' + q({ aweme_id: id }));
    const d = parse(r.t) || {};
    const a = d.aweme_detail || d.aweme || null;
    // 诊断：记下作品类型和图文相关字段，看网页接口怎么给「文字」帖
    let shape = null;
    if (a) {
      const v = a.video || {};
      shape = { t: a.aweme_type, m: a.media_type, dur: v.duration || 0, wh: (v.width || 0) + 'x' + (v.height || 0),
        play: ((v.play_addr && v.play_addr.url_list) || []).length, gears: (v.bit_rate || []).length,
        img: (a.images || []).length, img0: a.images && a.images[0] ? Object.keys(a.images[0]).join('|') : null,
        music: !!(a.music && a.music.play_url && (a.music.play_url.url_list || []).length),
        keys: Object.keys(a).filter(k => /text|note|slide|graphic|image|clip|media/i.test(k)).join('|') };
    }
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, item: (a && (a.video || a.images)) ? mapA(a) : null, msg: d.status_msg || null, shape });
    """#

    private static let authorPostJS = #"""
    const r = await req('GET', '/aweme/v1/web/aweme/post/?' + qPost({
      sec_user_id: sec, max_cursor: cursor, locate_query: 'false', show_live_replay_strategy: '1',
      need_time_list: '1', time_list_query: '0', whale_cut_token: '', cut_version: '1', count: '18'
    }));
    const d = parse(r.t) || {};
    const items = (d.aweme_list || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: String(d.max_cursor ?? 0), hasMore: !!d.has_more });
    """#

    private static let followReadJS = #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/other/?' + q({ sec_user_id: sec, publish_video_strategy_type: '2', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    const u = d.user || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, follow: u.follow_status || 0, uid: u.uid ? String(u.uid) : null, blocked: !!u.is_block, msg: d.status_msg || null });
    """#

    private static let followWriteJS = #"""
    const body = new URLSearchParams({ user_id: uid, type: type }).toString();
    const r = await req('POST', '/aweme/v1/web/commit/follow/user/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, followStatus: d.follow_status ?? null, msg: d.status_msg || null });
    """#

    private static let commentDiggJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const P = { cid: cid, aweme_id: id, digg_type: type, channel_id: '0', app_name: 'aweme', item_type: '0' };
    const r = await req('POST', '/aweme/v1/web/comment/digg?' + q(P), new URLSearchParams(P).toString());
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)) });
    """#
}
