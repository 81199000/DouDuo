import Foundation

// 管理类写操作：稍后再看加入 / 移除、清空观看历史、拉黑 / 解除拉黑、移除粉丝。
// 路径、参数、请求体写法都照网页版自己的调用。
// 全部只在用户点了按钮之后才发，不自动重试；测试不要真打这些接口。

struct DYManageResp: Decodable {
    let status: Int
    let statusCode: Int?
    let msg: String?
    /// 拉黑接口回的当前状态：1 = 已拉黑，0 = 未拉黑
    var blockStatus: Int? = nil
    /// 稍后再看移除接口回的实际移除条数
    var removed: Int? = nil
}

extension DouyinBridge {
    /// 写操作的结果判定比读接口严：抖音拦下请求时常回 HTTP 200 + 空内容，
    /// 那种情况没有 status_code，不能当成功。
    static func manageResult(_ r: DYManageResp) -> DYActionResult {
        if r.statusCode == 8 || (r.msg ?? "").contains("未登录") { return .notLoggedIn }
        guard r.status == 200 else { return .failed(r.msg?.isEmpty == false ? r.msg! : "HTTP \(r.status)") }
        guard let code = r.statusCode else { return .failed("抖音没有回执，可能被拦下了") }
        if code == 0 { return .ok }
        return .failed(r.msg?.isEmpty == false ? r.msg! : "抖音返回 \(code)")
    }

    private func manage(_ js: String, _ args: [String: Any], tag: String) async throws -> DYManageResp {
        await ensureWriteReady()
        let d = try await call(js, args: args, attempts: 1)
        let r = try JSONDecoder().decode(DYManageResp.self, from: d)
        DYLiveModel.log("DDSEND \(tag) status=\(r.status) code=\(r.statusCode.map(String.init) ?? "nil") msg=\(r.msg ?? "-")")
        return r
    }

    /// 加入稍后再看（POST watchlater/upsert，action_type 1）。
    func addWatchLater(_ awemeID: String) async throws -> DYActionResult {
        let r = try await manage(Self.watchLaterAddJS, ["id": awemeID], tag: "watchlater-add")
        if r.status == 200, r.statusCode == 4 { return .failed("稍后再看已达上限") }
        return Self.manageResult(r)
    }

    /// 移出稍后再看（POST watchlater/remove，remove_type 0 = 只移除选中的）。
    func removeWatchLater(_ awemeID: String) async throws -> DYActionResult {
        let r = try await manage(Self.watchLaterRemoveJS, ["id": awemeID], tag: "watchlater-remove")
        return Self.manageResult(r)
    }

    /// 清空观看历史（POST history/clear）。清掉就找不回来，调用前要让用户确认。
    func clearHistory() async throws -> DYActionResult {
        let r = try await manage(Self.historyClearJS, [:], tag: "history-clear")
        return Self.manageResult(r)
    }

    /// 拉黑 / 解除拉黑（POST user/block，block_type 1 拉黑、0 解除）。
    /// 除了 status_code 0，还要求回执里的 block_status 就是想要的状态才算成。
    func blockUser(uid: String, secUid: String, block: Bool) async throws -> DYActionResult {
        let r = try await manage(Self.blockJS, ["uid": uid, "sec": secUid, "type": block ? "1" : "0"],
                                 tag: block ? "block" : "unblock")
        let result = Self.manageResult(r)
        guard case .ok = result else { return result }
        guard r.blockStatus == (block ? 1 : 0) else { return .failed("抖音没有确认，请到对方主页核对") }
        return .ok
    }

    /// 移除粉丝（POST remove/follower）。对方不再关注我。
    func removeFollower(secUid: String) async throws -> DYActionResult {
        let r = try await manage(Self.removeFollowerJS, ["sec": secUid], tag: "remove-follower")
        return Self.manageResult(r)
    }

    // 请求体是 JSON 字符串，但 Content-Type 仍是表单类型——网页版就是这么发的。
    static let watchLaterAddJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = JSON.stringify({ item_to_playinfo: { [id]: { play_duration: 0, loop_status: 0 } }, action_type: 1 });
    const r = await req('POST', '/aweme/v1/web/watchlater/upsert/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#

    static let watchLaterRemoveJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = JSON.stringify({ remove_item_ids: [id], remove_type: 0 });
    const r = await req('POST', '/aweme/v1/web/watchlater/remove/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null, removed: d.removed_num ?? null });
    """#

    static let historyClearJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const r = await req('POST', '/aweme/v1/web/history/clear/?' + q({}), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#

    static let blockJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const body = new URLSearchParams({ user_id: uid, sec_user_id: sec, block_type: type, source: '0' }).toString();
    const r = await req('POST', '/aweme/v1/web/user/block/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null, blockStatus: d.block_status ?? null });
    """#

    static let removeFollowerJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const r = await req('POST', '/aweme/v1/web/remove/follower/?' + q({ sec_user_id: sec }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || null });
    """#
}
