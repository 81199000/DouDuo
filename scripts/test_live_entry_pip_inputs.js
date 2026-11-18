#!/usr/bin/env node
// Run on macOS with Node and Xcode. All responses are synthetic and XHR stays in memory.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const { execFileSync } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const app = path.join(root, "DouDuo");
const read = file => fs.readFileSync(path.join(app, file), "utf8");
const feed = read("DouyinFeedView.swift");
const follow = read("FollowLiveLogic.swift");
const live = read("DouyinLiveRoom.swift");

function slice(source, start, end) {
    const from = source.indexOf(start);
    const to = source.indexOf(end, from + start.length);
    assert.ok(from >= 0 && to > from, "Missing production definition: " + start);
    return source.slice(from, to);
}

function script(source, name) {
    const prefix = 'static let ' + name + ' = #"""';
    return slice(source, prefix, '\n    """#').slice(prefix.length);
}

const hls = "https://fixture.invalid/hd.m3u8";
const flv = "https://fixture.invalid/hd.flv";
const media = {
    hls_pull_url_map: { HD1: hls },
    flv_pull_url: { HD1: flv },
    // Upstream admits an FLV only when the SDK identifies this URL as non-encrypted AVC video.
    live_core_sdk_data: { pull_data: { stream_data: { data: {
        hd: { main: { flv, sdk_params: { VCodec: "h264", vbitrate: 1000 } } }
    } } } },
    default_resolution: "HD1"
};
const room = { id_str: "fixture-room", status: 2, owner: { web_rid: "fixture-web" }, stream_url: media };

async function map(source, name, response) {
    class FixtureXHR {
        open(method) { assert.equal(method, "GET"); }
        setRequestHeader() {}
        send() {
            this.status = 200;
            this.responseText = JSON.stringify(response);
            this.onload();
        }
    }
    const code = "(async () => {" + script(feed, "requestJS") + "\n" + script(source, name) + "})()";
    const data = JSON.parse(await vm.runInNewContext(code, {
        XMLHttpRequest: FixtureXHR, URLSearchParams, setTimeout() {},
        maxtime: "0", rid: room.owner.web_rid, partition: "101", ptype: "4", offset: "0"
    }));
    assert.equal(data.status, 200);
    assert.equal(data.items.length, 1);
    return data.items[0];
}

async function main() {
    const featured = await map(feed, "liveJS", { data: [{ type: 1, data: room }] });
    const listed = await map(follow, "list", { data: [{ room }] });
    const detail = await map(follow, "room", { data: { data: [room] } });
    const zone = await map(feed, "zoneJS", { data: { data: [{ room }] } });
    const otherHLS = "https://fixture.invalid/detail.m3u8";
    const changed = { ...room, stream_url: { ...media, hls_pull_url_map: { HD1: otherHLS } } };
    const otherDetail = await map(follow, "room", { data: { data: [changed] } });
    const hlsOnly = await map(feed, "liveJS", { data: [{ type: 1, data: {
        ...room, stream_url: { ...media, flv_pull_url: {} }
    } }] });
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "entry-inputs-"));
    try {
        const swift = path.join(tmp, "main.swift");
        const binary = path.join(tmp, "check");
        const definitions = slice(feed, "struct DYLiveRoom:", "private struct DYLiveResp")
            + slice(live, "struct DYLiveStream:", "enum DDLogWriter");
        fs.writeFileSync(swift, 'import Foundation\n' + definitions + '\n' + String.raw`
struct Input: Equatable {
    let foreground: DYLiveStream
    let hls: URL
    let warmsOnItemReady: Bool
}

func input(_ room: DYLiveRoom) -> Input? {
    guard let source = room.liveStreams.first,
          case let .prepare(quality, warms) = DYLivePiPPolicy.handoffDecision(
              vlcPlaysFLV: source.isFLV, vlcQuality: source.quality,
              hlsQualities: Set(room.hls.keys), vlcShowsPicture: true, handoffInProgress: false,
              appActive: true, coverHold: false),
          let hls = room.hlsURL(for: quality) else { return nil }
    return Input(foreground: source, hls: hls, warmsOnItemReady: warms)
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let rooms = try JSONDecoder().decode([DYLiveRoom].self, from: data)
let original = input(rooms[0])!
let metadata = DYLiveRoom(rooms[1].followMetadata)
precondition(metadata.liveStreams.isEmpty)
let resolved = DYLiveRoom(playback: rooms[2], fallback: metadata)
for room in [rooms[1], resolved, rooms[3]] {
    precondition(room.id == rooms[0].id && room.webRid == rooms[0].webRid)
    precondition(room.liveStreams == rooms[0].liveStreams && input(room) == original)
}
let alternate = input(DYLiveRoom(playback: rooms[4], fallback: metadata))!
precondition(original.foreground == alternate.foreground && original.hls != alternate.hls)
let noFLV = input(rooms[5])!
precondition(original.hls == noFLV.hls && !original.warmsOnItemReady && noFLV.warmsOnItemReady)
let request = DYFeaturedPiPInput(generation: UUID(), roomID: rooms[0].id,
                                 webRid: rooms[0].webRid, quality: "HD1", listedHLS: original.hls)
precondition(request.replacement(rooms[0]) == nil && request.replacement(metadata) == nil)
precondition(request.replacement(rooms[4]) == alternate.hls)
func changedRequest(id: String, rid: String, quality: String) -> DYFeaturedPiPInput {
    DYFeaturedPiPInput(generation: UUID(), roomID: id, webRid: rid, quality: quality, listedHLS: original.hls)
}
precondition(changedRequest(id: "other", rid: request.webRid, quality: "HD1").replacement(rooms[4]) == nil)
precondition(changedRequest(id: request.roomID, rid: "other", quality: "HD1").replacement(rooms[4]) == nil)
precondition(changedRequest(id: request.roomID, rid: request.webRid, quality: "SD1").replacement(rooms[4]) == nil)
precondition(changedRequest(id: request.roomID, rid: request.webRid, quality: "HD1") != request)
print("PASS detail requires same room, webRid and quality, new URL, generation-scoped request")
let reentry = changedRequest(id: request.roomID, rid: request.webRid, quality: request.quality)
let confirmed = DYFeaturedPiPDetail(input: request, url: alternate.hls, session: 2, resolvedAt: 10,
                                     originalFailure: .noPicture, reused: false)
let reuse = confirmed.reuse(for: reentry, session: 2, now: 11)
precondition(reuse?.url == alternate.hls && reuse?.input == reentry && reuse?.reused == true)
precondition(reuse?.resolvedAt == 10)
precondition(confirmed.reuse(for: reentry, session: nil, now: 11) == nil)
precondition(confirmed.reuse(for: reentry, session: 3, now: 11) == nil)
precondition(confirmed.reuse(for: reentry, session: 2, now: 25) == nil)
let changedListed = DYFeaturedPiPInput(generation: UUID(), roomID: request.roomID,
    webRid: request.webRid, quality: request.quality, listedHLS: alternate.hls)
for changed in [changedRequest(id: "other", rid: request.webRid, quality: request.quality),
                changedRequest(id: request.roomID, rid: "other", quality: request.quality),
                changedRequest(id: request.roomID, rid: request.webRid, quality: "SD1"), changedListed] {
    precondition(confirmed.reuse(for: changed, session: 2, now: 11) == nil)
}
let timedOut = DYFeaturedPiPDetail(input: request, url: alternate.hls, session: 2, resolvedAt: 10,
                                  originalFailure: .notLoaded, reused: false)
precondition(timedOut.reuse(for: reentry, session: 2, now: 11) == nil)
print("PASS recent verified detail can be reused across generations only for the same source and session")
var selection = DYFollowSelection()
let stale = selection.begin(roomID: rooms[0].id, webRid: rooms[0].webRid, hasStream: false)
selection.startResolving(roomID: rooms[0].id)
selection.cancel()
let latest = selection.begin(roomID: rooms[0].id, webRid: rooms[0].webRid, hasStream: false)
selection.startResolving(roomID: rooms[0].id)
precondition(!selection.complete(roomID: rooms[0].id, token: stale))
precondition(selection.complete(roomID: rooms[0].id, token: latest))
print("PASS old detail completion rejected on same-room reselection")
print("PASS equal inputs across four entry paths; same quality with different HLS; same HLS with different warm-up")
`);
        execFileSync("xcrun", ["swiftc", swift, path.join(app, "DYLivePiPPolicy.swift"),
            path.join(app, "FollowLiveLogic.swift"), "-module-cache-path", path.join(tmp, "modules"), "-o", binary]);
        const result = execFileSync(binary, [], {
            input: JSON.stringify([featured, listed, detail, zone, otherDetail, hlsOnly]), encoding: "utf8"
        });
        process.stdout.write(result);
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
