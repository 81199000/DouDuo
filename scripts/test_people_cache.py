#!/usr/bin/env python3
"""Compile and exercise the actual cache with Foundation + real Combine on macOS.

Model declarations are extracted from production; the contact's Decodable ->
Codable adapter anticipates the separately owned integration change. No network,
UI, project build, login credentials, or user cache directories are touched.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def declaration(path, marker):
    text = path.read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


HARNESS = r'''
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
@main struct Regression {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let a = String(repeating: "a", count: 64)
        let b = String(repeating: "b", count: 64)
        let cache = DYPeopleCache(directory: root)
        let c1 = DYForwardContact(id: "1", name: "One", avatar: nil, kind: 1)
        let c2 = DYForwardContact(id: "2", name: "Two", avatar: "a", kind: 2)
        let c3 = DYForwardContact(id: "3", name: "Three", avatar: nil, kind: 1)
        let renamed = DYForwardContact(id: "1", name: "Renamed", avatar: "new", kind: 2)
        let f1 = DYFriend(name: "Friend", avatar: nil, secUid: "sec1")
        let f2 = DYFriend(name: "Other", avatar: nil, secUid: "sec2")
        let fnew = DYFriend(name: "New", avatar: "new", secUid: "sec1")
        cache.activate(scope: a)
        expect(!cache.hasContactsSnapshot && !cache.hasFriendsSnapshot, "absent snapshot")
        expect(cache.mergeContacts([c1, c2, renamed], scope: a), "insert contacts")
        expect(cache.contacts == [renamed, c2], "dedup: first position, last metadata")
        expect(cache.mergeContacts([c1], scope: a), "existing contact metadata update")
        expect(cache.contacts == [c1, c2], "updated name avatar kind and stable order")
        expect(cache.mergeContacts([renamed], scope: a), "existing contact metadata restore")
        expect(cache.mergeFriends([f1, f2, fnew], scope: a), "insert friends")
        expect(cache.friends == [fnew, f2], "friend ID dedup")
        expect(cache.mergeFriends([f1], scope: a), "existing friend metadata update")
        expect(cache.friends == [f1, f2], "friend updated name avatar and stable order")
        expect(cache.mergeFriends([fnew], scope: a), "existing friend metadata restore")
        expect(cache.contactsUpdatedAt != nil && cache.friendsUpdatedAt != nil, "check times")
        let file = root.appendingPathComponent(a + ".json")
        let data = try Data(contentsOf: file)
        let fixedDate = Date(timeIntervalSince1970: 123456)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        var publications = 0
        let token = cache.objectWillChange.sink { publications += 1 }
        expect(!cache.mergeContacts([c2, renamed], scope: a), "stable existing order")
        expect(!cache.mergeFriends([f2, fnew], scope: a), "unchanged friends")
        expect(publications == 0, "no unchanged array publication")
        expect(tryData(file) == data, "no unchanged encoding write")
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        expect(modified == fixedDate, "no unchanged file rewrite")
        _ = token
        let restart = DYPeopleCache(directory: root)
        restart.activate(scope: a)
        expect(restart.contacts == [renamed, c2] && restart.friends == [fnew, f2], "disk restart")
        expect(restart.hasContactsSnapshot && restart.hasFriendsSnapshot, "restored flags")
        expect(restart.contactsUpdatedAt != nil && restart.friendsUpdatedAt != nil, "restored dates")
        expect(cache.mergeContacts([c3], scope: a), "partial insert")
        expect(cache.contacts == [renamed, c2, c3], "partial never deletes")
        expect(!cache.mergeFriends([], scope: a), "empty partial friends retains")
        expect(cache.friends == [fnew, f2], "partial friend preservation")
        cache.activate(scope: b)
        expect(cache.contacts.isEmpty && cache.friends.isEmpty, "switch clears synchronously")
        expect(!cache.hasContactsSnapshot && !cache.hasFriendsSnapshot, "scope flags clear")
        expect(!cache.mergeContacts([c1], scope: a), "stale contact rejection")
        expect(!cache.mergeFriends([f1], scope: a), "stale friend rejection")
        expect(cache.contactsUpdatedAt == nil && cache.friendsUpdatedAt == nil, "stale dates unchanged")
        expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(b + ".json").path), "stale no write")
        expect(cache.mergeContacts([c2], scope: b), "account B save")
        cache.activate(scope: a)
        expect(cache.contacts == [renamed, c2, c3], "account A isolated")
        expect(cache.mergeContacts([c3, renamed], scope: a, complete: true), "full deletes absent")
        expect(cache.contacts == [renamed, c3], "full preserves survivor order")
        expect(cache.mergeContacts([], scope: a, complete: true), "full empty deletes contacts")
        expect(cache.mergeFriends([], scope: a, complete: true), "full empty deletes friends")
        let emptyRestart = DYPeopleCache(directory: root)
        emptyRestart.activate(scope: a)
        expect(emptyRestart.contacts.isEmpty && emptyRestart.friends.isEmpty, "empty restored")
        expect(emptyRestart.hasContactsSnapshot && emptyRestart.hasFriendsSnapshot, "empty is snapshot")
        cache.activate(scope: b)
        expect(cache.contacts == [c2] && !cache.hasFriendsSnapshot, "independent snapshot flags")
        cache.activate(scope: "")
        expect(cache.scope.isEmpty && cache.contacts.isEmpty && !cache.hasContactsSnapshot, "logout clears")
        let filesBeforeInvalid = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for invalid in ["../escape", "", String(repeating: "g", count: 64), a + "/x", "abc"] {
            cache.activate(scope: invalid)
            expect(!cache.mergeContacts([c1], scope: invalid), "invalid scope contact reject")
            expect(!cache.mergeFriends([f1], scope: invalid), "invalid scope friend reject")
            expect(cache.contacts.isEmpty && cache.friends.isEmpty, "invalid stays empty")
        }
        let filesAfterInvalid = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        expect(filesBeforeInvalid == filesAfterInvalid, "invalid scopes create no files")
        expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.json").path), "no path traversal")
        let corrupt = root.appendingPathComponent(a + ".json")
        try Data("broken".utf8).write(to: corrupt)
        cache.activate(scope: a)
        expect(cache.contacts.isEmpty && !cache.hasContactsSnapshot, "corrupt file ignored")
        expect(cache.mergeContacts([], scope: a, complete: true) == false, "empty snapshot is not content change")
        expect(cache.hasContactsSnapshot, "first empty marked checked")
        let firstEmpty = DYPeopleCache(directory: root)
        firstEmpty.activate(scope: a)
        expect(firstEmpty.hasContactsSnapshot && !firstEmpty.hasFriendsSnapshot, "first empty persists")
        // Older archives can omit optional snapshot flags/dates and unrelated lists.
        let legacy: [String: Any] = ["contacts": [["id": "raw ID ", "name": "Old", "kind": 1]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: corrupt)
        let old = DYPeopleCache(directory: root)
        old.activate(scope: a)
        expect(old.contacts.first?.id == "raw ID ", "legacy data and literal IDs retained")
        expect(old.hasContactsSnapshot && !old.hasFriendsSnapshot, "legacy absent fields default")
        // A write failure must not discard the in-memory merge.
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let memory = DYPeopleCache(directory: blocked)
        memory.activate(scope: a)
        expect(memory.mergeContacts([c1], scope: a), "write failure still merges")
        expect(memory.contacts == [c1], "write failure retains memory")
        print("PASS people cache: disk, isolation, dedup, metadata, stable order, no-op publication/write, partial/full, empty, corruption, invalid scopes, legacy, write failure")
    }
    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
'''


class PeopleCacheTests(unittest.TestCase):
    def test_real_swift_cache(self):
        source = ROOT / 'DouDuo/DouyinPeopleCache.swift'
        self.assertTrue(source.exists(), 'DYPeopleCache production module is missing')
        contact = declaration(ROOT / 'DouDuo/DouyinForwardPanel.swift', 'struct DYForwardContact:')
        contact = contact.replace('Decodable', 'Codable')
        friend = declaration(ROOT / 'DouDuo/DouyinExtras.swift', 'struct DYFriend:')
        scratch = Path(os.environ.get('TMPDIR', str(Path.home() / '.cache'))) / 'douduo-people-tests'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            directory = Path(temporary)
            program = directory / 'Regression.swift'
            program.write_text(source.read_text() + '\n' + contact + '\n' + friend + '\n' + HARNESS)
            binary = directory / 'regression'
            result = subprocess.run(['swiftc', '-parse-as-library', str(program), '-o', str(binary)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary), str(directory / 'cache')], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
