package com.edwinma.krypto

data class SolutionStep(val a: Fraction, val op: Operation, val b: Fraction, val result: Fraction)

/** Pure game rules, a line-for-line port of `enum Krypto` in Krypto/GameEngine.swift. */
object KryptoEngine {
    /** Standard Krypto deck: 1–6 ×3, 7–10 ×4, 11–17 ×2, 18–25 ×1 (56 cards). */
    val deck: List<Int>
        get() = buildList {
            for (v in 1..6) repeat(3) { add(v) }
            for (v in 7..10) repeat(4) { add(v) }
            for (v in 11..17) repeat(2) { add(v) }
            for (v in 18..25) add(v)
        }

    /** Deals 5 hand cards plus a target, redealing until the hand is solvable. */
    fun deal(): Pair<List<Int>, Int> {
        while (true) {
            val shuffled = deck.shuffled()
            val hand = shuffled.take(5)
            val target = shuffled[5]
            if (solve(hand.map { Fraction.of(it) }, Fraction.of(target)) != null) return hand to target
        }
    }

    /** Number of distinct solution paths, stopping early at `cap`. Same count
     *  as `countSolutions` in functions/src/krypto.ts. */
    fun countSolutions(values: List<Fraction>, target: Fraction, cap: Int): Int {
        if (values.size == 1) return if (values[0] == target) 1 else 0
        var count = 0
        for (i in values.indices) {
            if (count >= cap) break
            for (j in values.indices) {
                if (i == j || count >= cap) continue
                val rest = values.toMutableList()
                rest.removeAt(maxOf(i, j)); rest.removeAt(minOf(i, j))
                for (op in Operation.entries) {
                    val result = op.apply(values[i], values[j]) ?: continue
                    count += countSolutions(rest + result, target, cap - count)
                    if (count >= cap) break
                }
            }
        }
        return count
    }

    /** Difficulty-based solve-time estimate, 30–180s. Same curve as the server. */
    fun estimateSolveSeconds(hand: List<Int>, target: Int): Int {
        val minSeconds = 30.0; val maxSeconds = 180.0; val halfLife = 6.0; val searchCap = 30
        val solutions = countSolutions(hand.map { Fraction.of(it) }, Fraction.of(target), searchCap)
        return Math.round(minSeconds + (maxSeconds - minSeconds) / (1 + solutions / halfLife)).toInt()
    }

    /** Depth-first search over all pairings and operations; returns the steps of one solution. */
    fun solve(values: List<Fraction>, target: Fraction): List<SolutionStep>? {
        if (values.size == 1) return if (values[0] == target) emptyList() else null
        for (i in values.indices) {
            for (j in values.indices) {
                if (i == j) continue
                val rest = values.toMutableList()
                val b = rest.removeAt(maxOf(i, j))
                val a = rest.removeAt(minOf(i, j))
                val (x, y) = if (i < j) a to b else b to a
                for (op in Operation.entries) {
                    // + and × are commutative; skip the mirrored pair once.
                    if ((op == Operation.ADD || op == Operation.MULTIPLY) && i > j) continue
                    val result = op.apply(x, y) ?: continue
                    val steps = solve(rest + result, target) ?: continue
                    return listOf(SolutionStep(x, op, y, result)) + steps
                }
            }
        }
        return null
    }
}
