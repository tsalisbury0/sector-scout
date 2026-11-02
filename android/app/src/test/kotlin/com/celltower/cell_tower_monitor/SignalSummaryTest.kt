package com.celltower.cell_tower_monitor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pinned notification is drawn natively, so these are the lines the user
 * will read. The band-106 and gNB rules are checked against the same numbers
 * the app shows on screen.
 */
class SignalSummaryTest {

    private fun cell(
        type: String = "LTE",
        registered: Boolean = true,
        cellId: String? = null,
        pci: Int? = null,
        arfcn: Int? = null,
        bands: List<Int> = emptyList(),
        mcc: String? = "310",
        mnc: String? = "260",
        dbm: Int? = null,
    ) = mapOf<String, Any?>(
        "type" to type,
        "registered" to registered,
        "cellId" to cellId,
        "pci" to pci,
        "arfcn" to arfcn,
        "bands" to bands,
        "mcc" to mcc,
        "mnc" to mnc,
        "dbm" to dbm,
    )

    private fun sim(
        cells: List<Map<String, Any?>>,
        carrierName: String = "T-Mobile",
        slotIndex: Int = 0,
        isDefault: Boolean = true,
        override: String = "NONE",
        plmn: String? = null,
    ) = mapOf<String, Any?>(
        "plmn" to plmn,
        "slotIndex" to slotIndex,
        "subscriptionId" to 1,
        "carrierName" to carrierName,
        "isDefault" to isDefault,
        "simState" to "READY",
        "networkTypeName" to "LTE",
        "overrideNetworkType" to override,
        "cells" to cells,
    )

    private fun snapshot(vararg sims: Map<String, Any?>) =
        mapOf<String, Any?>("sims" to sims.toList())

    @Test
    fun `bars follow the app's scale`() {
        assertEquals(5, SignalSummary.barsFor(-84))
        assertEquals(4, SignalSummary.barsFor(-85))
        assertEquals(4, SignalSummary.barsFor(-94))
        assertEquals(3, SignalSummary.barsFor(-95))
        assertEquals(3, SignalSummary.barsFor(-104))
        assertEquals(2, SignalSummary.barsFor(-105))
        assertEquals(1, SignalSummary.barsFor(-115))
        assertEquals(0, SignalSummary.barsFor(-125))
        assertNull(SignalSummary.barsFor(null))
    }

    @Test
    fun `a band 29 carrier never becomes the cell the shade describes`() {
        // Band 29 is a supplemental downlink: no ECI, so no eNB or sector, and
        // its band and channel must not stand in for the primary cell's.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = null,
                            pci = 470,
                            arfcn = 9700,
                            bands = listOf(29),
                            mcc = "310",
                            mnc = "410",
                            dbm = -88,
                        ),
                        cell(
                            cellId = "${245029 * 256 + 12}",
                            pci = 195,
                            arfcn = 700,
                            bands = listOf(2),
                            mcc = "310",
                            mnc = "410",
                            dbm = -95,
                        ),
                    ),
                    carrierName = "AT&T",
                ),
            ),
            aliasB106 = false,
        )!!

        // The B29 underneath is a second carrier, so the badge is LTE+ — but it
        // is still the B2 that the lines describe.
        assertEquals("LTE+", lines.badge)
        assertTrue("B2", lines.text.contains("B2"))
        assertTrue("reads the primary's level", lines.text.contains("-95"))
    }

    @Test
    fun `an LTE serving cell reads as band, channel and level`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${26873 * 256 + 62}",
                            pci = 76,
                            arfcn = 68611,
                            bands = listOf(71),
                            dbm = -95,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
        )!!

        assertEquals("T-Mobile · 4G LTE", lines.title)
        assertEquals("B71 · EARFCN 68611 · -95 dBm", lines.text)
        assertTrue(lines.detail.contains("eNB 26873 · sector 62"))
        // The level is stated once; no "3 of 5 bars" wording.
        assertTrue(lines.detail.contains("-95 dBm"))
        assertTrue(!lines.detail.contains("bars"))
        assertEquals("LTE", lines.badge)
    }

    @Test
    fun `the A10e build numbers its carrier 106 in the notification too`() {
        val a10e = cell(
            cellId = "${195007 * 256 + 11}",
            pci = 61,
            arfcn = 3580,
            mcc = "313",
            mnc = "700",
            dbm = -101,
        )

        val aliased = SignalSummary.of(
            snapshot(sim(listOf(a10e), carrierName = "Ameren")),
            aliasB106 = true,
        )!!
        assertEquals("B106 · EARFCN 134322 · -101 dBm", aliased.text)

        // The normal build leaves the modem's own numbers alone; the band still
        // comes from the channel, since this modem reports no band list.
        val plain = SignalSummary.of(
            snapshot(sim(listOf(a10e), carrierName = "Ameren")),
            aliasB106 = false,
        )!!
        assertEquals("B8 · EARFCN 3580 · -101 dBm", plain.text)
    }

    @Test
    fun `a channel already on band 106's raster is left as it is`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${195007 * 256 + 11}",
                            pci = 61,
                            arfcn = 134322,
                            bands = listOf(106),
                            mcc = "313",
                            mnc = "700",
                            dbm = -101,
                        ),
                    ),
                ),
            ),
            aliasB106 = true,
        )!!
        assertEquals("B106 · EARFCN 134322 · -101 dBm", lines.text)
    }

    @Test
    fun `NSA shows the anchor and keeps the NR leg on its own line`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${245710 * 256 + 228}",
                            pci = 310,
                            arfcn = 67086,
                            bands = listOf(66),
                            mcc = "310",
                            mnc = "410",
                            dbm = -108,
                        ),
                        cell(
                            type = "NR",
                            cellId = "12590807089",
                            pci = 341,
                            arfcn = 632064,
                            bands = listOf(77),
                            mcc = "310",
                            mnc = "410",
                            dbm = -100,
                        ),
                    ),
                    carrierName = "AT&T",
                    override = "NR_NSA",
                ),
            ),
            aliasB106 = false,
        )!!

        assertEquals("AT&T · 5G NSA", lines.title)
        // The anchor is what a cell map is keyed on.
        assertEquals("B66 · EARFCN 67086 · -108 dBm", lines.text)
        assertTrue(lines.detail.contains("eNB 245710 · sector 228"))
        assertTrue(lines.detail.contains("NR n77 · ARFCN 632064 · -100 dBm"))
        assertEquals("5G", lines.badge)
    }

    @Test
    fun `standalone 5G reads as gNB and sector`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            cellId = "12590807089",
                            pci = 341,
                            arfcn = 176910,
                            bands = listOf(5),
                            mcc = "310",
                            mnc = "410",
                            dbm = -98,
                        ),
                    ),
                    carrierName = "AT&T",
                    override = "NR_SA",
                ),
            ),
            aliasB106 = false,
        )!!

        assertEquals("AT&T · 5G SA", lines.title)
        assertEquals("n5 · ARFCN 176910 · -98 dBm", lines.text)
        // AT&T splits the NCI at 26 bits: gNB 12295710, sector 49.
        assertTrue(lines.detail.contains("gNB 12295710 · sector 49"))
        assertEquals("5G", lines.badge)
    }

    @Test
    fun `a T-Mobile gNB splits at 24 bits`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            cellId = "4314132792",
                            pci = 25,
                            arfcn = 658080,
                            bands = listOf(41),
                            mcc = "310",
                            mnc = "260",
                            dbm = -90,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
        )!!
        // T-Mobile's own maps call this tower gNB 1053255, sector 312.
        assertTrue(lines.detail.contains("gNB 1053255 · sector 312"))
    }

    @Test
    fun `T-Mobile's n38 indicator reads as n41 on an n41 ARFCN`() {
        // 2606.55 MHz is NREF 521310, inside both n38’s 514000–524999 and
        // n41’s 499200–537999; T-Mobile runs n41 there and no n38.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            cellId = "4314132792",
                            pci = 25,
                            arfcn = 521310,
                            bands = listOf(38),
                            mcc = "310",
                            mnc = "260",
                            dbm = -90,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("n41 · ARFCN 521310 · -90 dBm", lines.text)
    }

    @Test
    fun `T-Mobile's n2 indicator reads as n25`() {
        // n2's whole ARFCN block sits inside n25's; T-Mobile's PCS is n25.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            cellId = "4314132792",
                            pci = 25,
                            arfcn = 390000,
                            bands = listOf(2),
                            mcc = "310",
                            mnc = "260",
                            dbm = -90,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("n25 · ARFCN 390000 · -90 dBm", lines.text)
    }

    @Test
    fun `a BAND_UNKNOWN carrier is named from its ARFCN`() {
        // The A15 reports -1 for its 631.35 MHz n71 carrier; ARFCN 126270 sits
        // in no other NR band, so the channel names it.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            cellId = "4314132792",
                            pci = 984,
                            arfcn = 126270,
                            bands = listOf(-1),
                            mcc = "310",
                            mnc = "260",
                            dbm = -95,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("n71 · ARFCN 126270 · -95 dBm", lines.text)
    }

    @Test
    fun `an n77 carrier in the CBRS block reads as n48`() {
        // 3600.00 MHz is ARFCN 640000, inside n48's 3550–3700 MHz slice of
        // n77's wider span.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            cellId = "4314132792",
                            pci = 30,
                            arfcn = 640000,
                            bands = listOf(77),
                            mcc = "310",
                            mnc = "260",
                            dbm = -88,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("n48 · ARFCN 640000 · -88 dBm", lines.text)
    }

    @Test
    fun `the band corrections can be switched off`() {
        // The Settings switch reaches the shade through Corrections: with the
        // T-Mobile rule off, the modem's own n38 is what shows.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            cellId = "4314132792",
                            pci = 25,
                            arfcn = 521310,
                            bands = listOf(38),
                            mcc = "310",
                            mnc = "260",
                            dbm = -90,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
            corrections = SignalSummary.Corrections(tmobileBands = false),
        )!!
        assertEquals("n38 · ARFCN 521310 · -90 dBm", lines.text)
    }

    @Test
    fun `an operator on the default raster still splits at 22 bits`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            type = "NR",
                            // gNB 260000 / sector 5 on the 22-bit raster.
                            cellId = "4259840005",
                            pci = 25,
                            arfcn = 658080,
                            bands = listOf(41),
                            mcc = "311",
                            mnc = "480",
                            dbm = -90,
                        ),
                    ),
                ),
            ),
            aliasB106 = false,
        )!!
        assertTrue(lines.detail.contains("gNB 260000 · sector 5"))
    }

    @Test
    fun `the platform's NSA flag alone does not make it 5G`() {
        // NR_NSA while the NR leg has dropped: the notification should say LTE
        // and carry the LTE badge, not advertise 5G on an LTE connection.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${245710 * 256 + 228}",
                            pci = 310,
                            arfcn = 67086,
                            bands = listOf(66),
                            mcc = "310",
                            mnc = "410",
                            dbm = -108,
                        ),
                    ),
                    carrierName = "AT&T",
                    override = "NR_NSA",
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("AT&T · 4G LTE", lines.title)
        assertEquals("LTE", lines.badge)
    }

    @Test
    fun `the data SIM is described when two slots are registered`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(cell(cellId = "11", pci = 1, arfcn = 6300, bands = listOf(2), dbm = -80)),
                    carrierName = "T-Mobile",
                    slotIndex = 0,
                    isDefault = false,
                ),
                sim(
                    listOf(
                        cell(
                            cellId = "22",
                            pci = 2,
                            arfcn = 67086,
                            bands = listOf(66),
                            mcc = "310",
                            mnc = "410",
                            dbm = -100,
                        ),
                    ),
                    carrierName = "AT&T",
                    slotIndex = 1,
                    isDefault = true,
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("AT&T · 4G LTE", lines.title)
        // The slot has to name the SIM the numbers came from, not the first
        // slot that happens to be registered.
        assertEquals(1, lines.slotIndex)
        assertEquals("SIM 2", lines.slotLabel)
    }

    @Test
    fun `a SIM with no served cell falls back to the first registered`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(listOf(cell(registered = false, pci = 9)), isDefault = true),
                sim(
                    listOf(
                        cell(
                            cellId = "22",
                            pci = 2,
                            arfcn = 67086,
                            bands = listOf(66),
                            mcc = "310",
                            mnc = "410",
                            dbm = -100,
                        ),
                    ),
                    carrierName = "AT&T",
                    slotIndex = 1,
                    isDefault = false,
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("AT&T · 4G LTE", lines.title)
        assertEquals("SIM 2", lines.slotLabel)
    }

    @Test
    fun `an empty snapshot has nothing to show`() {
        assertNull(SignalSummary.of(mapOf("sims" to emptyList<Any?>()), aliasB106 = false))
    }

    @Test
    fun `the network decides the brand, not the SIM card`() {
        // An MVNO card on AT&T's network: the shade should say AT&T, like the
        // app's card does.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "22",
                            pci = 2,
                            arfcn = 67086,
                            bands = listOf(66),
                            mcc = "310",
                            mnc = "410",
                            dbm = -100,
                        ),
                    ),
                    carrierName = "cricket",
                ),
            ),
            aliasB106 = false,
            brands = mapOf("310-410" to "AT&T"),
        )!!
        assertEquals("AT&T · 4G LTE", lines.title)

        // With no list loaded at all, the card's own name is all there is.
        val withoutList = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "22",
                            pci = 2,
                            arfcn = 67086,
                            bands = listOf(66),
                            mcc = "310",
                            mnc = "410",
                            dbm = -100,
                        ),
                    ),
                    carrierName = "cricket",
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("cricket · 4G LTE", withoutList.title)
    }

    @Test
    fun `the list the app loaded wins over the built-in brands`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "22",
                            pci = 2,
                            arfcn = 67086,
                            bands = listOf(66),
                            mcc = "311",
                            mnc = "970",
                            dbm = -100,
                        ),
                    ),
                    carrierName = "SIM 1",
                ),
            ),
            aliasB106 = false,
            // A brand the app resolved from the user's own JSON file.
            brands = mapOf("311-970" to "Big River Communications"),
        )!!
        assertEquals("Big River Communications · 4G LTE", lines.title)
    }

    @Test
    fun `the band is inferred when the modem omits the band list`() {
        // What the A10e reports on AT&T: a channel, no bands.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${245970 * 256 + 216}",
                            pci = 61,
                            arfcn = 5330,
                            mcc = "310",
                            mnc = "410",
                            dbm = -94,
                        ),
                    ),
                    carrierName = "(Searching)",
                ),
            ),
            aliasB106 = false,
        )!!
        // EARFCN 5330 sits on band 14's raster (5280-5379), so the row is not
        // left empty even though the modem named no band.
        assertEquals("B14 · EARFCN 5330 · -94 dBm", lines.text)
    }

    @Test
    fun `a nameless SIM is labelled by its PLMN`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${195007 * 256 + 11}",
                            pci = 61,
                            arfcn = 3580,
                            mcc = "313",
                            mnc = "700",
                            dbm = -101,
                        ),
                    ),
                    carrierName = "(Searching)",
                ),
            ),
            aliasB106 = true,
            // The list the app fetched from the user's GitHub file.
            brands = mapOf("313-700" to "Ameren"),
        )!!
        // The network's brand is used rather than the raw code.
        assertEquals("Ameren · 4G LTE", lines.title)
    }

    @Test
    fun `a network the list tags lteM reads LTE-M`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${195007 * 256 + 11}",
                            pci = 61,
                            arfcn = 3580,
                            mcc = "313",
                            mnc = "700",
                            dbm = -101,
                        ),
                    ),
                    carrierName = "(Searching)",
                ),
            ),
            aliasB106 = true,
            brands = mapOf("313-700" to "Ameren"),
            lteMs = setOf("313700"),
        )!!
        // Android reports an eMTC carrier as plain LTE, so the tag alone can
        // name it in the shade.
        assertEquals("Ameren · 4G LTE-M", lines.title)
        assertEquals("LTE-M", lines.badge)
    }

    @Test
    fun `lteM is ignored when the network is not tagged`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${195007 * 256 + 11}",
                            pci = 61,
                            arfcn = 3580,
                            mcc = "313",
                            mnc = "700",
                            dbm = -101,
                        ),
                    ),
                    carrierName = "(Searching)",
                ),
            ),
            aliasB106 = true,
            brands = mapOf("313-700" to "Ameren"),
            lteMs = setOf("310260"),
        )!!
        assertEquals("Ameren · 4G LTE", lines.title)
        assertEquals("LTE", lines.badge)
    }

    @Test
    fun `an unknown network falls back to its PLMN`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "33",
                            pci = 3,
                            arfcn = 5330,
                            bands = listOf(12),
                            mcc = "999",
                            mnc = "999",
                            dbm = -100,
                        ),
                    ),
                    carrierName = "(Searching)",
                ),
            ),
            aliasB106 = false,
        )!!
        assertEquals("999-999 · 4G LTE", lines.title)
    }

    @Test
    fun `a tagged network reads LTE-M even when the cell carries no PLMN`() {
        // The A10e's serving identity routinely arrives without mcc/mnc while
        // ServiceState still knows the network, so the tag has to resolve on the
        // SIM's network too — this is what the app's own card does.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "${195007 * 256 + 11}",
                            pci = 61,
                            arfcn = 3580,
                            mcc = null,
                            mnc = null,
                            dbm = -93,
                        ),
                    ),
                    carrierName = "Ameren",
                    plmn = "313700",
                ),
            ),
            aliasB106 = false,
            brands = mapOf("313-700" to "Ameren"),
            // The list spells it dashed, exactly as the channel delivers it.
            lteMs = setOf("313-700"),
        )!!
        assertEquals("Ameren · 4G LTE-M", lines.title)
        assertEquals("LTE-M", lines.badge)
    }

    @Test
    fun `a satellite link says SAT in the reading line`() {
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(cell(cellId = "1234", pci = 10, arfcn = 5230, dbm = -110)),
                    carrierName = "T-Satellite",
                    plmn = "310830",
                ),
            ),
            aliasB106 = false,
            brands = mapOf("310-830" to "T-Satellite"),
            satellites = setOf("310-830"),
        )!!
        assertEquals("SAT", lines.badge)
        assertTrue(lines.text.startsWith("SAT · "))
    }
    @Test
    fun `an NSA slot with no NR cell reads LTE+ while a band 29 is under it`() {
        // The platform still says NR_NSA, but the radio exposed no NR cell: the
        // 5G leg has gone. A band 29 supplemental downlink cannot exist on its
        // own, so its presence is proof the LTE side is aggregating.
        val lines = SignalSummary.of(
            snapshot(
                sim(
                    listOf(
                        cell(
                            cellId = "7771018",
                            pci = 76,
                            arfcn = 5330,
                            bands = listOf(14),
                            dbm = -99,
                        ),
                        cell(
                            registered = false,
                            arfcn = 9700,
                            bands = listOf(29),
                            dbm = -111,
                        ),
                    ),
                    override = "NR_NSA",
                    plmn = "313700",
                )
            ),
            aliasB106 = false,
        )
        assertEquals("LTE+", lines?.badge)
    }

    @Test
    fun `every downlink-only band counts as a second carrier`() {
        for (band in listOf(29, 32, 67, 69, 75, 76)) {
            val lines = SignalSummary.of(
                snapshot(
                    sim(
                        listOf(
                            cell(cellId = "7771018", arfcn = 5330, bands = listOf(14)),
                            cell(registered = false, bands = listOf(band)),
                        ),
                        override = "NONE",
                    )
                ),
                aliasB106 = false,
            )
            assertEquals("LTE+", lines?.badge)
        }
    }
}
