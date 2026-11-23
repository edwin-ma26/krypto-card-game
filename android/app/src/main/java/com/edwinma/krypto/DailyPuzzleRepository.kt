package com.edwinma.krypto

import android.content.Context
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.delay
import kotlinx.coroutines.tasks.await
import java.time.LocalDate
import java.time.ZoneOffset

/** Reads today's server-dealt puzzle from `dailyPuzzles/{YYYY-MM-DD}` (UTC) and
 *  records a completion: locally for signed-out players, and into the user's
 *  streak fields for signed-in ones. Same contract as Krypto/DailyPuzzleService.swift. */
class DailyPuzzleRepository(context: Context) {
    data class Puzzle(val dateKey: String, val hand: List<Int>, val target: Int)
    data class Completion(val solveSeconds: Int, val streak: Int, val longestStreak: Int)

    private val db = FirebaseFirestore.getInstance()
    private val prefs = context.getSharedPreferences("dailyPuzzle", Context.MODE_PRIVATE)

    companion object {
        fun todayKeyUTC(): String = LocalDate.now(ZoneOffset.UTC).toString()
        fun dayBefore(key: String): String = LocalDate.parse(key).minusDays(1).toString()
    }

    /** Retries briefly around the midnight-UTC publish gap, like the iOS client. */
    suspend fun loadToday(): Puzzle {
        val today = todayKeyUTC()
        var attempt = 0
        while (true) {
            val data = runCatching { db.collection("dailyPuzzles").document(today).get().await().data }.getOrNull()
            @Suppress("UNCHECKED_CAST")
            val hand = (data?.get("hand") as? List<Number>)?.map { it.toInt() }
            val target = (data?.get("target") as? Number)?.toInt()
            if (hand != null && target != null) return Puzzle(today, hand, target)
            if (++attempt >= 4) error("Today's puzzle isn't ready yet — try again in a moment.")
            delay(1500)
        }
    }

    /** The player's existing completion of `dateKey`, if any. */
    suspend fun existingCompletion(dateKey: String): Completion? {
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        if (uid == null) {
            if (prefs.getString("completed.date", null) != dateKey) return null
            return Completion(prefs.getInt("completed.seconds", 0), 0, 0)
        }
        val data = runCatching { db.collection("users").document(uid).get().await().data }.getOrNull() ?: return null
        if (data["dailyLastCompletedDate"] != dateKey) return null
        return Completion(
            (data["dailyLastSolveSeconds"] as? Number)?.toInt() ?: 0,
            (data["dailyStreak"] as? Number)?.toInt() ?: 0,
            (data["dailyLongestStreak"] as? Number)?.toInt() ?: 0,
        )
    }

    /** Strict streak rule: yesterday's completion extends by one; any gap resets to 1. */
    suspend fun recordCompletion(dateKey: String, elapsedSeconds: Int): Completion {
        prefs.edit().putString("completed.date", dateKey).putInt("completed.seconds", elapsedSeconds).apply()
        val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return Completion(elapsedSeconds, 0, 0)
        val ref = db.collection("users").document(uid)
        val yesterday = dayBefore(dateKey)
        runCatching {
            db.runTransaction { tx ->
                val data = tx.get(ref).data ?: emptyMap<String, Any>()
                if (data["dailyLastCompletedDate"] == dateKey) return@runTransaction null
                val previous = (data["dailyStreak"] as? Number)?.toInt() ?: 0
                val longest = (data["dailyLongestStreak"] as? Number)?.toInt() ?: 0
                val newStreak = if (data["dailyLastCompletedDate"] == yesterday) previous + 1 else 1
                tx.set(ref, mapOf(
                    "dailyStreak" to newStreak,
                    "dailyLongestStreak" to maxOf(longest, newStreak),
                    "dailyLastCompletedDate" to dateKey,
                    "dailyLastSolveSeconds" to elapsedSeconds,
                ), com.google.firebase.firestore.SetOptions.merge())
                null
            }.await()
        }
        return existingCompletion(dateKey) ?: Completion(elapsedSeconds, 1, 1)
    }
}
