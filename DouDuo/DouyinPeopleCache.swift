import Foundation
import Combine

/// Account-scoped, local-first people snapshots. Networking is owned by callers.
/// Pass the session-cookie SHA256, never cookies or tokens, as the scope.
@MainActor
final class DYPeopleCache: ObservableObject {
    static let shared = DYPeopleCache()

    @Published private(set) var contacts: [DYForwardContact] = []
    @Published private(set) var friends: [DYFriend] = []
    private(set) var scope: String = ""
    private(set) var hasContactsSnapshot = false
    private(set) var hasFriendsSnapshot = false
    private(set) var contactsUpdatedAt: Date?
    private(set) var friendsUpdatedAt: Date?

    private let directory: URL

    /// The injected directory is the cache directory itself, not its parent.
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        .appendingPathComponent("people-cache-v1", isDirectory: true)) {
        self.directory = directory
    }

    func activate(scope requestedScope: String) {
        let nextScope = Self.isValidScope(requestedScope) ? requestedScope : ""
        guard nextScope != scope else { return }
        scope = nextScope
        if !contacts.isEmpty { contacts = [] }
        if !friends.isEmpty { friends = [] }
        hasContactsSnapshot = false
        hasFriendsSnapshot = false
        contactsUpdatedAt = nil
        friendsUpdatedAt = nil
        guard !scope.isEmpty,
              let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        let restoredContacts = Self.merged([], with: saved.contacts, complete: true)
        let restoredFriends = Self.merged([], with: saved.friends, complete: true)
        if !restoredContacts.isEmpty { contacts = restoredContacts }
        if !restoredFriends.isEmpty { friends = restoredFriends }
        hasContactsSnapshot = saved.hasContactsSnapshot
        hasFriendsSnapshot = saved.hasFriendsSnapshot
        contactsUpdatedAt = saved.contactsUpdatedAt
        friendsUpdatedAt = saved.friendsUpdatedAt
    }

    /// A partial response upserts only; only an explicitly complete snapshot deletes.
    /// Returns content/order changes, not changes to check time or snapshot presence.
    @discardableResult
    func mergeContacts(_ rows: [DYForwardContact], scope responseScope: String,
                       complete: Bool = false) -> Bool {
        guard accepts(responseScope) else { return false }
        let next = Self.merged(contacts, with: rows, complete: complete)
        let changed = next != contacts
        let firstSnapshot = !hasContactsSnapshot
        if changed { contacts = next }
        hasContactsSnapshot = true
        contactsUpdatedAt = Date()
        if changed || firstSnapshot { persist() }
        return changed
    }

    @discardableResult
    func mergeFriends(_ rows: [DYFriend], scope responseScope: String,
                      complete: Bool = false) -> Bool {
        guard accepts(responseScope) else { return false }
        let next = Self.merged(friends, with: rows, complete: complete)
        let changed = next != friends
        let firstSnapshot = !hasFriendsSnapshot
        if changed { friends = next }
        hasFriendsSnapshot = true
        friendsUpdatedAt = Date()
        if changed || firstSnapshot { persist() }
        return changed
    }

    private func accepts(_ responseScope: String) -> Bool {
        !scope.isEmpty && responseScope == scope
    }

    private static func isValidScope(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    /// First occurrence determines position; last occurrence supplies metadata.
    /// Existing survivors retain their order even when a server page is reordered.
    private static func merged<Row: Identifiable>(_ existing: [Row], with rows: [Row],
                                                  complete: Bool) -> [Row] {
        var latest: [Row.ID: Row] = [:]
        var incomingIDs: [Row.ID] = []
        for row in rows {
            if latest[row.id] == nil { incomingIDs.append(row.id) }
            latest[row.id] = row
        }
        var result: [Row] = []
        var seen: Set<Row.ID> = []
        for row in existing where seen.insert(row.id).inserted {
            if let replacement = latest[row.id] { result.append(replacement) }
            else if !complete { result.append(row) }
        }
        for id in incomingIDs where seen.insert(id).inserted {
            if let row = latest[id] { result.append(row) }
        }
        return result
    }

    private var fileURL: URL { directory.appendingPathComponent(scope + ".json") }

    private func persist() {
        guard Self.isValidScope(scope) else { return }
        do {
            let saved = Archive(contacts: contacts, friends: friends,
                                hasContactsSnapshot: hasContactsSnapshot,
                                hasFriendsSnapshot: hasFriendsSnapshot,
                                contactsUpdatedAt: contactsUpdatedAt,
                                friendsUpdatedAt: friendsUpdatedAt)
            let data = try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Disk failures must never discard a successfully merged in-memory snapshot.
        }
    }

    private struct Archive: Codable {
        var contacts: [DYForwardContact]
        var friends: [DYFriend]
        var hasContactsSnapshot: Bool
        var hasFriendsSnapshot: Bool
        var contactsUpdatedAt: Date?
        var friendsUpdatedAt: Date?

        init(contacts: [DYForwardContact], friends: [DYFriend],
             hasContactsSnapshot: Bool, hasFriendsSnapshot: Bool,
             contactsUpdatedAt: Date?, friendsUpdatedAt: Date?) {
            self.contacts = contacts
            self.friends = friends
            self.hasContactsSnapshot = hasContactsSnapshot
            self.hasFriendsSnapshot = hasFriendsSnapshot
            self.contactsUpdatedAt = contactsUpdatedAt
            self.friendsUpdatedAt = friendsUpdatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case contacts, friends, hasContactsSnapshot, hasFriendsSnapshot
            case contactsUpdatedAt, friendsUpdatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            contacts = try values.decodeIfPresent([DYForwardContact].self, forKey: .contacts) ?? []
            friends = try values.decodeIfPresent([DYFriend].self, forKey: .friends) ?? []
            hasContactsSnapshot = try values.decodeIfPresent(Bool.self, forKey: .hasContactsSnapshot)
                ?? values.contains(.contacts)
            hasFriendsSnapshot = try values.decodeIfPresent(Bool.self, forKey: .hasFriendsSnapshot)
                ?? values.contains(.friends)
            contactsUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .contactsUpdatedAt)
            friendsUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .friendsUpdatedAt)
        }
    }
}
