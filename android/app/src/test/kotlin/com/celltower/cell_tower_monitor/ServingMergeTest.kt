package com.celltower.cell_tower_monitor

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Covers the two rules that keep a served cell readable across a band-lock
 * change: pairing a scan reading with a registration cell that lost its
 * identity, and holding the last channel the modem reported.
 *
 * The situations are reproduced as plain maps because they cannot be produced
 * on demand on a live handset — this A10e only drops the numbers for a while
 * after `*#2263#`, and only sometimes.
 */
class ServingMergeTest {

    private fun cell(
        type: String = "LTE",
        registered: Boolean = true,
        cellId: String? = null,
        pci: Int? = null,
        arfcn: Int? = null,
        bands: List<Int> = emptyList(),
        mcc: String? = "313",
        mnc: String? = "700",
        dbm: Int? = null,
    ) = mutableMapOf<String, Any?>(
        "type" to type,
        "registered" to registered,
        "cellId" to cellId,
        "pci" to pci,
        "arfcn" to arfcn,
        "bands" to bands,
        "mcc" to mcc,
        "mnc" to mnc,
        "dbm" to dbm,
        // Same defaults the native reader writes, so a hole is a null here too.
        "tac" to null,
        "rsrp" to null,
        "rsrq" to null,
        "sinr" to null,
        "level" to null,
        "asu" to null,
        "timingAdvance" to null,
    )

    @Before
    fun clear() = ServingMerge.forgetHeldChannels()

    @After
    fun clearAfter() = ServingMerge.forgetHeldChannels()

    // ------------------------------------------------------------------
    // Pairing a thin registration cell with the scan
    // ------------------------------------------------------------------

    @Test
    fun `a served cell with no identity borrows the only scanned cell`() {
        // What the A10e reports right after a band lock: the network and the
        // level, but no PCI, no CI and no channel.
        val serving = mutableListOf(cell(dbm = -101))
        val scanned = listOf(
            cell(cellId = "49921803", pci = 61, arfcn = 3580, dbm = -91),
        )

        val match = ServingMerge.thinMatch(serving, scanned.single(), scanned, "313700")

        assertSame(serving.single(), match)
        assertNull(serving.single()["arfcn"])
        ServingMerge.fillMissing(serving.single(), scanned.single())
        assertEquals(3580, serving.single()["arfcn"])
        assertEquals("49921803", serving.single()["cellId"])
        assertEquals(61, serving.single()["pci"])
        // Registration still wins for the level it does report.
        assertEquals(-101, serving.single()["dbm"])
    }

    @Test
    fun `a contradicting identity is not completed from another cell`() {
        // The served cell knows its CI and it is not the scanned cell's.
        val serving = mutableListOf(cell(cellId = "49921803"))
        val scanned = listOf(cell(cellId = "49921899", pci = 62, arfcn = 3580))

        assertNull(ServingMerge.thinMatch(serving, scanned.single(), scanned, "313700"))
    }

    @Test
    fun `two candidate cells are left alone`() {
        // Two registered scan cells of the same technology: picking one would
        // be a guess about which cell is served.
        val serving = mutableListOf(cell())
        val scanned = listOf(
            cell(cellId = "49921803", pci = 61, arfcn = 3580),
            cell(cellId = "49921804", pci = 62, arfcn = 3600),
        )

        assertNull(ServingMerge.thinMatch(serving, scanned.first(), scanned, "313700"))
    }

    @Test
    fun `a served cell that already has an identity is matched by it`() {
        val serving = mutableListOf(cell(cellId = "49921803", pci = 61))
        val scanned = listOf(cell(cellId = "49921803", pci = 61, arfcn = 3580))

        assertTrue(ServingMerge.hasIdentity(serving.single()))
        assertNull(ServingMerge.thinMatch(serving, scanned.single(), scanned, "313700"))
    }

    @Test
    fun `another network's scan cell does not complete this SIM's`() {
        val serving = mutableListOf(cell(mcc = "310", mnc = "260"))
        val scanned = listOf(
            cell(cellId = "11", pci = 61, arfcn = 3580, mcc = "310", mnc = "260"),
            cell(cellId = "22", pci = 62, arfcn = 6300, mcc = "313", mnc = "700"),
        )

        assertNull(ServingMerge.thinMatch(serving, scanned.last(), scanned, "313700"))
    }

    @Test
    fun `identity match survives a PLMN switch`() {
        // Served by the same physical cell, but the scan's copy still carries
        // the previous network code while holding the PCI.
        val served = cell(cellId = "49921803", mcc = "310", mnc = "410")
        val scanned = cell(cellId = "49921803", pci = 61, arfcn = 67086, mcc = "310", mnc = "260")

        assertTrue(ServingMerge.identityMatch(served, scanned))
        ServingMerge.fillMissing(served, scanned)
        assertEquals(61, served["pci"])
        assertEquals(67086, served["arfcn"])
        // The served cell keeps its own network code.
        assertEquals("410", served["mnc"])
    }

    @Test
    fun `the other slot's cell on the same PCI is not borrowed`() {
        // Different CIs, same PCI: a different network's cell.
        val served = cell(cellId = "49921803", mcc = "310", mnc = "410")
        val scanned = cell(cellId = "49921899", pci = 61, mcc = "310", mnc = "260")

        assertFalse(ServingMerge.identityMatch(served, scanned))
    }

    // ------------------------------------------------------------------
    // Holding the last channel
    // ------------------------------------------------------------------

    @Test
    fun `a channel the modem stops reporting is kept for the same cell`() {
        val first = cell(cellId = "49921803", pci = 61, arfcn = 3580)
        ServingMerge.holdLastChannel(listOf(first), now = 1_000)
        assertEquals(3580, first["arfcn"])
        assertNull(first["heldChannel"])

        // Next reading: same cell, no channel (the band-lock case), and no band
        // list either, which is what this phone reports.
        val later = cell(cellId = "49921803", pci = 61)
        ServingMerge.holdLastChannel(listOf(later), now = 2_000)
        assertEquals(3580, later["arfcn"])
        assertEquals(true, later["heldChannel"])
    }

    @Test
    fun `the band list is held too`() {
        ServingMerge.holdLastChannel(
            listOf(cell(cellId = "1", pci = 7, arfcn = 9820, bands = listOf(30))),
            now = 1_000,
        )
        val later = cell(cellId = "1", pci = 7)
        ServingMerge.holdLastChannel(listOf(later), now = 2_000)

        assertEquals(9820, later["arfcn"])
        assertEquals(listOf(30), later["bands"])
    }

    @Test
    fun `a different cell does not inherit the channel`() {
        ServingMerge.holdLastChannel(
            listOf(cell(cellId = "49921803", pci = 61, arfcn = 3580)),
            now = 1_000,
        )
        // Different CI and PCI: after a band lock onto another band.
        val other = cell(cellId = "49921899", pci = 62)
        ServingMerge.holdLastChannel(listOf(other), now = 2_000)

        assertNull(other["arfcn"])
        assertNull(other["heldChannel"])
    }

    @Test
    fun `a fresh channel replaces what was held`() {
        ServingMerge.holdLastChannel(
            listOf(cell(cellId = "1", pci = 7, arfcn = 3580)),
            now = 1_000,
        )
        val moved = cell(cellId = "1", pci = 7, arfcn = 3600)
        ServingMerge.holdLastChannel(listOf(moved), now = 2_000)
        assertEquals(3600, moved["arfcn"])

        val blank = cell(cellId = "1", pci = 7)
        ServingMerge.holdLastChannel(listOf(blank), now = 3_000)
        assertEquals(3600, blank["arfcn"])
    }

    @Test
    fun `a hold older than fifteen minutes is dropped`() {
        ServingMerge.holdLastChannel(
            listOf(cell(cellId = "1", pci = 7, arfcn = 3580)),
            now = 0,
        )
        val later = cell(cellId = "1", pci = 7)
        ServingMerge.holdLastChannel(listOf(later), now = 16 * 60 * 1000L)

        assertNull(later["arfcn"])
        assertFalse(later.containsKey("heldChannel") && later["heldChannel"] == true)
    }

    @Test
    fun `a PCI the modem stops reporting is restored for that cell`() {
        // Switching PLMNs can leave the served cell without a PCI for a few
        // seconds; the CI is the same cell, and a PCI is fixed for a CI.
        ServingMerge.holdLastChannel(
            listOf(cell(cellId = "49921803", pci = 61, arfcn = 3580)),
            now = 1_000,
        )
        val later = cell(cellId = "49921803", mcc = "310", mnc = "410")
        ServingMerge.holdLastChannel(listOf(later), now = 2_000)
        assertEquals(61, later["pci"])
    }

    @Test
    fun `a restored PCI does not leak to another cell`() {
        ServingMerge.holdLastChannel(
            listOf(cell(cellId = "49921803", pci = 61)),
            now = 1_000,
        )
        val other = cell(cellId = "49921899")
        ServingMerge.holdLastChannel(listOf(other), now = 2_000)
        assertNull(other["pci"])
    }

    @Test
    fun `a cell with no identity is not filed`() {
        // Nothing to file it under, so it never inherits another cell's number.
        val anonymous = cell()
        ServingMerge.holdLastChannel(listOf(anonymous), now = 1_000)
        assertNull(anonymous["arfcn"])
    }
}
