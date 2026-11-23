import Foundation
import FirebaseFirestore

struct Friend: Identifiable, Equatable {
    let id: String
    let displayName: String
    let email: String
    let hasFoundingPup: Bool
    let badgeStage: BadgeStage
}

struct IncomingChallenge: Equatable {
    let from: String
    let fromName: String
    let roomCode: String
    let hasFoundingPup: Bool
    let badgeStage: BadgeStage
}

/// A pending friend request addressed to this account, stored at
/// `users/{myUid}/friendRequests/{fromUid}`. `id` is the sender's uid.
struct IncomingFriendRequest: Identifiable, Equatable {
    let id: String
    let fromName: String
    let hasFoundingPup: Bool
    let badgeStage: BadgeStage
}

/// Friends + friend challenges, keyed by the signed-in Firebase Auth uid
/// (the same account used by Competition Mode) rather than the anonymous
/// per-device id casual multiplayer rooms use.
@MainActor
final class FriendsService: ObservableObject {
    @Published var friends: [Friend] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var incomingChallenge: IncomingChallenge?
    @Published var incomingFriendRequests: [IncomingFriendRequest] = []

    private let db = Firestore.firestore()
    private var challengeListener: ListenerRegistration?
    private var friendRequestListener: ListenerRegistration?
    private var friendsFieldListener: ListenerRegistration?
    private var myUid: String?
    private var loadedFriendsUid: String?

    /// Begin listening for challenges and friend requests addressed to this
    /// account. Call again (or `stop()`) whenever the signed-in uid changes.
    func start(uid: String) {
        guard myUid != uid else { return }
        myUid = uid
        challengeListener?.remove()
        challengeListener = db.collection("challenges").document(uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self else { return }
                guard let data = snapshot?.data(),
                      let from = data["from"] as? String,
                      let fromName = data["fromName"] as? String,
                      let roomCode = data["roomCode"] as? String
                else {
                    self.incomingChallenge = nil
                    return
                }
                // Badge is denormalised onto the challenge by the sender, so
                // the banner needs no extra profile read. It's decoration, and
                // the authoritative copy lives on the sender's own user doc.
                self.incomingChallenge = IncomingChallenge(
                    from: from,
                    fromName: fromName,
                    roomCode: roomCode,
                    hasFoundingPup: data[Badges.foundingPupField] as? Bool ?? false,
                    badgeStage: BadgeStage(rawValue: data[Badges.stageField] as? Int ?? 0) ?? .pup
                )
            }

        friendRequestListener?.remove()
        friendRequestListener = db.collection("users").document(uid).collection("friendRequests")
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self else { return }
                self.incomingFriendRequests = snapshot?.documents.map { doc in
                    IncomingFriendRequest(
                        id: doc.documentID,
                        fromName: doc.data()["fromName"] as? String ?? "Player",
                        hasFoundingPup: doc.data()[Badges.foundingPupField] as? Bool ?? false,
                        badgeStage: BadgeStage(rawValue: doc.data()[Badges.stageField] as? Int ?? 0) ?? .pup
                    )
                } ?? []
            }

        // The other side of an accept/remove happens on a different device
        // running its own FriendsService instance, so `friends` can only be
        // kept in sync live — a one-shot load goes stale the moment the
        // other person acts.
        friendsFieldListener?.remove()
        friendsFieldListener = db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self else { return }
                let ids = Set(snapshot?.data()?["friends"] as? [String] ?? [])
                guard ids != Set(self.friends.map(\.id)) else { return }
                Task { await self.loadFriends(uid: uid, forceRefresh: true) }
            }
    }

    func stop() {
        challengeListener?.remove()
        challengeListener = nil
        friendRequestListener?.remove()
        friendRequestListener = nil
        friendsFieldListener?.remove()
        friendsFieldListener = nil
        myUid = nil
        loadedFriendsUid = nil
        friends = []
        incomingChallenge = nil
        incomingFriendRequests = []
    }

    // MARK: - Friends list

    /// Skips the Firestore round-trip if we already loaded this uid's
    /// friends list, so re-opening the profile screen shows the cached
    /// list instantly instead of reloading every time.
    func loadFriends(uid: String, forceRefresh: Bool = false) async {
        guard forceRefresh || loadedFriendsUid != uid else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let doc = try await db.collection("users").document(uid).getDocument()
            let ids = doc.data()?["friends"] as? [String] ?? []
            friends = try await fetchProfiles(ids: ids)
            loadedFriendsUid = uid
        } catch {
            errorMessage = "Couldn't load your friends list."
        }
    }

    /// Fetches friend profiles in concurrent batches.
    ///
    /// This used to await `getDocument()` once per friend in a loop, so the
    /// list cost one sequential round-trip per friend — unnoticeable at 10,
    /// a visible stall at 50. Documents-by-ID queries pull 30 profiles per
    /// request and the batches run concurrently, so the same 50 friends are
    /// two requests in flight at once.
    private func fetchProfiles(ids: [String]) async throws -> [Friend] {
        // A document-ID query throws on an empty or path-like value, which
        // would fail the whole list. The old per-document loop just skipped a
        // bad id, so filter them out up front to keep that forgiveness.
        let ids = ids.filter { !$0.isEmpty && !$0.contains("/") }
        guard !ids.isEmpty else { return [] }

        // Firestore caps `in` filters at 30 values per query.
        let batches = stride(from: 0, to: ids.count, by: 30).map {
            Array(ids[$0..<min($0 + 30, ids.count)])
        }

        let db = self.db
        let loaded = try await withThrowingTaskGroup(of: [Friend].self) { group in
            for batch in batches {
                group.addTask {
                    let snapshot = try await db.collection("users")
                        .whereField(FieldPath.documentID(), in: batch)
                        .getDocuments()
                    return snapshot.documents.map { document in
                        Friend(
                            id: document.documentID,
                            displayName: document.data()["displayName"] as? String ?? "Player",
                            email: document.data()["email"] as? String ?? "",
                            hasFoundingPup: document.data()[Badges.foundingPupField] as? Bool ?? false,
                            badgeStage: BadgeStage(rawValue: document.data()[Badges.stageField] as? Int ?? 0) ?? .pup
                        )
                    }
                }
            }
            var all: [Friend] = []
            for try await batch in group { all.append(contentsOf: batch) }
            return all
        }

        // Batches finish out of order and queries don't promise `ids` order, so
        // rebuild against `ids` — otherwise the list reshuffles on every load.
        // `compactMap` also drops ids with no profile doc, matching the old
        // loop's behaviour of skipping friends whose fetch came back empty.
        let byId = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    /// Looks up a player by username and drops a pending request in their
    /// `friendRequests` subcollection; they must accept it (see
    /// `acceptFriendRequest`) before either side's `friends` array changes.
    ///
    /// `setData` unconditionally overwrites rather than checking for an
    /// existing pending request first: the recipient's `friendRequests`
    /// subcollection is only readable by the recipient (see firestore.rules),
    /// so the sender can never read it back to check for a duplicate.
    func sendFriendRequest(username rawUsername: String, myUid: String, myName: String) async {
        let username = rawUsername.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else { return }
        // Never send from a nameless account: the recipient would see the
        // request (and, once accepted, the friend row) as "Player".
        guard !myName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Set a username before adding friends."
            return
        }
        do {
            let matches = try await db.collection("users")
                .whereField("displayName", isEqualTo: username)
                .limit(to: 1)
                .getDocuments()
            guard let friendUid = matches.documents.first?.documentID else {
                errorMessage = "No player found with that username."
                return
            }
            guard friendUid != myUid else {
                errorMessage = "That's your own username."
                return
            }
            guard !friends.contains(where: { $0.id == friendUid }) else {
                errorMessage = "You're already friends."
                return
            }
            try await Self.sendFriendRequest(toUid: friendUid, myUid: myUid, myName: myName)
        } catch {
            errorMessage = "Couldn't send that friend request. Check the username and try again."
        }
    }

    /// Drops a pending request in `friendUid`'s `friendRequests`. Static and
    /// throwing so callers that already know the recipient's uid (the
    /// post-redemption prompt in `ReferralThanksOverlay`) can use it without a
    /// `FriendsService` instance or its error banner.
    static func sendFriendRequest(toUid friendUid: String, myUid: String, myName: String) async throws {
        try await Firestore.firestore().collection("users").document(friendUid)
            .collection("friendRequests").document(myUid).setData([
                "fromName": myName,
                Badges.foundingPupField: Badges.hasFoundingPup,
                Badges.stageField: Badges.stage.rawValue,
                "createdAt": FieldValue.serverTimestamp(),
            ])
    }

    /// Batches both friends-array updates with deleting the request doc so
    /// the accept either fully applies or fully fails — no state where one
    /// side gained a friend but the request banner already vanished.
    func acceptFriendRequest(_ request: IncomingFriendRequest, myUid: String) async {
        let batch = db.batch()
        batch.updateData(["friends": FieldValue.arrayUnion([request.id])], forDocument: db.collection("users").document(myUid))
        batch.updateData(["friends": FieldValue.arrayUnion([myUid])], forDocument: db.collection("users").document(request.id))
        batch.deleteDocument(db.collection("users").document(myUid).collection("friendRequests").document(request.id))
        do {
            try await batch.commit()
            incomingFriendRequests.removeAll { $0.id == request.id }
            await loadFriends(uid: myUid, forceRefresh: true)
        } catch {
            errorMessage = "Couldn't accept that friend request. Try again."
        }
    }

    func declineFriendRequest(_ request: IncomingFriendRequest, myUid: String) {
        incomingFriendRequests.removeAll { $0.id == request.id }
        db.collection("users").document(myUid)
            .collection("friendRequests").document(request.id).delete()
    }

    func removeFriend(_ friendUid: String, myUid: String) async {
        friends.removeAll { $0.id == friendUid }
        do {
            try await db.collection("users").document(myUid).updateData([
                "friends": FieldValue.arrayRemove([friendUid]),
            ])
            try await db.collection("users").document(friendUid).updateData([
                "friends": FieldValue.arrayRemove([myUid]),
            ])
        } catch {
            errorMessage = "Couldn't remove that friend."
        }
    }

    // MARK: - Challenges

    /// Points a friend's `challenges/{friendUid}` doc at a room the caller already created
    /// via `MultiplayerService.createRoom()`; the recipient's own MultiplayerService joins it.
    func sendChallenge(to friendUid: String, roomCode: String, myUid: String, myName: String) async {
        do {
            try await db.collection("challenges").document(friendUid).setData([
                "from": myUid,
                "fromName": myName,
                "roomCode": roomCode,
                Badges.foundingPupField: Badges.hasFoundingPup,
                Badges.stageField: Badges.stage.rawValue,
                "createdAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            errorMessage = "Couldn't send that challenge."
        }
    }

    func clearIncomingChallenge() {
        incomingChallenge = nil
        guard let myUid else { return }
        db.collection("challenges").document(myUid).delete()
    }
}
