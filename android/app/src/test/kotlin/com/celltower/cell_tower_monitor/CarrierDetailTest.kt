package com.celltower.cell_tower_monitor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The privileged reader's payload is produced on a device but parsed here, so
 * the wire format is what these tests pin down: an unreadable payload must
 * never take the app's public-API reading with it.
 */
class CarrierDetailTest {

    @Test
    fun `reads every component carrier`() {
        val detail = CarrierDetail.parse(
            """
            {"uid":2000,"carriers":[
              {"band":2,"bw":20000,"net":13,"pci":101},
              {"band":66,"bw":15000,"net":13,"pci":202},
              {"band":41,"bw":100000,"net":20,"pci":303}
            ],"qci":9}
            """.trimIndent(),
        )

        assertEquals(3, detail.carriers.size)
        assertEquals(listOf(2, 66, 41), detail.carriers.map { it.band })
        assertEquals(135000, detail.totalBandwidthKhz)
        assertEquals(9, detail.qci)
    }

    @Test
    fun `drops a carrier the modem has not measured`() {
        // PhysicalChannelConfig answers 0 kHz for a carrier it is still
        // bringing up; a `B2 0 MHz` row would be worse than no row.
        val detail = CarrierDetail.parse(
            """{"carriers":[{"band":2,"bw":0,"net":13},{"band":66,"bw":15000,"net":13}]}""",
        )

        assertEquals(1, detail.carriers.size)
        assertEquals(66, detail.carriers.single().band)
    }

    @Test
    fun `keeps an unnamed band and an unknown pci as absent`() {
        val detail = CarrierDetail.parse(
            """{"carriers":[{"band":0,"bw":10000,"net":20,"pci":null}]}""",
        )

        val carrier = detail.carriers.single()
        assertEquals(0, carrier.band)
        assertNull(carrier.pci)
    }

    @Test
    fun `an empty or broken payload reads as nothing`() {
        assertEquals(CarrierDetail.EMPTY, CarrierDetail.parse(null))
        assertEquals(CarrierDetail.EMPTY, CarrierDetail.parse(""))
        // What the user service sends when the modem refused the call.
        assertEquals(CarrierDetail.EMPTY, CarrierDetail.parse("""{"error":"no telephony service"}"""))
        assertEquals(CarrierDetail.EMPTY, CarrierDetail.parse("not json"))
    }

    @Test
    fun `qci outside the 3GPP range is not a class`() {
        assertNull(CarrierDetail.parse("""{"carriers":[],"qci":0}""").qci)
        assertNull(CarrierDetail.parse("""{"carriers":[],"qci":300}""").qci)
        assertEquals(65, CarrierDetail.parse("""{"carriers":[],"qci":65}""").qci)
    }

    @Test
    fun `maps carry the shape the snapshot hands to dart`() {
        val maps = CarrierDetail.toMaps(
            CarrierDetail.parse("""{"carriers":[{"band":41,"bw":100000,"net":20,"pci":303}],"qci":7}"""),
        )

        assertEquals(1, maps.size)
        assertEquals(41, maps.single()["band"])
        assertEquals(100000, maps.single()["bw"])
        assertEquals(20, maps.single()["net"])
        assertEquals(303, maps.single()["pci"])
    }

    @Test
    fun `an unmatched payload is empty rather than throwing`() {
        // A carrier with no width and no technology is what an older firmware
        // returns for a band it cannot place; it must not abort the rest.
        val detail = CarrierDetail.parse(
            """{"carriers":[{"band":5},{"band":5,"bw":5000,"net":13,"pci":77}]}""",
        )

        assertTrue(detail.carriers.single().bandwidthKhz > 0)
        assertEquals(5000, detail.totalBandwidthKhz)
    }
}
