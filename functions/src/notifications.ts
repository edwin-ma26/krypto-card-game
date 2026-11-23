import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated, onDocumentUpdated, onDocumentWritten } from "firebase-functions/v2/firestore";

const db = getFirestore();

/** Looks up `uid`'s FCM token and sends it a push, swallowing failures (missing/stale token, user opted out) so a delivery problem never retries or crashes the trigger. */
async function pushTo(uid: string, title: string, body: string): Promise<void> {
  const token = (await db.collection("users").doc(uid).get()).data()?.fcmToken;
  if (typeof token !== "string" || !token) return;
  try {
    await getMessaging().send({ token, notification: { title, body } });
  } catch (err) {
    console.warn(`Push to ${uid} failed`, err);
  }
}

/** Notifies a player when someone sends them a friend request. */
export const onFriendRequestCreated = onDocumentCreated(
  "users/{uid}/friendRequests/{fromUid}",
  async (event) => {
    const uid = event.params.uid;
    const fromName = event.data?.data()?.fromName;
    if (typeof fromName !== "string") return;
    await pushTo(uid, "Krypto", `${fromName} sent you a friend request`);
  }
);

/**
 * Notifies a player when someone's `friends` array gains them — covers both
 * sides of an accept, since `acceptFriendRequest` updates both users' docs:
 * the sender gets "X accepted your friend request" and the accepter gets a
 * matching confirmation for the friend they just added.
 */
export const onFriendAdded = onDocumentUpdated("users/{uid}", async (event) => {
  const uid = event.params.uid;
  const beforeIds: string[] = event.data?.before.data()?.friends ?? [];
  const afterIds: string[] = event.data?.after.data()?.friends ?? [];
  const addedIds = afterIds.filter((id) => !beforeIds.includes(id));
  if (addedIds.length === 0) return;

  const displayName = event.data?.after.data()?.displayName ?? "Someone";
  await Promise.all(addedIds.map((friendId) => pushTo(friendId, "Krypto", `${displayName} is now your friend!`)));
});

/**
 * Notifies a player when a friend challenges them to a match. The challenge doc
 * at `challenges/{uid}` is written with `setData` (so a re-challenge overwrites
 * rather than creates), which is why this listens for any write: it pushes on a
 * genuinely new challenge — a fresh doc, or an existing one pointed at a new
 * room — and ignores the delete that fires when the recipient dismisses it.
 */
export const onChallengeCreated = onDocumentWritten("challenges/{uid}", async (event) => {
  const after = event.data?.after.data();
  if (!after) return; // Dismissed/cleared — nothing to notify.
  const before = event.data?.before.data();
  if (before && before.roomCode === after.roomCode) return; // Unchanged room, not a new challenge.

  const uid = event.params.uid;
  const fromName = after.fromName;
  if (typeof fromName !== "string" || !fromName) return;
  await pushTo(uid, "Krypto", `${fromName} challenged you to a match!`);
});

/**
 * Notifies a ranked player when their last opponent asks for a rematch, so a
 * request that lands while the app is in the background still reaches them.
 * The client's `rematchRequestedBy` write is the signal; it fires once per
 * fresh request (a repeat write by the same requester is ignored) and never
 * for bot matches, where the "request" is answered server-side anyway.
 * Casual rooms are keyed by device ids rather than uids, so they have no
 * token to push to and are left to the in-app prompt.
 */
export const onRankedRematchRequested = onDocumentUpdated("rankedMatches/{matchId}", async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  if (!after || after.isBot === true) return;
  const requester = after.rematchRequestedBy;
  if (typeof requester !== "string" || !requester) return;
  if (before?.rematchRequestedBy === requester) return; // Not a new request.

  const { playerA, playerB, nameA, nameB } = after;
  const target = requester === playerA ? playerB : requester === playerB ? playerA : undefined;
  if (typeof target !== "string" || !target) return;
  const requesterName = (requester === playerA ? nameA : nameB) ?? "Your opponent";
  await pushTo(target, "Krypto", `${requesterName} wants a rematch!`);
});
