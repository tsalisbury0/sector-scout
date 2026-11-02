# Sector Scout

Android app (Flutter) that shows what the modem currently sees: every SIM's
serving cell, its signal strength with a bar meter, and the neighbour cells the
radio is hearing.

## Signal bars

Both LTE and NR use the same dBm scale (5 bars = best):

| Bars | RSRP / dBm |
| --- | --- |
| 5 | -84 and above |
| 4 | -94 to -85 |
| 3 | -104 to -95 |
| 2 | -114 to -105 |
| 1 | -124 to -115 |
| 0 | below -125 |

If the modem gives no dBm, the platform's own 0-4 level is used as a fallback.

## Dual SIM, NSA and SA

- **Every active SIM is read separately.** Each slot gets its own card on its
  own **page** — swipe left and right to move between SIMs, with a dot
  indicator at the bottom. The serving cell + signal level come from that
  subscription's own `ServiceState` / `NetworkRegistrationInfo` (identity,
  band, TAC) plus `TelephonyManager.getSignalStrength()` (level,
  RSRP/RSRQ/SINR) — the same per-subscription APIs CellMapper and SignalCheck
  use. `getAllCellInfo()` is not trusted for serving cells because many DSDS
  devices (Samsung/Qualcomm) return one shared list for every subscription.
  The slot badge only appears when more than one SIM is active.
- **A registered cell from the shared scan is only adopted when its PLMN is
  this subscription's own.** Without that check the modem-wide list leaks the
  other slot's cell into a SIM (T-Mobile's page showing cricket's eNB, and vice
  versa) as soon as one slot has no WWAN registration of its own — for example
  while it is on Wi-Fi calling. Each payload now also carries the subscription's
  own `plmn`.
- **NSA** (5G carried under an LTE anchor) shows **two meters**: `LTE ANCHOR`
  and `5G NR`, each with its own bars and dBm.
- **SA** (5G on its own, no LTE registered) uses the **single meter**, the same
  one LTE uses.
- Mode is derived from the platform's `TelephonyDisplayInfo.overrideNetworkType`
  (the value behind the status-bar 5G / 5G+ icon) combined with the registered
  legs: NR + LTE = NSA, NR alone = SA. Firmwares that mark the NR leg
  `unregistered` in `getAllCellInfo()` (Samsung does) still get their NR cell
  adopted when the platform reports 5G as active, so the second meter appears.
- If a radio exposes no NR cell at all, the chip still says `5G NSA`/`5G SA`
  but only the single LTE meter can be drawn.

## Cell identity and AT&T sectors

For LTE the raw 28-bit E-UTRAN Cell Identity is not shown; it is split per the
3GPP layout and displayed in decimal:

- **eNB** = `CI >> 8` (top 20 bits)
- **Sector** = `CI & 0xFF` (bottom 8 bits, cell within the eNB)

For NR the identity is the 36-bit NCI, split the same way and shown in decimal:

- **gNB** = `NCI >> (36 - gNB bits)`
- **Sector** = the remaining low bits (cell within the gNB)

3GPP lets each operator choose the gNB ID length, so the split needs the PLMN:
**AT&T (310-410, 310-150, 310-170, 310-380, 313-100) runs a 26-bit gNB and a
10-bit sector.** Their gNB 12295710 / sector 49 is NCI 12590807089; splitting
that NCI at 24 bits instead gives the wrong tower (3073927) and sector (2097).
**T-Mobile (310-260, and T-911 on 312-190) runs a 24-bit gNB and a 12-bit
sector.** gNB 1053255 / sector 312 is NCI 4314132792; the 22-bit default reads
that same NCI as 263313 / 12600, a tower that does not exist on their maps.
Everyone else (Verizon, FirstNet's NR, ...) assumes the 22-bit default. The
NCI stays visible as hex.

Neighbour rows use the same split: a neighbour with an identity reads
**`eNB 195007`** or **`gNB 1053255`**, never an opaque `Cell <NCI>`. The raw
identity is only the fallback for a technology whose split is unknown.

The NR **band** is read from the modem's own band list, not guessed from the
ARFCN, with two corrections for T-Mobile. NR's band is derived by the modem
rather than signalled, and in each pair below the reported band sits entirely
inside a wider one, spectrum and ARFCN range alike:

- **n38 → n41.** n38 is 2570–2620 MHz (514000–524999), n41 is 2496–2690
  (499200–537999). T-Mobile runs n41 across the block and no n38 at all.
- **n2 → n25.** n2 is 1930–1990 MHz (386000–398999), n25 is 1930–1995
  (386000–399999). T-Mobile's PCS carrier is n25.

So a T-Mobile carrier in either shared window comes back as the narrow band and
is shown corrected: `Band n41 (modem: n38)`, `Band n25 (modem: n2)` — never a
silent substitution. Other operators keep the reported band, so a European n38
or another carrier's n2 still reads as reported. The ARFCN and frequency rows
are unaffected in either case, and the same correction is applied to the pinned
notification.

Some firmwares report **-1** for the band instead of naming it (the A15 does on
its 631.35 MHz n71 carrier). That value is `BAND_UNKNOWN`, not a band, and is
dropped rather than printed as `n-1`. With no band from the radio the app falls
back to the channel: on the NR raster that answer is only used when exactly one
band owns the ARFCN (126270 belongs to n71 alone), because several NR bands
share channels by design — an ambiguous channel stays unnamed instead of
guessing.

Sectors are shown as **numbers only**, on both RATs — the Alpha/Beta/Gamma
operator naming was removed, so a cell reads `Sector (dec) 49` and nothing more.
AT&T eNBs beginning 240/241/242/243/246/248/249 are small cells/DAS whose low
byte is not a macro sector; that range is also excluded from the NSA gNB
estimate.

**LTE band 29 reads as a secondary, because that is all it can be.** The
700 MHz block is a supplemental downlink: downlink only (no uplink anywhere in
the band) and only ever deployed as a second LTE carrier under a primary. The
radio reports it with a PCI, a band and a channel but no cell identity, so
there is no eNB and no sector to decode. A B29 carrier is therefore shown under
**4G LTE secondary** with the eNB, sector and TAC rows left out entirely — not
blanked, since an SDL has no site or tracking area of its own — plus a single
downlink frequency, rather than sitting in the neighbour list. An SDL only shows
up once it is aggregated, which is the same thing CellMapper draws as attached
with no eNB or sector. It is never treated as the slot's anchor: the page, the
header meter and the pinned notification all keep the primary LTE cell.

The carrier's **MCC/MNC only come through while it is actually carrying data**, so
the PLMN row falls back to the PLMN the main carrier is registered on and says
so (`310-410 (from primary cell)`). That is the anchor's PLMN rather than the
card's: on an MVNO SIM the card can read `310-150` (cricket) while the cell the
phone is attached to belongs to `310-410` (AT&T), and the cell is what the row
describes. Everything else the modem does report — PCI, band, downlink frequency
— is shown as read: on a live S25 the carrier came back as 719.5 MHz, PCI 386,
EARFCN 9685, and nothing else.

The NR carrier is identified from the NR-ARFCN and shown as its own row; that
is a frequency label, not a sector name. Inside the 3.3–4.2 GHz block it follows
the deployment, not the 3GPP band number:

| Frequency | Label |
|---|---|
| 3300–3550 MHz | `n77 DoD` |
| 3550–3700 MHz | `n48 CBRS` |
| 3700–4200 MHz | `n77 C-Band` |

n77 spans the whole block and therefore *contains* CBRS, so a modem reporting
**n77** for a carrier at, say, 3600 MHz is right about the band and wrong about
the deployment. The frequency decides: the band row reads **n48** for any n77
carrier between 3550 and 3700 MHz, and an n48 carrier keeps its own number
anywhere. This correction is not operator-specific — CBRS is CBRS whoever runs
it. The DoD and C-Band ends of the block stay n77.

Some firmwares (Samsung's, for one) hand apps **no** NR identity while NSA is
up: `getAllCellInfo()` contains no `CellIdentityNr`, so there is no NCI to
split. For an AT&T macro anchor the app then derives an estimate —
`gNB = eNB + 12,050,000`, the offset between the pair that pinned the mapping
down (eNB 245029 → gNB 12295029), labelled **gNB (est.)**. No sector is derived
for the NSA leg: the NCI is what carries the cell-within-gNB number, so without
it there is nothing to split, and copying the anchor's sector would be a guess.
Those rows appear only when the radio reports the NCI. The estimate is only made
when the real NCI is missing and the PLMN is AT&T; for every other operator or
the small-cell/DAS eNB ranges the gNB stays blank rather than guessing.

The offset is a single constant, `CellSnapshot.attGnbOffset` in
`lib/models/cell_snapshot.dart`. It was taken from one AT&T market; if you use
the app elsewhere and know a real eNB → gNB pair nearby, recompute it as
`gNB - eNB` and the estimate follows. Because it is a subtraction away from the
anchor, the estimate is only as good as that pairing — treat the `est.` rows as
a hint, not a measurement.


The same radios also expose the NR leg intermittently — Samsung only hands it
to apps while NR is carrying data — so the NR card can come and go while the
platform still reports 5G as active. When that happens the app says so under
the anchor card instead of silently dropping the second meter.

## Carrier names

Names come from the **PLMN the SIM is actually registered on**, not from the
SIM's own service-provider string — that string is often an MVNO, a roaming
partner, or blank.
The list lives in the user's own repo, [`tsalisbury0/private_plmn`](https://github.com/tsalisbury0/private_plmn):

```
https://raw.githubusercontent.com/tsalisbury0/private_plmn/main/plmns.json
```

**There is no list compiled into the app.** If the file has never been fetched,
the cards and the notification show the SIM's own name. `plmns.json` in this
repo is the starter file to push there; the current contents are:

| PLMN | Name |
|---|---|
| 310-260 | T-Mobile |
| 310-410 | AT&T |
| 311-480 | Verizon |
| 311-970 | Big River |
| 313-100 | FirstNet |
| 313-700 | Ameren |
| 310-830 | T-Satellite |
| 312-190 | T-911 |

- Lookup key is the serving cell's `MCC-MNC`, so a Cricket SIM on AT&T's network
  reads **AT&T** in the app and in the pinned notification.
- File names tried, in order: `main/plmns.json`, `main/carriers.json`,
  `master/plmns.json`. Renaming the file to any of those needs no rebuild. To
  use a different path, bake it in:

  ```bash
  flutter build apk --release \
    --dart-define=CARRIER_NAMES_URL=https://raw.githubusercontent.com/<you>/<repo>/main/<file>.json
  ```  Both shapes parse: a list of `{"mcc":"310","mnc":"410","brand":"AT&T"}`
  objects, or a flat `{"310-410": "AT&T"}` map. `brand`, `operator` or `name`
  all work as the value field. `mcc`/`mnc` may be 2- or 3-digit; both widths are
  indexed, and the first entry for a PLMN wins.
- **Bars offsets live in the same file.** A value may be an object with an
  explicit `boost` in dB, and/or `satellite: true`, which marks the link as a
  satellite path (the card shows `SAT`) and implies the default 20 dB:

  ```json
  {
    "310-260": "T-Mobile",
    "310-830": { "brand": "T-Satellite", "satellite": true },
    "312-190": { "brand": "T-911", "boost": 20 },
    "313-700": { "brand": "Ameren", "boost": 15, "lteM": true }
  }
  ```

  `boost` and `satellite` are separate: a boost on its own only lifts the bar
  count, so a terrestrial network can tune its scale (313-700 asks for 15 dB)
  without being labelled `SAT`.

  **`lteM: true` tags a network as LTE-M / eMTC.** Write it on the PLMN that
  runs the eMTC carrier — either shape works, `"lteM"`, `"lte_m"` or `"ltem"`:

  ```json
  [
    { "mcc": "313", "mnc": "700", "brand": "Ameren", "boost": 15, "lteM": true }
  ]
  ```

  The header then reads **LTE-M** next to the carrier name instead of `LTE`, the
  mode chip reads `4G LTE-M`, and the pinned notification's badge does too. The
  tag is the only way to know: Android has no LTE-M network type, and an eMTC
  carrier reports as plain `LTE` with no mode on `CellIdentityLte`, so nothing
  in the modem data distinguishes it. An NSA slot still reads `5G` — the 5G leg
  is what is serving the data there, whatever the anchor's tag says.

  A satellite link is ~20 dB weaker than a terrestrial one at the same usable
  quality, so the level is raised by the boost **for the bar count only** — the
  dBm readout stays the raw figure the modem reported. With 20 dB this is the
  satellite bar scale:

  | Level | Bars |
  |---|---|
  | above -104 | 5 |
  | -114 .. -105 | 4 |
  | -124 .. -115 | 3 |
  | -134 .. -125 | 2 |
  | -144 .. -135 | 1 |  The offsets are cached beside the names (`CarrierBrands.kt`), so a phone that
  starts with no network still counts them the same way.
- **The two SpaceX direct-to-cell PLMNs are already known**: `310-830`
  (T-Satellite) and `312-190` (T-911) count on the satellite scale without any
  flag in the file, because that is a fact about the network rather than a
  name. An entry in the file with its own `boost` overrides the default, so
  tuning them stays a JSON edit. (`SignalQuality.satelliteBoostDefaults`.)
- A failed fetch (offline, captive portal, 404 on an empty repo) keeps the copy
  already stored on the device, so names do not disappear.
- The notification runs natively and stays up with the app closed, so it keeps
  its own copy: the app hands the list it loaded over the channel, and
  `CarrierBrands.kt` stores it in `SharedPreferences`. It has no built-in table
  either — before the first fetch it falls back to the SIM's name.
- **The `satellite` and `lteM` tags are cached too**, next to the names and the
  offsets, so the shade still marks `SAT` and **LTE-M** after a restart with no
  network. (Previously only the offsets survived; the flags had to be fetched
  again or re-pushed by the app.)

## Downlink and uplink frequencies

Every cell — serving and neighbour — carries its downlink and uplink centre
frequency, derived from the channel number:

Every band in 3GPP's tables is priced — 69 LTE bands (1–88, 103, 106) and 59 NR
bands (n1–n263), from `bands.json` rather than a hand-written list.

- **NR** uses the global NR-ARFCN raster (`F = 3000 + (N - 600000) × 0.015 MHz`
  above 3 GHz, `N × 0.005` below). The uplink is the downlink shifted by the
  band's duplex spacing (n5 −45, n66 −400, n71 +46…), clamped to the uplink
  block, and TDD carriers such as n41/n77 report the same frequency for both
  directions.
- **LTE** uses the band's EARFCN raster. Downlink = band low edge + 0.1 MHz ×
  (EARFCN − band start); the uplink uses the same offset from its own low edge,
  which handles reverse-duplex bands (13, 14, 17, 71) for free. Bands 66 and 70
  pair a narrower uplink than downlink, so the uplink is clamped to its block
  (the top of B66 has no uplink above 1780.00 MHz). Band 29 is downlink-only, so
  it shows no uplink.

`bands.json` is generated by `tool/gen_bands.py` from the 3GPP transcriptions in
`tool/banddata` (TS 36.101 Table 5.7.3-1 and TS 38.104 Table 5.2-1/2, via
[hoon/arfcn](https://github.com/hoon/arfcn), MIT). The same generator writes
`lib/models/band_tables.dart`, and the desktop reads `bands.json` directly — one
source, so the test source cannot dial a band the app has no entry for.

**TDD is one number, not two.** When both directions share a carrier (LTE bands
38/40/41/46/48, NR n41/n77/n78/n79, mmWave) the card shows a single
**Downlink/Uplink** row instead of printing the same value twice, and neighbour
rows use `↓↑`. FDD cells keep the separate pair.

**The band is worked out from the EARFCN when the modem omits it.** Some Samsung
builds — the A10e on Android 11, for one — return a valid EARFCN with an empty
band list (`"bands": []`). Since 3GPP gives every LTE band its own EARFCN range
on the shared 0.1 MHz raster, the band (and therefore both frequencies) can
still be derived; the app does that instead of hiding the rows. A band the modem
did report always wins over the raster.

A channel outside every band, or cells where Android withholds the ARFCN (most
neighbours on Android 12+), show no frequency instead of a guess.

The NR raster is global and its bands overlap by design, so a channel alone often
fits two of them (n2 in n25, n38 in n41, n5 in n26, n71 in n105). The app names a
band only when the answer is unique, and it gives the bands it resolved before
the table was complete priority — that is what keeps the A15's 631.35 MHz carrier
reading **n71** now that n105 covers the same MHz. The band-specific corrections
(T-Mobile's n38→n41 and n2→n25, the n77/n48 frequency split, the B106 alias) run
before and after this lookup, so none of them depend on which band the table
happens to name. The
A10e build reports PLMN **313-700** as **B106** with its own EARFCN and uplink
(see [Running it](#running-it)), so that build shows 134322 / 899.0 MHz where
the normal build shows 3580 / 893.0.

## What it shows

- **Serving cell** per SIM: eNB/sector (LTE) or gNB/sector (NR), TAC/LAC, PCI/PSC/BSIC,
  band, ARFCN, downlink/uplink frequency, PLMN (MCC-MNC), and a rough distance
  estimate from LTE timing advance.
- **Radio quality**: RSRP, RSRQ, SINR, ASU where the modem exposes them.
- **Neighbour cells** per SIM with band, PCI, strength (strongest first) and the
  same downlink/uplink pair (one `↓↑` value on TDD) when the channel number is
  available.
- **Empty states are dismissible**: the “No SIM card in this slot” / “no cells
  reported” warning has a **×**; it comes back by itself if the slot recovers
  and then drops out again.
- **One page per SIM**, swiped left and right, with a dot indicator.
- **Live updates**: the native layer pushes a snapshot on every modem callback
  (debounced 400 ms) with a 2.5 s poll as backup, plus pull-to-refresh.

## Running it

```bash
cd D:/cell_tower_monitor
flutter pub get
flutter run                 # on a connected device
flutter build apk --debug   # build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release # optional, faster for daily use
```

Over Wi-Fi ADB: `adb connect <phone-ip>:5555`, then `flutter run -d <serial>`.

**The A10e build.** One `--dart-define` re-codes PLMN **313-700** as **B106**,
the 900 MHz LMR/utility band (3GPP: 935–940 MHz down, 896–901 MHz up, 39 MHz
duplex, EARFCN 134292–134341). That modem reports the carrier on band 8's
raster, so the A10e build re-expresses the channel number too: EARFCN 3580
(938.0 MHz on band 8) is shown as **134322**, with **938.00 down / 899.00 up**
where the normal build says 893.00.

The re-code is keyed to the network, not to the band number, so it survives a
modem that reports neither a band nor a channel. Every other network keeps its
3GPP labels, and any other band this network runs is shown as itself.

**The serving cell keeps the channel the scan knows about.** `ServiceState` is
authoritative for *which* cell each SIM is camped on, but this A10e strips the
channel out of it — after a `*#2263#` band-lock change the registration copy
reports `mEarfcn=2147483647` with `mBands=[]` while `CellInfoLte` still carries
`3580`. The app therefore merges the scan's copy into the served cell (matched
by PCI) instead of discarding it, so band 106, ARFCN 134322 and 938.00/899.00
keep rendering even while the SIM is out of service. Anything the registration
copy does report still wins.

That pairing has a fallback for the same band-lock change: registration can also
come back without PCI and CI, and then nothing can be matched by identity. When
exactly one served cell of a technology is that thin and the scan knows exactly
one registered cell of it on this network, the two are treated as one cell — but
only when nothing they both know contradicts. The rules live in
`ServingMerge.kt` with JVM unit tests (`./gradlew :app:testDebugUnitTest`).

When neither source reports a channel, the app holds the last one that cell
reported for up to 15 minutes rather than blanking the ARFCN and frequency rows,
and marks the number as **(last known)**. The hold is filed per cell (technology
+ PLMN + CI, or PCI), so a different cell, a different network, or a genuine
channel change starts fresh instead of inheriting the old value. Everything else
is identical:

```bash
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk \
  build/app/outputs/flutter-apk/cell-tower-monitor.apk
```

**There is one APK.** The B106 re-code used to be a `--dart-define` build, which
meant an A10e had to be sideloaded with a different file from every other
phone and lost the numbering when it was replaced with the standard one. It is
the **Anterix B106** switch on the Settings page now: any phone can run either
numbering, the choice survives a reinstall, and only that network's carrier is
affected.

## Settings

The **tune** icon in the app bar opens Settings, which holds the display
corrections and the pinned notification together:

| Switch | Effect |
|---|---|
| T-Mobile band corrections | n38 reads n41 and n2 reads n25 on 310-260 / 312-190 |
| CBRS as n48 | a 3550–3700 MHz carrier named n77 reads n48 |
| Anterix B106 | reads the 313-700 carrier as B106 instead of the band 8 the modem reports |
| Pinned notification | the shade card, same switch as the one on a SIM page |

**Turning a correction on asks first.** Every one of these is a North American
deployment — T-Mobile's n41/n25, US CBRS, Anterix's B106 — and those bands are
real elsewhere, so a corrected label outside North America would name the wrong
band. The dialog says so and needs an explicit **Turn on**; turning a switch off
is immediate, since that is always the conservative direction.

Turning a correction off shows what the modem actually reported, so the app can
be checked against another tool without the corrections in the way. The raw
ARFCN, frequencies and identity rows are never altered by these switches.

The flags are stored in Android's own preferences (`sector_scout_settings`)
rather than in Dart state: `SignalStatusService` draws the shade with no Flutter
engine and reads the same file on every tick, so the notification and the app
agree without either having to wake the other. Defaults are on.

## Pinned notification

The **Pinned notification** switch at the bottom of a SIM page keeps the served
cell in the notification shade: band, channel and level on one line, eNB/gNB,
sector and band when expanded, with the 5G leg of an NSA pair on its own line.
It is drawn by `SignalStatusService`, a foreground service that reads
`CellSnapshot` itself, so it keeps updating with the app closed — and the app
screen is not needed to keep it alive.

**The icon is the technology**, drawn as a text badge because Android gives the
status bar one silhouette:

| Network | Badge |
|---|---|
| LTE only | `LTE` |
| LTE on a PLMN tagged `lteM` | `LTE-M` |
| LTE with a second carrier — CA, or any supplemental downlink | `LTE+` |
| LTE Advanced Pro, any network but AT&T | `LTE+` |
| LTE Advanced Pro on AT&T / FirstNet | `5GE` |
| 5G NSA or SA | `5G` |
| NR Advanced on AT&T / FirstNet | `5G+` |
| NR Advanced on T-Mobile | `5GUC` |
| NR Advanced on Verizon | `5GUW` |

`LTE+` means the LTE side is aggregating, and it is read from the radio as well
as from `TelephonyDisplayInfo.overrideNetworkType` (`LTE_CA`,
`LTE_ADVANCED_PRO` — `CellInfo` itself carries no "LTE-Advanced" flag). A second
registered LTE cell is aggregation, and so is **any supplemental downlink** —
bands 29, 32, 67, 69, 75 and 76 have no uplink at all, so a radio only reports
one while it is carrying it under a primary. That second rule is what makes an
NSA slot whose 5G leg has quietly gone read `LTE+` while a B29 is still under
the anchor, even though the platform keeps saying `NR_NSA`.

`5GE` is AT&T's own name for Advanced Pro, so it is used only on the AT&T and
FirstNet PLMNs; every other network reads `LTE+`. Neither is a 5G claim: both are
still LTE radio, which is why the header draws them in the same muted ink as
`LTE` and not in the accent green.

NR Advanced on a network without a house style stays `5G`, and 2G/3G keep the
bars icon. The badge is generated as a bitmap (`SignalIcon.kt`) — white bold
text, shrunk to fit `5GUW` — and cached per label.

**`5G` means a 5G carrier is actually there**, not that the platform says so. A
badge is only 5G (or a carrier's variant) when the data SIM has an NR cell
registered — an SA cell, or the secondary leg of an NSA pair. With no NR cell on
that SIM it is `LTE`, full stop. This matters because Samsung keeps reporting
`overrideNetworkType = NR_NSA` for a while after the NR leg has gone, so
trusting the override alone advertised 5G on an LTE-only connection. The
override is now used for one thing only: choosing *which* 5G badge to draw once
an NR cell is confirmed.

Observed on the S25 in one sitting: with traffic flowing on n77 (NR Advanced) the
badge read `5G+`; after an airplane-mode cycle it re-attached on n5 and read
`5G`; the NR leg then dropped on its own after ~60 s idle and the badge went to
`LTE` — while Samsung's own shade tile still claimed "LTE (AT&T B30) + 5G n77"and its status bar still showed `5G+`. The title follows the same rule, so
`AT&T · 4G LTE` and the `LTE` badge always appear together.

**In the app** the same badge sits to the right of the carrier name, with the
slot (SIM 1/2) after it, and the separate `4G LTE` / `5G NSA` / `5G SA` chip
stays on the far right of the card. The two are deliberately independent: the
badge follows the radio that is serving, the chip follows the platform's mode
and only turns green while an NR carrier is attached. An NSA slot with its 5G
leg gone therefore reads `LTE` + `5G NSA` in grey.

**A satellite link shows `SAT` instead**, in the badge's slot — never both. The
badge names the radio, `SAT` names the path, so one takes the other's place
rather than sitting beside it next to the same name. It is plain text like the
badge, in the palette's blue (`AppColors.satellite`), and it appears for any
PLMN the operator list flags `satellite: true`, plus the built-in
`310-830` and `312-190`. A `boost` on its own does not qualify — that only
lifts the bar count. The chip is unaffected: a satellite LTE cell still
reads `4G LTE` on the right.

One rendering note: Samsung's One UI draws its own app icon in the small-icon
slot of a foreground-service notification, so from Android 13 the same badge is
also set as the **large icon**, where it renders as drawn. On Android 11 (the
A10e) the small icon renders faithfully and the large one is left off, so the
badge appears once.

It is `setOngoing(true)` with no dismiss action, so it cannot be swiped away;
the shade does not offer a Clear for it, and the switch survives the app being
restarted. Nothing in an app can go further than that: **a force-stop, or the
Stop button in Android 13+'s *Active apps* panel, ends it** — those are the OS's
escape hatches for foreground services, not something code can opt out of.

How it works, since the OS has rules here:

- Declared `android:foregroundServiceType="specialUse"`, with
  `FOREGROUND_SERVICE_SPECIAL_USE`. `dataSync` would have been the wrong label
  and is capped at 6 hours a day on Android 15+; `specialUse` has no runtime
  limit for a sideloaded app.
- Android 13+ asks for `POST_NOTIFICATIONS` on the first switch-on. Denying it
  leaves the switch off and says so in a snackbar.
- The slot it describes is chosen natively: the default data subscription when
  it has a served cell, else the first SIM with one. Its label (`SIM 2`) comes
  from the same choice as the numbers, so the two cannot disagree.
- The A10e build passes its band-106 flag through the channel, so the
  notification says **B106 / 134322** like the app instead of contradicting it.
  It also infers the band from the channel when the modem reports no band list,
  which this A10e does constantly — `B14 · EARFCN 5330` rather than a bare
  channel number.
- The switch state is committed with `commit()`, not `apply()`: an app update
  kills the process moments after the write, and an async save can lose it.
- Updates every 2.5 s, the same cadence `CellMonitor` polls the radio at, so the
  shade is never more than one app refresh behind the screen. Low-importance
  channel, no sound or vibration. When the modem has no served cell the pinned
  line says so rather than disappearing.

### Staying fresh in the background

A foreground service survives the task being swiped away, but Doze and OEM
battery managers still **freeze a backgrounded app**, which is what left the
shade showing a reading from minutes earlier. Two things address it:

- The app asks for the **battery-optimisation exemption**
  (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`). While it is missing, a card under the
  notification switch explains it and offers **Allow**, which opens the system
  prompt; the state is re-read whenever the app comes back to the front, so the
  card disappears as soon as the exemption is granted.
- The service listens for `ACTION_SCREEN_ON` / `ACTION_USER_PRESENT` and
  refreshes immediately, so picking the phone up repaints the shade instead of
  waiting for the next 2.5 s tick. (Deep sleep suspends the tick — that is the
  CPU, not the service.)

## Sharing with another phone

Tap the share icon in the app bar and pick a transport — **Wi-Fi** or
**Bluetooth**. Both publish the same payload; Bluetooth is the mode for when
there is no network to join.

### Wi-Fi

The app binds an HTTP server on **port 41729**, shows the URL to type on the
other phone, and keeps serving while sharing is on:

- `http://<phone-ip>:41729/` — a live page that shows **the same cards as the
  app**: carrier with its technology badge, slot, mode chip, one meter per NSA
  leg, eNB/gNB and sector, band, ARFCN, DL/UL frequencies, PLMN, radio quality
  and every neighbour with its PCI, band, frequency and bars. Both SIMs are
  stacked in slot order.
- `http://<phone-ip>:41729/snapshot` — the exact payload the app itself parses,
  with permissive CORS headers, so another app on the second phone can poll it.

The page is **rendered on the phone, not in JavaScript**. `/view` returns just
its live region, which the page swaps in every 2 s, and both the app and the
page read the same row builder (`serving_view.dart`) and model getters — so band
names, NR re-codes, the A10e's B106 aliasing, eNB/gNB decoding, DL/UL maths and
the satellite bars all match what the phone's own cards show, with no second
copy of that logic to drift.

The payload is published with **this phone's own numbering**, not the modem's
raw fields: the A10e sends `"bands": [106]` and `"arfcn": 134322`, so a peer
running the normal build renders its carrier as B106 / 938.00 / 899.00 rather
than B8 / 3580 / 893.00. Band 106 is in the frequency table for every build,
which is what lets the receiving phone price that channel without the sender's
re-code (or any flag of its own).

The dialog has a **Browser dashboard** switch. Turn it off for **API-only
mode**: `/` and `/index.html` then return the same JSON as `/snapshot`, no HTML
is served at any path, and unknown paths answer with JSON instead of text. It
flips live without rebinding the port, so a client polling `/` keeps working
when you change the mode.

Nothing goes to the internet: the response is whatever the modem last reported,
and stopping the share closes the port. Only Wi-Fi, hotspot, Ethernet and USB
tether addresses are handed out — a cellular address sits behind the carrier's
NAT and would never work, so with mobile data only the dialog says to join
Wi-Fi instead. It only runs while the app is alive and sharing is on — Android
kills the process in the background, so this is a “both phones on the desk”
feature.

### Bluetooth

**Bluetooth** mode (`BleShare.kt`) advertises a GATT service from the same app,
with no network and no mobile data involved. The dialog shows the name the other
phone will list — this phone's Bluetooth name, which is its model on most
devices — and keeps the newest reading pushed into the advertiser as it changes.

Reads are chunked: every read answers `[index, total, …bytes]` sized to the
client's negotiated MTU, the server keeps a per-client cursor, and writing to the
reset characteristic rewinds a client that lost a read. A phone that never
negotiates a larger MTU still works at 20-byte chunks. Phones that cannot
advertise (some older budget models) report that in the dialog instead of
silently doing nothing.

## Watching another phone

The receiving end is in the app too: tap the **cast icon** in the app bar and
pick **Wi-Fi** or **Bluetooth**.

Wi-Fi either takes the address the other phone is advertising (`10.1.1.47` or
`10.1.1.47:41729`, scheme and path optional) or finds it with **Scan network**,
which sweeps the subnet on 41729 and lists every phone that answers. Bluetooth
scans for phones running the Bluetooth share and lists them by name and signal
strength; tapping one connects. Either way the app polls that phone every 2 s —
over HTTP, or over the GATT link it keeps open (`BleWatch.kt`).

**The port is fixed on purpose.** It used to be "first free of 8080–8083", which
made a scan impossible: there was no known port to knock on. It now sits high,
clear of the 8000/8080/8090 range that dev servers, printers and routers occupy,
and both ends use the same number so either can find the other. A bind failure
is reported instead of silently drifting to another port, and a short retry
rides out the TIME_WAIT left by stopping and restarting the share.

Discovery reads `/health` rather than merely probing for an open socket, so a
random device that happens to hold 41729 is not reported as a phone — the answer
has to be this app's `{"ok": true}` JSON.

The remote reading is fed through the same parser and the same cards, so it
looks and behaves like a local read: two swipeable SIM pages, NSA vs SA meters,
eNB/gNB, band, ARFCN, downlink/uplink, neighbours and bars. A banner names the
peer and their model, and the subtitle switches to `Remote · <ip>`.

- Polls never overlap; a slow peer cannot queue up requests.
- If the peer stops answering, the last reading stays on screen under an amber
  banner with the reason, and the link recovers by itself once the peer is back
  — no reconnecting by hand.
- Pull-to-refresh polls the peer immediately; the **×** on the banner stops
  watching and returns to the local radio.
- Watching needs no local location permission: the peer's `permissionGranted`
  and `locationEnabled` flags drive the view, so a viewer that has never
  granted access still renders the other phone's towers.

The Wi-Fi client only speaks HTTP/JSON to `/snapshot`, so anything can supply
it — this app's own share, another install on the same Wi-Fi, or a script that
produces the same payload. That also makes the app usable as a mirror while it
shares in API-only mode. The Bluetooth client consumes the same JSON, byte for
byte, so both transports land in the same parser and the same cards.

## Desktop console (Windows)

`desktop/sector_scout_desktop.py` is the same idea on a PC, and it does two jobs
that complement the phone:

- **Test source** — it serves the phone's own `/snapshot` JSON on **41729**, the
  same fixed port the phone uses, so a phone can *watch the PC* to exercise
  badges, bands, bars, NSA/SA, eNB/gNB and the band switches without touching a
  modem. That is what makes the band remaps and the 5G-attached rule testable on
  demand. The port is not a setting on either side: it is how each end finds the
  other with **Scan**, and there is nothing to type.
- **Phones** — it polls several peer phones at once and draws their readings
  side by side, one card per phone with a block per SIM. Each SIM is drawn the
  way the app draws its own card: carrier and technology badge with the mode
  chip opposite, the five-bar meter and level, then the same rows — eNB/gNB and
  sector, TAC, PCI, band, channel, downlink/uplink, PLMN — followed by the
  radio-quality rows and the neighbours, so a reading looks the same in both
  places. A phone sharing over **Bluetooth** arrives the same way: `Scan
  Bluetooth` looks for the app's GATT service, and the chosen phones are polled
  over that link (every five seconds — a GATT read pulls the whole payload, so
  it cannot run at the Wi-Fi cadence). That needs the `bleak` package
  (`pip install bleak`), which is the one dependency the console has; without it
  the button is still drawn, disabled, with the reason in the footer. The phone app itself
  only watches one peer at a time.

Launch it with `desktop/Sector Scout Desktop.lnk`: that runs it under
`pythonw.exe`, so there is no console window, and its taskbar entry carries the
Sector Scout icon (`sector_scout.ico`). Only tkinter is needed — no packages to
install.

| Scenario | What it exercises |
| --- | --- |
| T-Mobile n41 SA | modem says n38 at 2606.55 MHz → the n41 correction |
| T-Mobile n71 SA (band unknown) | no band at all → the band named from the ARFCN |
| AT&T 5G NSA (5G+) | LTE anchor + NR leg with `NR_ADVANCED` → the 5G+ badge |
| Anterix B106 LTE-M | band 8 raster → B106 when the Anterix switch is on |
| Dual SIM (T-Mobile + Verizon) | two SIMs on one peer |

The signal drifts ±2 dBm between requests so the bars and the "read Ns ago"
line visibly update; every other field is fixed, so what you see is the
scenario, not noise.

For anything the presets do not cover, pick **Custom — pick every field** and
build the source yourself. Each part is set independently:

- **Carrier** — pick a name to fill **MCC** and **MNC**, or type both yourself.
  A PLMN that is not in `plmns.json` works fine; the picker simply stops naming
  it until it matches one again.
- **Override** — `NONE`, `LTE_CA`, `LTE_ADVANCED_PRO`, `NR_NSA`, `NR_SA`,
  `NR_ADVANCED (NSA)` or `NR_ADVANCED (SA)`; this is what decides `LTE+`, `5GE`,
  `5G`, `5G+`, `5GUC` and `5GUW`. The two LTE entries serve **no NR carrier at
  all** — that is the only way the app can be shown an aggregation label, since
  an attached 5G carrier outranks it — but the NR rows stay in the source, so
  switching back to an NR override restores them. `LTE_ADVANCED_PRO` reads
  `5GE` on an AT&T or FirstNet PLMN and `LTE+` anywhere else. This is the way to
  exercise `5GE` away from a cell site. The two advanced
  entries send the same platform value, because a phone cannot tell you which
  it is holding — they differ in what they set up. **NR_ADVANCED (NSA)** keeps
  the anchor and gives you one NR leg; **NR_ADVANCED (SA)** unticks the anchor
  and opens the source to five aggregated carriers. Unticking the anchor by
  hand renames the entry to match, so the name never disagrees with the layout.
- **LTE anchor** — band, EARFCN and level, or unticked for an NR-only (SA)
  source.
- **LTE carriers** — the anchor plus up to four aggregated layers, added with
  **+ Add LTE carrier**. A layer on band 29 is served as a downlink-only
  supplemental carrier exactly the way a modem reports one: no cell identity, no
  TAC and no PLMN until it moves data. Any other band is a carrier-aggregation
  layer with its own eNB, sector, PCI and TAC, which the app lists under *4G
  LTE secondary*. Layers need an anchor: untick it and they are held back rather
  than served as a second primary.
- **NR carriers** — one row each, added with **+ Add NR carrier**. How many you
  get depends on the override, because the two cases are not the same thing:
  **NR_NSA is one secondary carrier** on an LTE anchor, while **NR_SA
  aggregates up to five**. The button shows the budget (`+ Add NR carrier 1/5`)
  and greys out at the limit; switching to NR_NSA trims extra legs rather than
  serving something a modem could never report.
- **Neighbours** — how many measured-but-not-served LTE cells to report, and on
  which band. They are served the way a modem really hands them over: no PLMN,
  no cell identity and no TAC, just a PCI, a band and a level, each 6 dB and
  then 4 dB per cell below the anchor. That exercises the app's neighbour card
  and its "Android 12+ hides neighbour cell IDs" note without needing a site
  nearby. Twelve is the ceiling.

The tick box on each row is a switch, not a delete. Unticked, the carrier stays
in the editor — band, channel, level and identity all kept — but it is left out
of the served JSON, and its fields grey out so it is obvious it is not being
sent. That is how the states a preset cannot express are reachable:

| What you want | How to get it |
| --- | --- |
| LTE only on an NSA network (anchor with no 5G leg) | untick the NR row, keep `NR_NSA` |
| Plain LTE with no override at all | untick the NR row, set override `NONE` |
| 5G SA with no LTE anchor | untick **LTE anchor** |
| NSA anchor back with its leg | tick the NR row again |

The **−** button removes a row outright, down to zero NR carriers; the summary
line names the result (`B30 anchor · NR_NSA → LTE only`, `n5 + n77 · NR_SA →
5G SA`, `no carriers · NONE → nothing served`) so what the phone will call the
reading is visible before you point it at this PC.

Each row also carries the site identity **eNB**/**gNB**, **Sector**, **PCI** and
**TAC**. The eNB and sector are packed into the 28-bit ECI the app splits back
out, and the gNB and sector into the 36-bit NCI — using the gNB ID length the
operator actually uses, 26 bits for AT&T, 24 for T-Mobile and 22 for everyone
else, so the number read back on the phone is the number typed here. The
defaults decode as eNB 30722 / sector 36 and gNB 12295710 / sector 49. A gNB
wider than the operator's field is masked to fit, and a row added with **+ Add
NR carrier** gets its own sector and PCI instead of repeating the first one.

**PCI is limited to what the radio can carry:** 0–503 on LTE (504 physical cell
identities) and 0–1007 on NR (1008). A larger number is snapped to the limit
when you leave the box, and clamped again on the way into the payload, so a
typo can never be served as an identity no modem would report.

Two rules follow what a modem actually reports, and the editor shows both:

- **While an LTE anchor is serving, the NR identity is not sent.** With NSA up
  the radio hands over the 5G leg's PCI, band and channel but not its NCI, so
  there is no gNB and no sector to encode and no TAC either. The NR gNB,
  Sector and TAC boxes grey out and the payload carries `cellId: null` and
  `tac: null`, which is what makes the app show **gNB (est.)** — its estimate
  from the LTE eNB (eNB 245029 → gNB 12295029 on AT&T). Untick the anchor and
  the fields come back, because standalone 5G does report its own identity.
- **A single FR2 carrier cannot be SA.** The millimetre-wave bands (n257–n262)
  are only ever a secondary component of NR CA, so with no LTE anchor and one
  NR row that row is left out of the payload and the summary says so
  (`no carriers · NR_SA → nothing served (mmWave needs CA)`). Add a second NR
  carrier, or an anchor, and the FR2 row is served again.

Each row takes a **band**, a **channel** and a **frequency**, and the last two
track each other — type `881.5` MHz and the EARFCN follows, or type `2525` and
the frequency does. Band lists are shortcuts rather than constraints: `n5`,
`B106`, `band 71` and a bare `5` are all read the same way, and a band with no
built-in channel leaves the field for you to fill. A band that has no known
LTE mapping (an Anywave or Anterix band, say) still accepts a channel by hand.

Level is set three ways, all of them in sync: the filled **slider**, the spinbox
arrows, and typing. The slider maps the pointer straight onto −140…−40 dBm and
colours the track with the same scale as the signal bars, so it doubles as a
readout.

The summary line under the URL reads back what is currently served
(`B30 anchor + n5 · NR_NSA → 5G NSA (gNB est. — no NR identity)`), the payload
preview below it is the composed JSON, and the layout — including which rows
are switched off — is saved with the rest of the config.

To watch real phones, type an address in the **Phones** tab — `10.1.1.47` or
`10.1.1.47:37534`, scheme and path optional — and press **Add phone**. The list
is saved to `%APPDATA%\Sector Scout\desktop.json`, along with the port and the
scenario, so the console comes back the way you left it. **Display
corrections** turns the T-Mobile and CBRS band remaps on or off in the view, so
the same reading can be compared with and without them.

```
cd desktop
python sector_scout_desktop.py [--port 8090]
```

## Device support

`minSdkVersion` is 24 (Android 7.0), `targetSdkVersion` is 36, and the release
APK ships `armeabi-v7a`, `arm64-v8a` and `x86_64`, so 32-bit phones install it.

The telephony code is guarded by API level: `CellInfoNr` needs 29,
`TelephonyDisplayInfo` needs 30, `TelephonyCallback` needs 31. Older releases
still read the modem-wide cell list and draw the same cards, with polling in
place of modem callbacks.

- **Galaxy A10e, Android 11 (API 30)** — installed and exercised over USB. It
  gets the 2.5 s poll instead of `TelephonyCallback`, but the NSA/SA chip still
  works from the API 30 display info; NR cells appear only if that modem reports
  them, and the A10e is LTE-only hardware. Its modem reports LTE with an empty
  band list, which is why the band/frequency inference above exists.
- **Galaxy A14 5G, Android 15 (API 35)** and **A15 5G, Android 16 (API 36)** —
  full feature set; `targetSdk 36` already handles forced edge-to-edge, and the
  bottom padding uses `viewPadding`.

## Permissions and Android rules

Android treats cell data as location data, so:

- `ACCESS_FINE_LOCATION` is required — without it `getAllCellInfo()` returns
  nothing at all.
- **Location services must be switched on** (not just the permission), or the
  cell list comes back empty.
- `READ_PHONE_STATE` is requested for the subscription list, network type and
  operator names.

Nothing leaves the device unless you turn on the Wi-Fi share above, and that
traffic never leaves your local network. The app is portrait-locked so the
reading cannot be rotated away mid-capture.

Known limitations, all Android-side:

- From Android 12, **neighbour cell IDs are masked** for normal apps; only the
  serving cell keeps its real CI. Neighbours are labelled by PCI + band.- **Neighbour scans are modem-wide.** `getAllCellInfo()` returns one list for
  the radio rather than one per subscription. When both slots see the same
  neighbours, the list is shown once and tagged `shared radio`; serving cells
  and levels are still per-SIM.
- Some OEM ROMs return cached or partial cell info unless the app is
  foregrounded.
- 5G NR data (SS-RSRP, SINR) only appears on devices/modem firmware that
  reports it; SA vs NSA details beyond the registered-cell heuristic need
  carrier privileges.

## Structure

```
lib/
  main.dart                     app shell, dark theme, system bar styling
  models/cell_snapshot.dart     payload parsing, SIMs, NSA/SA, dBm→bars, eNB/sector
  models/band_filters.dart      the display-correction switches, read by the model
  models/band_tables.dart       GENERATED: every LTE/NR band, from bands.json
  services/app_settings.dart    loads/stores those switches through the channel
  services/cell_tower_service.dart  MethodChannel + EventChannel client
  services/signal_notification.dart switch for the pinned notification service
  services/lan_server.dart      optional LAN share: dashboard + JSON snapshot
  services/dashboard_html.dart  the browser page, built from this phone's model
  services/serving_view.dart    the card rows, shared by the app and the page
  services/lan_discovery.dart   subnet sweep for phones on the share port
  services/remote_client.dart   LAN peer client: address parsing + snapshot fetch
  services/ble_link.dart        Bluetooth share + watch over the native GATT bridge
  services/carrier_names.dart   PLMN → carrier brand, from the private_plmn repo
  screens/home_screen.dart      per-SIM pages, SimHeaderCard, share/remote dialogs
  screens/settings_screen.dart  band switches and the pinned-notification switch
  widgets/signal_bars.dart      animated 5-bar meter
  widgets/tech_badge.dart       LTE / LTE+ / 5GE / 5G / 5G+ / 5GUC / 5GUW label
  theme/app_colors.dart         palette
plmns.json                      the operator list to push to private_plmn
bands.json                      every LTE/NR band + channel window, shared by both
tool/gen_bands.py               rebuilds bands.json and lib/models/band_tables.dart
android/app/src/main/kotlin/com/celltower/cell_tower_monitor/
  MainActivity.kt               registers the channels
  CellSnapshot.kt               per-SIM TelephonyManager → Map payload
  CellMonitor.kt                live callbacks + polling, coalesced
  ServingMerge.kt               scan/registration pairing, PCI + channel memory
  SignalSummary.kt              notification lines: band, band 106, gNB/sector
  SignalIcon.kt                 LTE / LTE+ / 5GE / 5G / 5G+ / 5GUC / 5GUW bitmaps
  CarrierBrands.kt              PLMN → brand for the notification
  AppSettings.kt                the band switches, in prefs the service can read
  SignalStatusService.kt        foreground service holding the pinned notification
  BleShare.kt                   GATT server: advertises + chunks the snapshot
  BleWatch.kt                   GATT client: scan, connect, reassemble, poll
desktop/
  sector_scout_desktop.py       Windows console: spoof /snapshot, watch many phones
  sector_scout.ico              window and taskbar icon
  Sector Scout Desktop.lnk      starts it under pythonw, no console window
```

Payload shape from the native side:

```
{ permissionGranted, locationEnabled, timestamp, deviceModel, cellCount,
  sims: [ { slotIndex, subscriptionId, carrierName, isDefault, simState,
            networkTypeName, cells: [ { type, registered, cellId, tac, pci,
            mcc, mnc, dbm, level, arfcn, bands[], rsrp, rsrq, sinr,
            timingAdvance } ] } ] }
```

Channel names: `cell_tower/monitor` (method `snapshot`) and
`cell_tower/stream` (events). If you swap the telephony layer, those are the
only contracts to keep.

## Tests

```bash
flutter test                                   # Dart
cd android && ./gradlew :app:testDebugUnitTest # native (JVM)
```

The Dart suite includes the carrier badge matrix (`test/tech_badge_test.dart`),
which mirrors `SignalIconTest` so the header badge and the notification icon
cannot drift apart.

The Kotlin tests cover what cannot be reproduced on demand: the cell-pairing
fallback, the PLMN-switch identity match, the PCI and last-known-channel holds
in `ServingMerge`; the notification's lines in `SignalSummary` (band inference,
the A10e re-code, brand-vs-SIM name, the AT&T vs 22-bit gNB split, and that the
SIM label matches the numbers); and the badge matrix in `SignalIcon`.

## What changed recently

- **Band and channel that survive a band lock.** The served cell is filled from
the modem's own scan even when registration reports no identity, and a channel
or PCI the radio stops reporting is held for that cell (15 minutes) instead of
blanking the row. A held channel is labelled `(last known)`.
- **PCI stays put across a PLMN switch.** Identity agreement (CI, or PCI when
the CI is unknown) is checked before the network filter, so a scan copy still
carrying the old code can supply the PCI the served cell is missing.
- **Your carrier list, not the community MCC/MNC database.** See the table above.
- **Bluetooth as a second transport.** Share or watch over BLE when there is no
  Wi-Fi to join; both dialogs switch between Wi-Fi and Bluetooth.
- **The pinned notification stays fresh in the background.** Battery-optimisation
  exemption card plus a screen-on refresh.
- **The carrier badge is in the app**, to the right of the carrier name with the
  slot (SIM 1/2) after it, so the header shows the same `LTE` / `5G` / `5G+` /
  `5GUC` / `5GUW` the notification icon does. A satellite link shows `SAT` in
  that slot instead of the technology. It always names the radio that is
  serving: an NSA slot whose 5G leg has dropped reads `LTE` — it used to be
  hidden there, which left the header with no technology label at all.
- **The mode chip is only green when 5G is attached.** `5G NSA` keeps its words
  when the NR carrier goes away (Samsung holds the override), but it drops the
  accent colour, so green always means an NR cell is really there.
- **The notification says which technology you are on** and names the network by
  brand, not by whatever the SIM card calls itself.

Covers payload parsing (including `Integer.MAX_VALUE` "unavailable" sentinels),
dual-SIM parsing, NSA/SA detection, eNB/sector decoding, numeric-only sectors on
both RATs (no Alpha/Beta/Gamma naming), NR carrier and centre frequency from the
ARFCN, downlink/uplink
frequencies (FDD, reverse duplex, TDD and downlink-only bands, plus the NR band
offsets), the NSA gNB estimate (including the cases where it must stay blank:
other operators, small cells, and a reported NCI), the bar thresholds, the NSA
dual-meter vs SA single-meter layout at 360 dp, the bars widget, and the LAN
server end to end — `/snapshot`, the rendered dashboard and its `/view` region,
the 503 before the first reading, and the port closing on stop — plus the CA
secondary rule (a second registered LTE carrier is attached, not a neighbour) — the band inferred from a bare EARFCN
(and reported bands still winning), which carriers count as TDD, plus the LAN
client: address
normalisation, fetching and parsing a peer payload, always hitting `/snapshot`,
and the messages for 503, non-JSON, an unexpected status and an unreachable
address — plus the carrier-name list: brand vs operator fallback, first-entry
wins over MVNOs, both MNC widths, junk input, and keeping the SIM's own name
until the list loads.
