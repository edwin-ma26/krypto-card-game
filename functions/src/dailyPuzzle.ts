/** Deals the shared puzzle-of-the-day, server-side, so every player
 * worldwide sees the identical hand+target for the same UTC calendar date —
 * the "midnight UTC, global" boundary the client's `DailyPuzzleService` reads
 * against. Client writes to `dailyPuzzles/{date}` are blocked by security
 * rules; these scheduled functions are the sole writers.
 *
 * Split into two steps so the (slightly expensive — a redeal loop plus a
 * solution-count search for `estimateSolveSeconds`) work happens a day ahead
 * of when the puzzle goes live, not in a race against midnight:
 *
 *  - `prepareDailyPuzzle` (23:00 UTC, the day before) deals tomorrow's puzzle
 *    and stages it in `dailyPuzzleStaging/{date}` — a collection with no
 *    `firestore.rules` entry, so it's admin-SDK-only and can't be read by a
 *    client the way `dailyPuzzles/{date}` can. Staging the actual puzzle
 *    there instead of publishing it early is what keeps it spoiler-free.
 *  - `publishDailyPuzzle` (00:00 UTC) just copies that staged puzzle into the
 *    public `dailyPuzzles/{date}` doc — cheap and fast, so a client reading
 *    right at the midnight boundary no longer risks the multi-second "isn't
 *    dealt yet" gap `DailyPuzzleService.load` used to retry around. Falls
 *    back to dealing on the spot if, for whatever reason, nothing was staged
 *    (e.g. this is the first day this pipeline has run at all). */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { dealKrypto, canonicalPuzzleId, estimateSolveSeconds } from "./krypto";

/** How many recent days' puzzle ids to avoid repeating. */
const RECENT_HISTORY_SIZE = 30;
/** Redeal attempts before just accepting a repeat rather than looping forever. */
const MAX_DEAL_ATTEMPTS = 25;

interface StagedPuzzle {
  hand: number[];
  target: number;
  id: string;
  estimatedSolveSeconds: number;
}

function utcDateKey(d: Date): string {
  return d.toISOString().slice(0, 10); // "YYYY-MM-DD"
}

function tomorrowKeyUTC(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + 1);
  return utcDateKey(d);
}

/** Deals a hand+target not among `recentIds`, giving up and accepting a
 * repeat after `MAX_DEAL_ATTEMPTS` rather than looping forever. */
function dealFreshPuzzle(recentIds: string[]): { hand: number[]; target: number; id: string } {
  let hand: number[] = [];
  let target = 0;
  let id = "";
  for (let attempt = 0; attempt < MAX_DEAL_ATTEMPTS; attempt++) {
    const dealt = dealKrypto();
    id = canonicalPuzzleId(dealt.hand, dealt.target);
    hand = dealt.hand;
    target = dealt.target;
    if (!recentIds.includes(id)) break;
  }
  return { hand, target, id };
}

/** Deals tomorrow's puzzle a day ahead and stages it out of clients' reach. */
export const prepareDailyPuzzle = onSchedule(
  { schedule: "0 23 * * *", timeZone: "UTC" },
  async () => {
    const db = getFirestore();
    const dateKey = tomorrowKeyUTC();
    const stagingRef = db.collection("dailyPuzzleStaging").doc(dateKey);
    const metaRef = db.collection("dailyPuzzles").doc("_meta");

    await db.runTransaction(async (tx) => {
      const [stagingSnap, metaSnap] = await Promise.all([tx.get(stagingRef), tx.get(metaRef)]);
      // Guards a manual re-run or a rare double-fire from redealing (and
      // burning another recent-id slot for) a day that's already staged.
      if (stagingSnap.exists) return;

      const recentIds: string[] = (metaSnap.data()?.recentIds as string[] | undefined) ?? [];
      const { hand, target, id } = dealFreshPuzzle(recentIds);

      const staged: StagedPuzzle = { hand, target, id, estimatedSolveSeconds: estimateSolveSeconds(hand, target) };
      tx.set(stagingRef, staged);
      tx.set(metaRef, { recentIds: [...recentIds, id].slice(-RECENT_HISTORY_SIZE) }, { merge: true });
    });
  }
);

/** Publishes today's puzzle from yesterday's staged deal. */
export const publishDailyPuzzle = onSchedule(
  { schedule: "0 0 * * *", timeZone: "UTC" },
  async () => {
    const db = getFirestore();
    const dateKey = utcDateKey(new Date());
    const dayRef = db.collection("dailyPuzzles").doc(dateKey);
    const stagingRef = db.collection("dailyPuzzleStaging").doc(dateKey);
    const metaRef = db.collection("dailyPuzzles").doc("_meta");

    await db.runTransaction(async (tx) => {
      const [daySnap, stagingSnap, metaSnap] = await Promise.all([
        tx.get(dayRef),
        tx.get(stagingRef),
        tx.get(metaRef),
      ]);
      // Guards a manual re-run or a rare double-fire from redealing a day
      // that's already live and possibly already being played.
      if (daySnap.exists) return;

      let hand: number[];
      let target: number;
      let id: string;
      let estimatedSolveSeconds: number;

      const staged = stagingSnap.data() as StagedPuzzle | undefined;
      if (staged) {
        ({ hand, target, id, estimatedSolveSeconds } = staged);
      } else {
        // Nothing was staged (e.g. `prepareDailyPuzzle` hasn't run yet on a
        // fresh deploy, or failed last night) — deal on the spot rather than
        // leaving today with no puzzle at all.
        const recentIds: string[] = (metaSnap.data()?.recentIds as string[] | undefined) ?? [];
        ({ hand, target, id } = dealFreshPuzzle(recentIds));
        estimatedSolveSeconds = estimateSolveSeconds(hand, target);
        tx.set(metaRef, { recentIds: [...recentIds, id].slice(-RECENT_HISTORY_SIZE) }, { merge: true });
      }

      tx.set(dayRef, { hand, target, createdAt: FieldValue.serverTimestamp() });
      if (staged) tx.delete(stagingRef);

      // Pools into the same aggregate telemetry every other mode reports
      // into (see Krypto/PuzzleStatsService.swift) — the daily puzzle is
      // dealt server-side, so its "dealt" event is recorded here instead of
      // by a client.
      const statsRef = db.collection("puzzleStats").doc(id);
      tx.set(
        statsRef,
        {
          hand: [...hand].sort((a, b) => a - b),
          target,
          timesDealt: FieldValue.increment(1),
          estimatedSolveSeconds,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });
  }
);
