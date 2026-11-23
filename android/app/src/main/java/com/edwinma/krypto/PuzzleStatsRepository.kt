package com.edwinma.krypto

import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions

/** Aggregate per-puzzle telemetry in `puzzleStats/{id}`, same doc shape and id
 *  scheme as Krypto/PuzzleStatsService.swift so both platforms pool together. */
object PuzzleStatsRepository {
    private val db get() = FirebaseFirestore.getInstance()
    private const val BUCKET_SECONDS = 10
    private const val BUCKET_COUNT = 61
    private const val BUCKETS_FIELD = "solveTimeBucketsV2"

    fun id(hand: List<Int>, target: Int): String = (hand.sorted().map { it.toString() } + "t$target").joinToString("-")

    /** Writes go to a random shard under the puzzle, `puzzleStats/{id}/shards/{0…7}`,
     *  not the puzzle doc itself: one document sustains ~1 write/s and the daily
     *  puzzle is one document every player hits in the same hours. Same scheme
     *  and count as `PuzzleStats.shardCount` on iOS, which sums them on read. */
    private const val SHARD_COUNT = 8
    private fun shardRef(hand: List<Int>, target: Int) =
        db.collection("puzzleStats").document(id(hand, target))
            .collection("shards").document((0 until SHARD_COUNT).random().toString())

    fun recordDealt(hand: List<Int>, target: Int) {
        shardRef(hand, target).set(mapOf(
            "timesDealt" to FieldValue.increment(1), "updatedAt" to FieldValue.serverTimestamp(),
        ), SetOptions.merge())
    }

    fun recordSolved(hand: List<Int>, target: Int, elapsedSeconds: Int, solverName: String) {
        val elapsedMs = elapsedSeconds.toLong() * 1000
        val bucket = (maxOf(elapsedSeconds, 0) / BUCKET_SECONDS).coerceAtMost(BUCKET_COUNT - 1).toString()
        val ref = shardRef(hand, target)
        db.runTransaction { tx ->
            val fastest = tx.get(ref).getLong("fastestSolveTimeMs")
            val update = mutableMapOf<String, Any>(
                "timesSolved" to FieldValue.increment(1),
                "totalSolveTimeMs" to FieldValue.increment(elapsedMs),
                BUCKETS_FIELD to mapOf(bucket to FieldValue.increment(1)),
                "updatedAt" to FieldValue.serverTimestamp(),
            )
            if (fastest == null || elapsedMs < fastest) {
                update["fastestSolveTimeMs"] = elapsedMs
                update["fastestSolveBy"] = solverName
            }
            tx.set(ref, update, SetOptions.merge())
            null
        }.addOnFailureListener { android.util.Log.w("PuzzleStats", "recordSolved failed", it) }
    }
}
