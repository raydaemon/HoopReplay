package com.connectedai.hoopreplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UuidV7Test {
    @Test
    fun canonicalVersion7AndTimeOrdered() {
        val ids = List(1000) { uuidV7() }
        ids.forEach { assertTrue(it, Regex("^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(it)) }
        assertEquals(ids, ids.sorted())
        assertEquals(ids.size, ids.toSet().size)
        assertEquals("0192d5f3-1a2b", uuidV7(0x0192d5f31a2bL).substring(0, 13))
    }
}
