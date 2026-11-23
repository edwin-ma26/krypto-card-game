package com.edwinma.krypto

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

data class Card(val id: String = UUID.randomUUID().toString(), val value: Fraction, val colorIndex: Int)

/** Board state and the tap-card / tap-op / tap-card combine loop, ported from
 *  Krypto/GameViewModel.swift (solo and daily paths only; no multiplayer). */
class GameViewModel : ViewModel() {
    val cards = mutableStateListOf<Card>()
    var target by mutableStateOf(Fraction.of(0)); private set
    var selectedCardId by mutableStateOf<String?>(null); private set
    var selectedOp by mutableStateOf<Operation?>(null); private set
    var elapsed by mutableStateOf(0); private set
    var isSolved by mutableStateOf(false); private set
    var hint by mutableStateOf<String?>(null); private set
    val steps = mutableStateListOf<String>()

    private val history = ArrayDeque<List<Card>>()
    private var timer: Job? = null
    private var startMillis = 0L
    var onSolved: ((elapsedSeconds: Int) -> Unit)? = null

    val canUndo: Boolean get() = history.isNotEmpty()
    val timeString: String get() = "%d:%02d".format(elapsed / 60, elapsed % 60)

    fun startShared(hand: List<Int>, targetValue: Int, resumeElapsed: Int = 0) {
        cards.clear()
        // Colours are shuffled per deal, like iOS, so the same slot isn't always sand.
        val colors = (0 until 5).shuffled()
        cards.addAll(hand.mapIndexed { i, v -> Card(value = Fraction.of(v), colorIndex = colors[i % colors.size]) })
        target = Fraction.of(targetValue)
        steps.clear(); history.clear()
        selectedCardId = null; selectedOp = null; hint = null
        isSolved = false
        elapsed = resumeElapsed
        startMillis = System.currentTimeMillis() - resumeElapsed * 1000L
        timer?.cancel()
        timer = viewModelScope.launch {
            while (true) {
                delay(250)
                elapsed = ((System.currentTimeMillis() - startMillis) / 1000).toInt()
            }
        }
    }

    fun tapCard(card: Card) {
        hint = null
        if (isSolved) return
        if (selectedCardId == card.id) {
            selectedCardId = null; selectedOp = null
            return
        }
        val firstId = selectedCardId
        val op = selectedOp
        val firstIndex = cards.indexOfFirst { it.id == firstId }
        val secondIndex = cards.indexOfFirst { it.id == card.id }
        if (firstId == null || op == null || firstIndex < 0 || secondIndex < 0) {
            selectedCardId = card.id
            return
        }
        // Division by zero: keep the op, just bounce the selection.
        val result = op.apply(cards[firstIndex].value, cards[secondIndex].value) ?: return
        history.addLast(cards.toList())
        steps.add("${cards[firstIndex].value} ${op.symbol} ${cards[secondIndex].value} = $result")
        val resultCard = cards[secondIndex].copy(value = result)
        cards[secondIndex] = resultCard
        cards.removeAt(firstIndex)
        // Keep the result selected so the next operation chains off it.
        selectedCardId = if (cards.size > 1) resultCard.id else null
        selectedOp = null
        checkWin()
    }

    fun tapOperation(op: Operation) {
        hint = null
        if (isSolved || selectedCardId == null) return
        selectedOp = if (selectedOp == op) null else op
    }

    fun undo() {
        val previous = history.removeLastOrNull() ?: return
        if (steps.isNotEmpty()) steps.removeAt(steps.lastIndex)
        cards.clear(); cards.addAll(previous)
        selectedCardId = null; selectedOp = null; hint = null
        isSolved = false
    }

    fun showHint() {
        if (isSolved) return
        val first = KryptoEngine.solve(cards.map { it.value }, target)?.firstOrNull()
        hint = if (first != null) "Try ${first.a} ${first.op.symbol} ${first.b} = ${first.result}"
        else "No solution from here — undo a step"
    }

    private fun checkWin() {
        if (cards.size != 1 || cards[0].value != target) return
        elapsed = ((System.currentTimeMillis() - startMillis) / 1000).toInt()
        timer?.cancel()
        isSolved = true
        onSolved?.invoke(elapsed)
    }

    override fun onCleared() { timer?.cancel() }
}
