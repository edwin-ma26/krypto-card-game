/** Server-side port of the client's Krypto deck + solver, so the server is
 * the sole authority for dealing hands (matches Krypto/GameEngine.swift). */

function gcd(a: number, b: number): number {
  a = Math.abs(a);
  b = Math.abs(b);
  while (b) {
    [a, b] = [b, a % b];
  }
  return a || 1;
}

class Fraction {
  readonly num: number;
  readonly den: number;

  constructor(num: number, den = 1) {
    const sign = den < 0 ? -1 : 1;
    const g = gcd(num, den);
    this.num = (sign * num) / g;
    this.den = (sign * den) / g;
  }

  equals(other: Fraction): boolean {
    return this.num === other.num && this.den === other.den;
  }

  static add(a: Fraction, b: Fraction): Fraction {
    return new Fraction(a.num * b.den + b.num * a.den, a.den * b.den);
  }

  static sub(a: Fraction, b: Fraction): Fraction {
    return new Fraction(a.num * b.den - b.num * a.den, a.den * b.den);
  }

  static mul(a: Fraction, b: Fraction): Fraction {
    return new Fraction(a.num * b.num, a.den * b.den);
  }

  static div(a: Fraction, b: Fraction): Fraction | null {
    return b.num === 0 ? null : new Fraction(a.num * b.den, a.den * b.num);
  }
}

function buildDeck(): number[] {
  const deck: number[] = [];
  for (let v = 1; v <= 6; v++) for (let i = 0; i < 3; i++) deck.push(v);
  for (let v = 7; v <= 10; v++) for (let i = 0; i < 4; i++) deck.push(v);
  for (let v = 11; v <= 17; v++) for (let i = 0; i < 2; i++) deck.push(v);
  for (let v = 18; v <= 25; v++) deck.push(v);
  return deck;
}

function shuffled<T>(input: T[]): T[] {
  const arr = [...input];
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

function solve(values: Fraction[], target: Fraction): boolean {
  if (values.length === 1) return values[0].equals(target);
  for (let i = 0; i < values.length; i++) {
    for (let j = 0; j < values.length; j++) {
      if (i === j) continue;
      const rest = values.filter((_, k) => k !== i && k !== j);
      const a = values[i];
      const b = values[j];
      const results = [Fraction.add(a, b), Fraction.sub(a, b), Fraction.mul(a, b), Fraction.div(a, b)];
      for (const result of results) {
        if (result && solve([...rest, result], target)) return true;
      }
    }
  }
  return false;
}

/** Counts successful solution branches (not deduplicated for symmetric ops —
 * this is a difficulty signal, not a real solution catalog), stopping early
 * past `cap` since a puzzle with dozens of solutions is "easy" regardless of
 * the exact count. Cheap enough to run once per deal: a 5-card hand's search
 * tree is only ~20*12*6*2 leaves fully expanded, capped well below that. */
function countSolutions(values: Fraction[], target: Fraction, cap: number): number {
  if (values.length === 1) return values[0].equals(target) ? 1 : 0;
  let count = 0;
  for (let i = 0; i < values.length && count < cap; i++) {
    for (let j = 0; j < values.length && count < cap; j++) {
      if (i === j) continue;
      const rest = values.filter((_, k) => k !== i && k !== j);
      const a = values[i];
      const b = values[j];
      const results = [Fraction.add(a, b), Fraction.sub(a, b), Fraction.mul(a, b), Fraction.div(a, b)];
      for (const result of results) {
        if (result) count += countSolutions([...rest, result], target, cap - count);
      }
    }
  }
  return count;
}

/** Difficulty proxy, since every hand takes the same 4 combine-steps to
 * solve: a puzzle with only a handful of solution paths plays much harder to
 * *find* than one with dozens, even though both take one "step count". Maps
 * solution count to an estimated solve time via decay toward `MIN_SECONDS`,
 * used as the daily puzzle's target time before enough real solves exist to
 * trust `puzzleStats.averageSolveSeconds` on its own (see
 * `Krypto/PuzzleStatsService.swift`'s blended `targetSeconds`). */
export function estimateSolveSeconds(hand: number[], target: number): number {
  const MIN_SECONDS = 30;
  const MAX_SECONDS = 180;
  const HALF_LIFE = 6; // solution count at which the estimate is roughly midpoint
  const SEARCH_CAP = 30; // beyond this, "how much easier" no longer matters
  const solutionCount = countSolutions(
    hand.map((v) => new Fraction(v)),
    new Fraction(target),
    SEARCH_CAP
  );
  const seconds = MIN_SECONDS + (MAX_SECONDS - MIN_SECONDS) / (1 + solutionCount / HALF_LIFE);
  return Math.round(seconds);
}

/** Deterministic doc id for a hand+target, independent of deal order — mirrors
 * `PuzzleStats.id` in Krypto/PuzzleStatsService.swift so both the client and
 * this server-side ranked deal path pool stats into the same puzzleStats doc. */
export function canonicalPuzzleId(hand: number[], target: number): string {
  return [...hand]
    .sort((a, b) => a - b)
    .map(String)
    .concat(`t${target}`)
    .join("-");
}

export function dealKrypto(): { hand: number[]; target: number } {
  const deck = buildDeck();
  for (let attempt = 0; attempt < 500; attempt++) {
    const draw = shuffled(deck);
    const hand = draw.slice(0, 5);
    const target = draw[5];
    if (solve(hand.map((v) => new Fraction(v)), new Fraction(target))) {
      return { hand, target };
    }
  }
  // Should be unreachable given the deck's density, but never leave a match unsolvable.
  return { hand: [1, 2, 3, 4, 5], target: 15 };
}
