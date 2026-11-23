/** Server-side cleanup when a player deletes their account.
 *
 * The app only re-authenticates and deletes the Firebase Auth user; this
 * trigger removes everything that user owned in Firestore, so the cleanup
 * runs to completion even if the app is killed mid-delete and also covers
 * accounts deleted from the Firebase console. Deleting a Firestore document
 * does not delete its subcollections, so `users/{uid}` goes through
 * `recursiveDelete` (solves history, friend requests).
 *
 * Kept: ranked matches and rooms, which are the opponent's history too, and
 * `referrals/{otherUid}` records that name this player as the referrer, which
 * belong to the referred players.
 */

import * as functionsV1 from "firebase-functions/v1";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";

export const onUserDeleted = functionsV1.auth.user().onDelete(async (user) => {
  const uid = user.uid;
  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);

  // Each step is independent; one failing must not stop the others.
  const step = async (label: string, run: () => Promise<unknown>) => {
    try {
      await run();
    } catch (error) {
      logger.error(`onUserDeleted ${label} failed for ${uid}`, error);
    }
  };

  await step("friends", async () => {
    // Query rather than trust the (possibly already deleted) user doc's own
    // friends array, so a half-finished client cleanup can't leave dangling
    // references on other players' friend lists.
    const friends = await db.collection("users").where("friends", "array-contains", uid).get();
    if (friends.empty) return;
    const batch = db.batch();
    friends.docs.forEach((doc) => batch.update(doc.ref, { friends: FieldValue.arrayRemove(uid) }));
    await batch.commit();
  });

  await step("usernames", async () => {
    const names = await db.collection("usernames").where("uid", "==", uid).get();
    if (names.empty) return;
    const batch = db.batch();
    names.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
  });

  await step("referralCodes", async () => {
    const codes = await db.collection("referralCodes").where("uid", "==", uid).get();
    if (codes.empty) return;
    const batch = db.batch();
    codes.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
  });

  await step("singletons", async () => {
    const batch = db.batch();
    batch.delete(db.collection("referrals").doc(uid));
    batch.delete(db.collection("challenges").doc(uid));
    batch.delete(db.collection("matchmakingQueue").doc(uid));
    await batch.commit();
  });

  await step("userDoc", () => db.recursiveDelete(userRef));

  logger.info(`onUserDeleted cleaned up ${uid}`);
});
