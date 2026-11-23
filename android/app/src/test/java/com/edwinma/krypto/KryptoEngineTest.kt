package com.edwinma.krypto

import org.junit.Assert.*
import org.junit.Test

class KryptoEngineTest {
    private fun f(n: Int) = Fraction.of(n)

    @Test fun deckHas56Cards() = assertEquals(56, KryptoEngine.deck.size)

    @Test fun fractionReduces() {
        assertEquals(Fraction.of(1, 2), Fraction.of(2, 4))
        assertEquals("3/2", (f(1) + Fraction.of(1, 2)).toString())
        assertNull(f(5).dividedBy(f(0)))
    }

    @Test fun solvesKnownHand() {
        val steps = KryptoEngine.solve(listOf(2, 3, 4, 5, 6).map(::f), f(24))
        assertNotNull(steps)
        assertEquals(4, steps!!.size)
        assertEquals(f(24), steps.last().result)
    }

    @Test fun dealIsAlwaysSolvable() {
        repeat(20) {
            val (hand, target) = KryptoEngine.deal()
            assertNotNull(KryptoEngine.solve(hand.map(::f), f(target)))
        }
    }

    @Test fun estimateStaysInRange() {
        val (hand, target) = KryptoEngine.deal()
        val s = KryptoEngine.estimateSolveSeconds(hand, target)
        assertTrue(s in 30..180)
    }
}
