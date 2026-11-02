package com.celltower.cell_tower_monitor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The badge is what the status bar shows instead of a generic app icon, so each
 * carrier's house style is pinned here — and so is the rule that 5G is only
 * claimed while a 5G carrier is attached.
 */
class SignalIconTest {

    @Test
    fun `LTE only is labelled LTE`() {
        assertEquals("LTE", SignalIcon.labelFor("LTE", "NONE", "310260", nrAttached = false))
    }

    @Test
    fun `carrier aggregation reads LTE+ everywhere`() {
        assertEquals("LTE+", SignalIcon.labelFor("LTE", "LTE_CA", "310410", nrAttached = false))
        assertEquals("LTE+", SignalIcon.labelFor("LTE", "LTE_CA", "311480", nrAttached = false))
    }

    @Test
    fun `Advanced Pro reads 5GE on AT&T and FirstNet only`() {
        assertEquals(
            "5GE",
            SignalIcon.labelFor("LTE", "LTE_ADVANCED_PRO", "310410", nrAttached = false),
        )
        assertEquals(
            "5GE",
            SignalIcon.labelFor("LTE", "LTE_ADVANCED_PRO", "313100", nrAttached = false),
        )
        assertEquals(
            "LTE+",
            SignalIcon.labelFor("LTE", "LTE_ADVANCED_PRO", "310260", nrAttached = false),
        )
        assertEquals(
            "LTE+",
            SignalIcon.labelFor("LTE", "LTE_ADVANCED_PRO", "311480", nrAttached = false),
        )
        // Still an LTE-Advanced marker: an attached 5G carrier outranks it.
        assertEquals(
            "5G",
            SignalIcon.labelFor("LTE", "LTE_ADVANCED_PRO", "310410", nrAttached = true),
        )
    }

    @Test
    fun `the platform saying NSA is not enough on its own`() {
        // Samsung keeps advertising NR_NSA after the NR leg has dropped; with no
        // 5G cell attached the badge must read LTE.
        assertEquals("LTE", SignalIcon.labelFor("LTE", "NR_NSA", "310410", nrAttached = false))
        assertEquals("LTE", SignalIcon.labelFor("LTE", "NR_ADVANCED", "310410", nrAttached = false))
    }

    @Test
    fun `an attached 5G carrier reads 5G`() {
        assertEquals("5G", SignalIcon.labelFor("LTE", "NR_NSA", "310410", nrAttached = true))
        assertEquals("5G", SignalIcon.labelFor("NR", "NR_SA", "310410", nrAttached = true))
        assertEquals("5G", SignalIcon.labelFor("NR", "NONE", "310260", nrAttached = true))
    }

    @Test
    fun `NR Advanced carries the carrier's own badge`() {
        assertEquals("5G+", SignalIcon.labelFor("NR", "NR_ADVANCED", "310410", nrAttached = true))
        assertEquals("5GUC", SignalIcon.labelFor("NR", "NR_ADVANCED", "310260", nrAttached = true))
        assertEquals("5GUW", SignalIcon.labelFor("NR", "NR_ADVANCED", "311480", nrAttached = true))
        // With the dash the app displays elsewhere.
        assertEquals("5G+", SignalIcon.labelFor("NR", "NR_ADVANCED", "310-410", nrAttached = true))
    }

    @Test
    fun `FirstNet is AT&T's badge`() {
        assertEquals("5G+", SignalIcon.labelFor("NR", "NR_ADVANCED", "313100", nrAttached = true))
    }

    @Test
    fun `NR Advanced on a network with no house style stays 5G`() {
        assertEquals("5G", SignalIcon.labelFor("NR", "NR_ADVANCED", "313700", nrAttached = true))
        assertEquals("5G", SignalIcon.labelFor("NR", "NR_ADVANCED", null, nrAttached = true))
    }

    @Test
    fun `other technologies and no service have no badge`() {
        assertNull(SignalIcon.labelFor("GSM", "NONE", "310260", nrAttached = false))
        assertNull(SignalIcon.labelFor("WCDMA", "NONE", "310260", nrAttached = false))
        assertNull(SignalIcon.labelFor(null, "NONE", null, nrAttached = false))
    }
    @Test
    fun `a second carrier reads LTE+ without the platform saying CA`() {
        assertEquals(
            "LTE+",
            SignalIcon.labelFor("LTE", "NR_NSA", "313700", nrAttached = false, aggregated = true),
        )
        assertEquals(
            "LTE+",
            SignalIcon.labelFor("LTE", "NONE", "310260", nrAttached = false, aggregated = true),
        )
    }

    @Test
    fun `no second carrier and no override stays LTE`() {
        assertEquals(
            "LTE",
            SignalIcon.labelFor("LTE", "NR_NSA", "313700", nrAttached = false, aggregated = false),
        )
    }
}
