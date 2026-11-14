#!/usr/bin/env python3
"""Record the active Duo display and handle UI-test rotation/keyboard markers.

Run beside xcodebuild with the same log file. Device Hub must show iPhone Duo;
System Events needs Accessibility permission. No account or media actions occur.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import signal
import struct
import subprocess
import time
import unicodedata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--display", choices=["outer", "inner"], required=True)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    display = "3" if args.display == "inner" else "1"

    def capture(path):
        subprocess.run(["xcrun", "simctl", "io", args.udid, "screenshot",
                        "--display=" + display, str(path)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def hub(command):
        subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "DeviceHub"',
                        "-e", command, "-e", "end tell"], check=True, stdout=subprocess.DEVNULL)

    def audit(payload):
        container = Path(subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", args.udid, "me.rrmm.douduo", "data"], text=True).strip())
        session = json.loads((container / "Library/Application Support/feed-session.json").read_text())
        with (container / "Library/Preferences/me.rrmm.douduo.plist").open("rb") as source:
            preferences = plistlib.load(source)
        blocked = json.loads(preferences.get("douyin_blocked_hashtags_v1") or "[]")
        normalize = lambda value: unicodedata.normalize("NFKC", value).casefold()
        tag = payload["tag"]
        key = normalize(tag)
        # Independently inspect raw server tag metadata and a literal caption
        # boundary, without calling the application's filtering implementation.
        caption = re.compile(r"[#＃]" + re.escape(tag) + r"(?=$|[\s#＃，。,.!！?？:：;；])", re.IGNORECASE)
        matches = [item["id"] for item in session["items"]
                   if key in {normalize(value) for value in item.get("hashtagNames", [])}
                   or caption.search(item.get("desc", ""))]
        phase = payload["phase"]
        if phase == "before-filter":
            assert payload["originalID"] in matches, "Original real recommendation must carry the selected tag"
        elif phase == "after-cleanup":
            assert key not in {normalize(value) for value in blocked}, "Temporary block must be removed"
        else:
            assert key in {normalize(value) for value in blocked}, "Real block must be persisted"
            assert not matches, f"Blocked real recommendations remain: {matches}"
            assert payload["originalID"] not in {item["id"] for item in session["items"]}
        report = dict(payload, currentID=session["currentID"], recommendationCount=len(session["items"]),
                      matchingIDs=matches, blockedTags=blocked,
                      recommendations=[{"id": item["id"], "tags": item.get("hashtagNames", [])}
                                       for item in session["items"]])
        (args.output / (phase + ".json")).write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"PASS real data {phase}: {len(session['items'])} recommendations, {len(matches)} matching tags", flush=True)

    deadline = time.monotonic() + args.timeout
    recording = None
    with args.log.open() as stream:
        while time.monotonic() < deadline:
            line = stream.readline()
            if not line:
                time.sleep(0.1)
                continue
            if "DUODUO_RECORD_START " in line:
                name = line.split("DUODUO_RECORD_START ", 1)[1].strip()
                recording = subprocess.Popen(["xcrun", "simctl", "io", args.udid, "recordVideo",
                                              "--display=" + display, str(args.output / (Path(name).name + ".mp4"))],
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif "DUODUO_RECORD_STOP " in line:
                if recording is not None:
                    recording.send_signal(signal.SIGINT)
                    recording.wait(timeout=15)
                    recording = None
            elif "DUODUO_CAPTURE " in line:
                name = line.split("DUODUO_CAPTURE ", 1)[1].strip()
                path = args.output / (Path(name).name + ".png")
                capture(path)
                print(path, flush=True)
            elif "DUODUO_POSTURE " in line:
                state = line.split("DUODUO_POSTURE ", 1)[1].strip()
                button = {"half": "Partially Open", "open": "Open"}[state]
                hub('click (first button of group 1 of (first window whose name starts with "iPhone Duo") whose help is "' + button + '")')
                print("Duo posture: " + state, flush=True)
            elif "DUODUO_ROTATE " in line:
                portrait = line.split("DUODUO_ROTATE ", 1)[1].strip() == "portrait"
                # Upside-down portrait is not an app-supported orientation, so
                # inspect actual display bounds instead of assuming one click.
                for _ in range(4):
                    path = args.output / "rotation-probe.png"
                    capture(path)
                    width, height = struct.unpack(">II", path.read_bytes()[16:24])
                    if (width < height) == portrait:
                        break
                    hub('click (first button of group 1 of (first window whose name starts with "iPhone Duo") whose help is "Rotate Right")')
                    time.sleep(0.7)
                print("Duo rotated to " + ("portrait" if portrait else "landscape"), flush=True)
            elif "DUODUO_SHOW_KEYBOARD" in line:
                hub('click menu item "Toggle Software Keyboard" of menu 1 of menu item "Keyboard" of menu 1 of menu bar item "Device" of menu bar 1')
            elif "DUODUO_AUDIT " in line:
                audit(json.loads(line.split("DUODUO_AUDIT ", 1)[1]))
            elif "** TEST " in line:
                if recording is not None:
                    recording.send_signal(signal.SIGINT)
                    recording.wait(timeout=15)
                return
    if recording is not None:
        recording.send_signal(signal.SIGINT)
        recording.wait(timeout=15)
    raise TimeoutError("Duo regression did not finish before the capture timeout")


if __name__ == "__main__":
    main()
