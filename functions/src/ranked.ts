/** Ranked matchmaking: human pairing plus the bot fallback.
 *
 * `onQueueJoin` (index.ts) calls `tryPairWithHuman` the instant a ticket is
 * created. If nobody's waiting it holds the invocation open for a jittered
 * ~20s (`jitteredWaitMs`), retries the human search, and only then falls
 * back to `matchWithBot`, which creates a normal-looking `rankedMatches`
 * doc against a roster bot and drives it to completion from the same
 * invocation (`driveBotMatch`): a few `cardsLeft` ticks spread over the
 * bot's solve time, then the winner write if the human hasn't finished.
 * The shipped client renders all of that exactly like a human opponent —
 * it only ever sees cards-left and the final winner — so bots need no app
 * update.
 *
 * Everything is tunable from Remote Config (`loadBotConfig`) and off by
 * default, so deploying this is inert until `ranked_bots_enabled` flips. */

import { getFirestore, FieldValue, Transaction, DocumentReference } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { dealKrypto, canonicalPuzzleId, estimateSolveSeconds } from "./krypto";

// Resolved lazily: this module is imported (and so evaluated) before
// index.ts gets to call `initializeApp()`, so a top-level `getFirestore()`
// here would throw on cold start.
const db = () => getFirestore();

// MARK: - Config

export interface BotConfig {
  enabled: boolean;
  /** Centre of the wait before a bot is offered. */
  waitSeconds: number;
  /** Std-dev of the (gaussian) jitter around `waitSeconds`. */
  waitJitterSeconds: number;
  /** How often a player of the bot's own rating should beat it. 0.5 = fair. */
  targetWinRate: number;
}

const DEFAULT_CONFIG: BotConfig = { enabled: false, waitSeconds: 20, waitJitterSeconds: 5, targetWinRate: 0.5 };

/** Where the bot knobs live: a single admin-only Firestore doc (no rule in
 * firestore.rules grants clients access, so only the console / Admin SDK
 * can change it). Remote Config was the first choice, but its *server*
 * templates are a separate namespace from the app's template and this
 * project has none, so reads came back NOT_FOUND and bots silently stayed
 * off. The app's Remote Config copy of these values (used only for the
 * wait-time estimate shown while searching) should be kept in step. */
const CONFIG_DOC = "config/rankedBots";

/** Reads the bot knobs, falling back to the (disabled) defaults for any
 * missing or malformed field — so a missing doc can never switch bots on. */
export async function loadBotConfig(): Promise<BotConfig> {
  try {
    const snap = await db().doc(CONFIG_DOC).get();
    const data = snap.data() ?? {};
    const num = (key: string, fallback: number, min: number, max: number) =>
      typeof data[key] === "number" ? clamp(data[key], min, max) : fallback;
    const resolved: BotConfig = {
      enabled: data.enabled === true,
      waitSeconds: num("waitSeconds", DEFAULT_CONFIG.waitSeconds, 5, 120),
      waitJitterSeconds: num("waitJitterSeconds", DEFAULT_CONFIG.waitJitterSeconds, 0, 60),
      targetWinRate: num("targetWinRate", DEFAULT_CONFIG.targetWinRate, 0.1, 0.9),
    };
    logger.info("ranked bot config", { ...resolved, source: snap.exists ? CONFIG_DOC : "defaults (doc missing)" });
    return resolved;
  } catch (error) {
    logger.warn("ranked bot config unavailable, bots stay off", error);
    return DEFAULT_CONFIG;
  }
}

/** The wait before offering a bot: gaussian around `waitSeconds` so it's
 * never the same number twice, clamped so it can't be instant or absurd. */
export function jitteredWaitMs(config: BotConfig): number {
  const seconds = config.waitSeconds + gaussian() * config.waitJitterSeconds;
  return Math.round(clamp(seconds, config.waitSeconds * 0.6, config.waitSeconds * 1.9) * 1000);
}

/** A bot "accepting a rematch": short, but not instant, and still jittered. */
export function rematchWaitMs(): number {
  return Math.round(clamp(3.5 + gaussian() * 1.2, 2, 7) * 1000);
}

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

// MARK: - Human pairing

/** Looks for the nearest-Elo waiting human and pairs atomically. Returns
 * true if a match was made (or this ticket is no longer waiting, in which
 * case there's nothing more to do either way). */
export async function tryPairWithHuman(uid: string, myElo: number, preferredUid?: string): Promise<boolean> {
  const queueRef = db().collection("matchmakingQueue");
  return db().runTransaction(async (tx) => {
    const myRef = queueRef.doc(uid);
    const mySnap = await tx.get(myRef);
    if (mySnap.data()?.status !== "waiting") return true; // Already matched or cancelled.

    // A rematch request: if the previous opponent is waiting too, pair them
    // straight away regardless of rating; otherwise fall through to the
    // ordinary nearest-rating search.
    if (preferredUid && preferredUid !== uid) {
      const prefRef = queueRef.doc(preferredUid);
      const prefSnap = await tx.get(prefRef);
      const pref = prefSnap.data();
      if (pref?.status === "waiting") {
        const prefElo: number = typeof pref.elo === "number" ? pref.elo : 1200;
        const [nameA, nameB] = await Promise.all([displayName(tx, uid), displayName(tx, preferredUid)]);
        const { ref: matchRef } = createMatch(tx, { playerA: uid, playerB: preferredUid, eloA: myElo, eloB: prefElo, isBot: false, nameA, nameB });
        tx.update(myRef, { status: "matched", matchId: matchRef.id });
        tx.update(prefRef, { status: "matched", matchId: matchRef.id });
        return true;
      }
    }

    // Nearest waiting opponent by Elo, via two range queries against the
    // (status, elo) composite index instead of scanning every ticket. Elo
    // is a total order, so the true nearest neighbour is adjacent in sorted
    // order; `limit(2)` on the ascending side covers our own ticket tying.
    const [above, below] = await Promise.all([
      tx.get(queueRef.where("status", "==", "waiting").where("elo", ">=", myElo).orderBy("elo", "asc").limit(2)),
      tx.get(queueRef.where("status", "==", "waiting").where("elo", "<", myElo).orderBy("elo", "desc").limit(1)),
    ]);

    let bestId: string | null = null;
    let bestElo = 1200;
    let bestDiff = Infinity;
    for (const doc of [...above.docs, ...below.docs]) {
      if (doc.id === uid) continue;
      const elo: number = typeof doc.data().elo === "number" ? doc.data().elo : 1200;
      const diff = Math.abs(elo - myElo);
      if (diff < bestDiff) {
        bestDiff = diff;
        bestId = doc.id;
        bestElo = elo;
      }
    }
    if (!bestId) return false;

    const oppRef = queueRef.doc(bestId);
    const oppSnap = await tx.get(oppRef);
    if (oppSnap.data()?.status !== "waiting") return false;

    const [nameA, nameB] = await Promise.all([displayName(tx, uid), displayName(tx, bestId)]);
    const { ref: matchRef } = createMatch(tx, { playerA: uid, playerB: bestId, eloA: myElo, eloB: bestElo, isBot: false, nameA, nameB });
    tx.update(myRef, { status: "matched", matchId: matchRef.id });
    tx.update(oppRef, { status: "matched", matchId: matchRef.id });
    return true;
  });
}

interface MatchParticipants {
  playerA: string;
  playerB: string;
  eloA: number;
  eloB: number;
  isBot: boolean;
  nameA: string;
  nameB: string;
}

/** A player's display name for the match doc, read inside the pairing
 * transaction so the client never needs a second profile fetch. */
async function displayName(tx: Transaction, uid: string): Promise<string> {
  const snap = await tx.get(db().collection("users").doc(uid));
  const name = snap.data()?.displayName;
  return typeof name === "string" && name.trim() ? name.trim() : "Player";
}

/** Deals and writes a `rankedMatches` doc inside `tx`, bumping the shared
 * puzzleStats "dealt" counter the same way every other mode does. */
function createMatch(
  tx: Transaction,
  p: MatchParticipants
): { ref: DocumentReference; hand: number[]; target: number } {
  const matchRef = db().collection("rankedMatches").doc();
  const { hand, target } = dealKrypto();
  tx.set(matchRef, {
    playerA: p.playerA,
    playerB: p.playerB,
    eloA: p.eloA,
    eloB: p.eloB,
    hand,
    target,
    status: "playing",
    cardsLeft: { [p.playerA]: 5, [p.playerB]: 5 },
    nameA: p.nameA,
    nameB: p.nameB,
    isBot: p.isBot,
    createdAt: FieldValue.serverTimestamp(),
  });
  const puzzleStatsRef = db().collection("puzzleStats").doc(canonicalPuzzleId(hand, target));
  tx.set(
    puzzleStatsRef,
    {
      hand: [...hand].sort((a, b) => a - b),
      target,
      timesDealt: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  return { ref: matchRef, hand, target };
}

// MARK: - Bot roster

/** Bots live in their own collection, not `users`, so they can never show
 * up in friend search, referrals or a future leaderboard by accident. Their
 * handles are generated to look like the real player base (first names with
 * digits, initial+surname, "simply"-style prefixes — the same shapes real
 * sign-ups produce), rather than taken from any list. Ids are stable
 * (`bot-<handle>`) so a bot's Elo can drift with its record across deploys. */
const FIRST_NAMES = [
  "marie", "greg", "harrison", "abe", "zion", "alan", "inga", "braxton", "jennifer", "nora",
  "felix", "priya", "mateo", "hana", "luca", "amara", "theo", "ines", "kenji", "sofia",
  "omar", "leila", "jonas", "maya", "rafael", "elin", "dev", "zara", "milo", "aisha",
  "noah", "yuki", "ivan", "chloe", "tariq", "greta", "sam", "nadia", "arjun", "elena",
  "owen", "lucia", "caleb", "mira", "jude", "tessa", "ravi", "hollis", "june", "emeka",
];
const LAST_NAMES = [
  "niles", "smith", "chen", "park", "wang", "lopez", "okafor", "murphy", "silva", "kim",
  "patel", "nguyen", "brooks", "fischer", "rossi", "haddad", "novak", "berg", "reyes", "cole",
];
const PREFIXES = ["simply", "just", "its", "the", "real", "hey"];

function botHandle(i: number): string {
  const first = FIRST_NAMES[i % FIRST_NAMES.length];
  const last = LAST_NAMES[(i * 7) % LAST_NAMES.length];
  const digits = String(1000 + ((i * 7919) % 9000));
  switch (i % 6) {
    case 0: return `${first}${digits}`; // marie1088
    case 1: return `${first[0]}${last}`; // mjniles
    case 2: return `${first}${last[0]}${digits.slice(0, 2)}`; // abej42
    case 3: return `${PREFIXES[i % PREFIXES.length]}${first}`; // simplyharrison
    case 4: return `${first}_${last}`; // nora_kim
    default: return `${first}.${last[0]}`; // felix.c
  }
}

const ROSTER_SIZE = 60;

interface Bot {
  id: string;
  name: string;
  elo: number;
}

async function ensureRoster(): Promise<Bot[]> {
  const col = db().collection("bots");
  const existing = await col.get();
  if (existing.size >= ROSTER_SIZE) {
    return existing.docs.map((d) => ({
      id: d.id,
      name: typeof d.data().name === "string" ? d.data().name : d.id.replace(/^bot-/, ""),
      elo: typeof d.data().elo === "number" ? d.data().elo : 1200,
    }));
  }
  // First use (or a roster grown since): seed/top up, spread across the
  // rating range players actually land in so there's always someone close.
  const batch = db().batch();
  const bots: Bot[] = Array.from({ length: ROSTER_SIZE }, (_, i) => {
    const name = botHandle(i);
    return { id: `bot-${name.replace(/[^a-z0-9]/g, "")}`, name, elo: 950 + Math.round((i / (ROSTER_SIZE - 1)) * 550) };
  });
  const have = new Set(existing.docs.map((d) => d.id));
  for (const bot of bots) {
    if (have.has(bot.id)) continue;
    batch.set(col.doc(bot.id), { name: bot.name, elo: bot.elo, wins: 0, losses: 0, createdAt: FieldValue.serverTimestamp() });
  }
  await batch.commit();
  logger.info("seeded ranked bot roster", { count: bots.length });
  const refreshed = await col.get();
  return refreshed.docs.map((d) => ({
    id: d.id,
    name: typeof d.data().name === "string" ? d.data().name : d.id.replace(/^bot-/, ""),
    elo: typeof d.data().elo === "number" ? d.data().elo : 1200,
  }));
}

/** One of the few bots nearest the player's rating, chosen at random so a
 * player who re-queues doesn't keep drawing the same opponent. */
function pickBot(roster: Bot[], elo: number): Bot {
  const nearest = [...roster].sort((a, b) => Math.abs(a.elo - elo) - Math.abs(b.elo - elo)).slice(0, 4);
  return nearest[Math.floor(Math.random() * nearest.length)];
}

// MARK: - Bot match

/** Creates a bot match for `uid` if their ticket is still waiting, then
 * plays it out (this call returns only when the match is over, so the
 * invoking function must allow for `MAX_BOT_SOLVE_SECONDS` of runtime). */
export async function matchWithBot(uid: string, myElo: number, config: BotConfig, preferredBotId?: string): Promise<void> {
  const roster = await ensureRoster();
  const bot = roster.find((b) => b.id === preferredBotId) ?? pickBot(roster, myElo);
  const queueRef = db().collection("matchmakingQueue").doc(uid);

  const created = await db().runTransaction(async (tx) => {
    const ticket = await tx.get(queueRef);
    if (ticket.data()?.status !== "waiting") return null;
    const nameA = await displayName(tx, uid);
    const match = createMatch(tx, { playerA: uid, playerB: bot.id, eloA: myElo, eloB: bot.elo, isBot: true, nameA, nameB: bot.name });
    tx.update(queueRef, { status: "matched", matchId: match.ref.id });
    return match;
  });
  if (!created) return; // Cancelled, or a human grabbed them in the meantime.

  const solveSeconds = botSolveSeconds(created.hand, created.target, bot.elo, config.targetWinRate);
  logger.info("bot match created", { match: created.ref.id, bot: bot.id, botElo: bot.elo, playerElo: myElo, solveSeconds });
  await driveBotMatch(created.ref, bot, uid, myElo, solveSeconds);
}

/** Mirrors `RankedMatchView.introSeconds` on the client. */
const INTRO_MS = 3000;
const MIN_BOT_SOLVE_SECONDS = 18;
export const MAX_BOT_SOLVE_SECONDS = 300;

/** How long this bot takes on this puzzle. Starts from the puzzle's own
 * difficulty estimate (what a middling player needs), speeds up or slows
 * down with the bot's rating, biases toward the configured win rate, and
 * adds log-normal noise so the same bot on the same puzzle isn't a clock. */
function botSolveSeconds(hand: number[], target: number, botElo: number, targetWinRate: number): number {
  const base = estimateSolveSeconds(hand, target); // 30…180
  const skill = Math.pow(1.15, (1200 - botElo) / 100); // 100 Elo higher ⇒ ~13% faster
  const fairness = 0.5 / targetWinRate; // >1 slows the bot so humans win more often
  const noise = Math.exp(gaussian() * 0.35);
  return Math.round(clamp(base * skill * fairness * noise, MIN_BOT_SOLVE_SECONDS, MAX_BOT_SOLVE_SECONDS));
}

/** Plays the bot's side: cards-left ticks 4, 3, 2 at random points through
 * the solve, then the winner write at `solveSeconds` unless the human has
 * already won. Bails out (and records the loss) the moment the match
 * stops being `playing`. */
async function driveBotMatch(
  matchRef: DocumentReference,
  bot: Bot,
  humanUid: string,
  humanElo: number,
  solveSeconds: number
): Promise<void> {
  // Three interior tick times, sorted, kept off the very start and end.
  const ticks = [0, 0, 0]
    .map(() => 0.12 + Math.random() * 0.78)
    .sort((a, b) => a - b)
    .map((f) => Math.round(f * solveSeconds * 1000));
  const schedule: Array<{ atMs: number; cardsLeft: number }> = [
    { atMs: ticks[0], cardsLeft: 4 },
    { atMs: ticks[1], cardsLeft: 3 },
    { atMs: ticks[2], cardsLeft: 2 },
  ];

  // The client shows a 3s "opponent found" countdown before its clock
  // starts; the bot's clock starts at the same moment so the countdown
  // doesn't hand it a head start.
  const startedAt = Date.now() + INTRO_MS;
  for (const step of schedule) {
    await sleep(Math.max(0, startedAt + step.atMs - Date.now()));
    const snap = await matchRef.get();
    if (snap.data()?.status !== "playing") {
      // Ended early: either the human solved it, or they forfeited (which
      // records the bot as winner) — settle whichever it was.
      await settleBot(bot, humanElo, snap.data()?.winner === bot.id);
      return;
    }
    await matchRef.update({ [`cardsLeft.${bot.id}`]: step.cardsLeft });
  }

  await sleep(Math.max(0, startedAt + solveSeconds * 1000 - Date.now()));
  const botWon = await db().runTransaction(async (tx) => {
    const snap = await tx.get(matchRef);
    if (snap.data()?.winner) return false; // Human got there first.
    tx.update(matchRef, { winner: bot.id, status: "finished", [`cardsLeft.${bot.id}`]: 1 });
    return true;
  });
  await settleBot(bot, humanElo, botWon);
  logger.info("bot match finished", { match: matchRef.id, bot: bot.id, botWon, human: humanUid });
}

/** Drifts the bot's rating with the result so the roster keeps tracking the
 * players it actually faces. Same formula the client uses for humans. */
async function settleBot(bot: Bot, humanElo: number, botWon: boolean): Promise<void> {
  const K = 24;
  const expected = 1 / (1 + Math.pow(10, (humanElo - bot.elo) / 400));
  const delta = Math.round(K * ((botWon ? 1 : 0) - expected));
  await db()
    .collection("bots")
    .doc(bot.id)
    .set(
      {
        elo: clamp(bot.elo + delta, 600, 2400),
        wins: FieldValue.increment(botWon ? 1 : 0),
        losses: FieldValue.increment(botWon ? 0 : 1),
        lastPlayedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
}

/** Backstop for a bot match whose driving invocation died (deploy mid-game,
 * instance recycled): anything still `playing` well past the longest
 * possible bot solve is awarded to the bot so the human isn't stuck. */
export async function finishStaleBotMatches(): Promise<void> {
  const cutoff = new Date(Date.now() - (MAX_BOT_SOLVE_SECONDS + 120) * 1000);
  const stale = await db()
    .collection("rankedMatches")
    .where("isBot", "==", true)
    .where("status", "==", "playing")
    .where("createdAt", "<", cutoff)
    .get();
  if (stale.empty) return;
  const batch = db().batch();
  for (const doc of stale.docs) {
    const botId: string = doc.data().playerB;
    batch.update(doc.ref, { winner: botId, status: "finished", [`cardsLeft.${botId}`]: 1 });
  }
  await batch.commit();
  logger.warn("finished stale bot matches", { count: stale.size });
}

// MARK: - Helpers

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/** Standard normal sample (Box–Muller). */
function gaussian(): number {
  const u = 1 - Math.random();
  const v = Math.random();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}
