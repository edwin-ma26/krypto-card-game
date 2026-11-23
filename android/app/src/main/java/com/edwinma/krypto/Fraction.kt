package com.edwinma.krypto

import kotlin.math.abs

/** Exact rational arithmetic so division never loses precision mid-game.
 *  Mirrors Krypto/Fraction.swift. */
data class Fraction(val num: Long, val den: Long) {
    companion object {
        fun of(num: Long, den: Long = 1): Fraction {
            require(den != 0L)
            val sign = if (den < 0) -1 else 1
            val g = gcd(abs(num), abs(den)).coerceAtLeast(1)
            return Fraction(sign * num / g, sign * den / g)
        }
        fun of(num: Int): Fraction = of(num.toLong(), 1)

        fun gcd(a: Long, b: Long): Long {
            var x = a; var y = b
            while (y != 0L) { val t = x % y; x = y; y = t }
            return x
        }
    }

    val isWhole: Boolean get() = den == 1L

    override fun toString(): String = if (isWhole) "$num" else "$num/$den"

    operator fun plus(r: Fraction) = of(num * r.den + r.num * den, den * r.den)
    operator fun minus(r: Fraction) = of(num * r.den - r.num * den, den * r.den)
    operator fun times(r: Fraction) = of(num * r.num, den * r.den)
    /** Null when dividing by zero. */
    fun dividedBy(r: Fraction): Fraction? = if (r.num == 0L) null else of(num * r.den, den * r.num)
}

enum class Operation(val symbol: String) {
    ADD("+"), SUBTRACT("−"), MULTIPLY("×"), DIVIDE("÷");

    fun apply(a: Fraction, b: Fraction): Fraction? = when (this) {
        ADD -> a + b
        SUBTRACT -> a - b
        MULTIPLY -> a * b
        DIVIDE -> a.dividedBy(b)
    }
}
