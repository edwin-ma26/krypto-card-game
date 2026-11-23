import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { tryPairWithHuman, matchWithBot, loadBotConfig, jitteredWaitMs, rematchWaitMs, sleep, finishStaleBotMatches } from "./ranked";

initializeApp();
const db = getFirestore();

export { onFriendRequestCreated, onFriendAdded, onChallengeCreated, onRankedRematchRequested } from "./notifications";
export { prepareDailyPuzzle, publishDailyPuzzle } from "./dailyPuzzle";
export { checkEmail } from "./auth";
export { onUserDeleted } from "./accountDeletion";

/**
 * Fires whenever a player joins the ranked queue. Pairs with the closest-Elo
 * waiting human immediately if there is one. Otherwise — when bots are
 * enabled in Remote Config — it keeps this invocation alive for a jittered
 * ~20s, tries the human search once more, and then plays the ticket against
 * a roster bot (see ranked.ts). The generous timeout is what lets one
 * invocation drive a whole bot match; a human-vs-human pairing returns in
 * milliseconds as before.
 */
export const onQueueJoin = onDocumentCreated(
  { document: "matchmakingQueue/{uid}", timeoutSeconds: 540 },
  async (event) => {
    const uid = event.params.uid;
    const data = event.data?.data();
    if (!data || data.status !== "waiting") return;
    const myElo: number = typeof data.elo === "number" ? data.elo : 1200;
    // Rematch hints from the client (see RankedService.RematchHint).
    const rematchWith = typeof data.rematchWith === "string" ? data.rematchWith : undefined;
    const rematchBot = typeof data.rematchBot === "string" ? data.rematchBot : undefined;

    // A failing human search (e.g. a missing index) must not strand the
    // ticket: log it and carry on to the bot path, which needs no queries.
    const pairHuman = async () => {
      try {
        return await tryPairWithHuman(uid, myElo, rematchWith);
      } catch (error) {
        console.error("tryPairWithHuman failed", error);
        return false;
      }
    };

    if (await pairHuman()) return;

    const config = await loadBotConfig();
    if (!config.enabled) return;

    // A bot rematch is "accepted" after a short pause rather than the full
    // wait; everything else gets the normal jittered wait for a human first.
    await sleep(rematchBot ? rematchWaitMs() : jitteredWaitMs(config));
    // Someone may have joined (and been paired with us by *their* trigger)
    // during the wait, or we may have cancelled — both are handled inside.
    if (await pairHuman()) return;
    await matchWithBot(uid, myElo, config, rematchBot);
  }
);

/**
 * When someone joins on a player's referral code (a `referrals/{referredUid}`
 * doc is created), evolve that player's Founding Pup immediately and
 * authoritatively.
 *
 * The client mirrors `hasFoundingPup` for itself — the badge is earned offline
 * on the pre-launch screen, so the device is the only witness — but
 * `foundingPupStage` is written *only* here, via the Admin SDK, bypassing the
 * security rules. That's what makes the evolution tamper-proof: it always
 * equals the real referral count and can't be inflated by a hand-crafted
 * profile write (see the `users/{uid}` rule).
 *
 * Stages mirror `BadgeStage` on the client: 0 pup, 1 third-eye, 2 many-eyed,
 * 3 cosmic, capped at 3.
 */
export const onReferralCreated = onDocumentCreated("referrals/{referredUid}", async (event) => {
  const referrerUid = event.data?.data()?.referrerUid;
  if (typeof referrerUid !== "string" || !referrerUid) return;

  const countSnap = await db
    .collection("referrals")
    .where("referrerUid", "==", referrerUid)
    .count()
    .get();
  const stage = Math.min(countSnap.data().count, 3);

  await db.collection("users").doc(referrerUid).set(
    { hasFoundingPup: true, foundingPupStage: stage },
    { merge: true }
  );
});

/** Purges queue tickets abandoned by a force-quit or crashed session, and
 * closes out any bot match whose driving invocation died (see ranked.ts). */
export const cleanupStaleQueue = onSchedule("every 2 minutes", async () => {
  await finishStaleBotMatches().catch((error) => console.error("finishStaleBotMatches", error));
  const cutoffMillis = Date.now() - 90 * 1000;
  // "matched" tickets are supposed to be deleted by the client on leaving,
  // but a force-quit (or an older build) leaves them behind. They matter
  // because rules only allow *creating* a waiting ticket, so a leftover
  // blocks that player's next join and can drop them into the old match.
  const matchedCutoffMillis = Date.now() - 10 * 60 * 1000;
  const [waiting, matched] = await Promise.all([
    db.collection("matchmakingQueue").where("status", "==", "waiting").get(),
    db.collection("matchmakingQueue").where("status", "==", "matched").get(),
  ]);

  const stale = [
    ...waiting.docs.filter((doc) => (doc.data().joinedAt?.toMillis?.() ?? 0) < cutoffMillis),
    ...matched.docs.filter((doc) => (doc.data().joinedAt?.toMillis?.() ?? 0) < matchedCutoffMillis),
  ];
  if (stale.length === 0) return;

  const batch = db.batch();
  stale.forEach((doc) => batch.delete(doc.ref));
  await batch.commit();
});
