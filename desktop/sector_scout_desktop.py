#!/usr/bin/env python3
"""Sector Scout Desktop — serve a spoof payload, watch real phones.

Two jobs, in one window:

* **Test source** — an HTTP server that answers the same `/snapshot` JSON the
  phone app's LAN sharing serves, so a phone (or the app's "Watch another
  phone" dialog) can be pointed at this PC to exercise the UI without a modem:
  badges, band labels, bars, NSA/SA, and the band corrections.
* **Phones** — polls one or more willing phones and shows their live readings
  side by side, which is what the phone app itself cannot do (it watches one
  peer at a time).

No third-party packages are required: tkinter ships with Python, and the
taskbar icon comes from `sector_scout.ico` next to this file. Launch it through
`Sector Scout Desktop.lnk` to get that icon without a console window.

Usage:  python sector_scout_desktop.py

The port is not an option: the phone's sharing server, its LAN scan and this
source all use 41729, which is how either end finds the other.
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes
import importlib.util
import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tkinter as tk
from tkinter import ttk
from tkinter import messagebox

APP_DIR = Path(__file__).resolve().parent


def _data_file(name: str) -> Path:
    """Where a file shipped with the app lives.

    From the repository, `sector_scout.ico` sits beside this script and
    `bands.json`/`plmns.json` one folder up. A PyInstaller build has neither
    layout: the executable's own folder, and the bundle's unpack directory,
    are what matter there. The first candidate that exists wins, so one
    script works in both places.
    """
    roots = [APP_DIR, APP_DIR.parent]
    if getattr(sys, "frozen", False):
        roots.insert(0, Path(sys.executable).resolve().parent)
        bundle = getattr(sys, "_MEIPASS", None)
        if bundle:
            roots.insert(0, Path(bundle))
    for root in roots:
        candidate = root / name
        if candidate.is_file():
            return candidate
    return roots[0] / name
CONFIG_DIR = Path(os.environ.get("APPDATA", str(Path.home()))) / "Sector Scout"
CONFIG_FILE = CONFIG_DIR / "desktop.json"
ICON_FILE = _data_file("sector_scout.ico")

# The app's palette, so the two look like one product.
BG = "#070A0F"
SURFACE = "#111823"
SURFACE_ALT = "#0D1420"
BORDER = "#1E293B"
TEXT = "#F1F5F9"
MUTED = "#94A3B8"
OFF = "#475569"  # a switched-off carrier: present, but clearly not served
TRACK = "#1F2937"  # an empty bar, as the app draws it
ACCENT = "#34D399"
WARNING = "#FBBF24"
DANGER = "#F87171"

POLL_SECONDS = 2.0
# A Bluetooth read opens a GATT link and pulls the whole payload, so BLE
# phones are polled on their own, slower cadence.
BLE_POLL_SECONDS = 5.0

# --- the same bar scale the app uses -------------------------------------
def bars_for(dbm: int | None) -> int:
    if dbm is None:
        return 0
    if dbm >= -84:
        return 5
    if dbm >= -94:
        return 4
    if dbm >= -104:
        return 3
    if dbm >= -114:
        return 2
    if dbm >= -124:
        return 1
    return 0


def bar_colour(bars: int) -> str:
    return {5: ACCENT, 4: "#A3E635", 3: WARNING, 2: WARNING, 1: DANGER}.get(
        bars, "#6B7280"
    )


def bar_text(bars: int) -> str:
    return "\u25ae" * bars + "\u25af" * (5 - bars)


def nr_mhz(arfcn: int | None) -> float | None:
    if not arfcn or arfcn <= 0:
        return None
    if arfcn < 600000:
        return arfcn * 0.005
    if arfcn <= 2016666:
        return 3000.0 + (arfcn - 600000) * 0.015
    return 24250.08 + (arfcn - 2016667) * 0.06


# --- band tables -----------------------------------------------------------
# Every LTE and NR band, with its channel window and lowest frequencies, read
# from `bands.json` — the same file `tool/gen_bands.py` compiles into the app's
# Dart table. One source, so the source can only dial a band the phone can
# decode, and a channel means the same frequency on both ends.
BANDS_FILE = _data_file("bands.json")


def _load_bands() -> tuple[dict[int, dict], dict[int, dict]]:
    """(lte, nr) band tables, keyed by band number."""
    try:
        raw = json.loads(BANDS_FILE.read_text(encoding="utf-8"))
        lte = {int(row["band"]): row for row in raw.get("lte") or []}
        nr = {int(row["band"]): row for row in raw.get("nr") or []}
        if lte and nr:
            return lte, nr
    except (OSError, ValueError, TypeError, KeyError):
        pass
    return {}, {}


LTE_BANDS, NR_BANDS = _load_bands()

# A representative channel per band, so choosing `n5` is enough to get a
# carrier; the channel stays editable for anything else. Half-way into each
# band's downlink allocation, which is clear of both edges.
LTE_CHANNELS = {band: (plan["first"] + plan["last"]) // 2 for band, plan in LTE_BANDS.items()}
NR_CHANNELS = {band: (plan["first"] + plan["last"]) // 2 for band, plan in NR_BANDS.items()}

# The bands the app resolved from a channel before the tables were whole. They
# keep priority, because the full NR table overlaps by design (n2 in n25, n38 in
# n41, n5 in n26, n71 in n105) and a band added since must never take one of
# them over — the A15's n71 has to keep reading n71.
NR_FIRST_WAVE = {
    1, 2, 3, 5, 7, 8, 12, 13, 14, 20, 25, 26, 28, 30, 38, 41, 48, 66, 70, 71,
    77, 78, 79, 260, 261,
}


def nr_band_from_arfcn(arfcn: int | None) -> int | None:
    """The NR band a channel sits in, or None when more than one fits."""
    if not arfcn or arfcn <= 0:
        return None
    claims = [
        band for band, plan in NR_BANDS.items()
        if plan["first"] <= arfcn <= plan["last"]
    ]
    established = [band for band in claims if band in NR_FIRST_WAVE]
    pool = established or claims
    return pool[0] if len(pool) == 1 else None


def lte_band_from_earfcn(earfcn: int | None) -> int | None:
    """The LTE band a channel sits in — 3GPP's ranges never overlap."""
    if not earfcn or earfcn <= 0:
        return None
    for band, plan in LTE_BANDS.items():
        if plan["first"] <= earfcn <= plan["last"]:
            return band
    return None

TMOBILE_PLMNS = {"310260", "312190"}


def band_name(band: int, tech: str | None) -> str:
    """One band as the app writes it: `B71` for LTE, `n77` for NR."""
    return f"{'n' if tech == 'NR' else 'B'}{band}"


def band_label(cell: dict, corrections: bool = True) -> str | None:
    """Band as the phone app would label it, for the same cell.

    The app names *every* band the modem listed, joined with a comma, and
    corrects them one at a time: n77 on a CBRS carrier, and T-Mobile's n38/n2
    when the modem named a single, narrower band. Anything less here — one band
    instead of the list, or a correction the app would not make — is exactly
    what makes this card disagree with the phone, so the rules are copied
    rather than approximated.
    """
    tech = cell.get("type")
    bands = [b for b in (cell.get("bands") or []) if isinstance(b, int) and b > 0]
    arfcn = cell.get("arfcn") if isinstance(cell.get("arfcn"), int) else None
    plmn = f"{cell.get('mcc')}{cell.get('mnc')}"

    if not bands:
        # A modem that names no band (or reports BAND_UNKNOWN) is answered from
        # the channel, on the same tables and with the same priority the phone
        # uses.
        inferred = (
            nr_band_from_arfcn(arfcn)
            if tech == "NR"
            else lte_band_from_earfcn(arfcn)
        )
        return None if inferred is None else band_name(inferred, tech)

    mhz = nr_mhz(arfcn) if tech == "NR" else None
    labels: list[str] = []
    for band in bands:
        if corrections and tech == "NR":
            if band == 77 and mhz is not None and 3550 <= mhz < 3700:
                labels.append(band_name(48, tech))
                continue
            # The app only re-codes a band the modem named on its own: a cell
            # listing several keeps the numbers it reported.
            if len(bands) == 1 and plmn in TMOBILE_PLMNS and arfcn:
                if band == 38 and 499200 <= arfcn <= 537999:
                    labels.append(band_name(41, tech))
                    continue
                if band == 2 and 386000 <= arfcn <= 399999:
                    labels.append(band_name(25, tech))
                    continue
        labels.append(band_name(band, tech))
    return ", ".join(labels)


def mode_of(sim: dict, cells: list[dict]) -> str:
    serving = [c for c in cells if c.get("registered")]
    has_lte = any(c.get("type") == "LTE" for c in serving)
    has_nr = any(c.get("type") == "NR" for c in serving)
    if has_nr and has_lte:
        return "5G NSA"
    if has_nr:
        return "5G SA"
    if has_lte:
        return "4G LTE"
    return sim.get("networkTypeName") or "No service"


ATT_BADGE_PLMNS = frozenset({"310410", "310150", "310170", "310380", "313100"})
VERIZON_PLMN = "311480"


def plmn_of(cell: dict | None) -> str:
    """A cell's MCC/MNC as one string (`313700`), or "" when it names none."""
    if not cell:
        return ""
    mcc = str(cell.get("mcc") or "")
    mnc = str(cell.get("mnc") or "")
    return f"{mcc}{mnc}" if mcc and mnc else ""


# --- carrier names ---------------------------------------------------------
# The operator's brand, by PLMN, from the same public list the app fetches. The
# name on the SIM is only what the card carries — often an MVNO, a roaming
# partner, or a stale translation — so the network the modem is registered on is
# what names the carrier, exactly as the app's `CarrierNames.resolve` does.
CARRIER_URLS = [
    "https://raw.githubusercontent.com/tsalisbury0/private_plmn/main/plmns.json",
    "https://raw.githubusercontent.com/tsalisbury0/private_plmn/main/carriers.json",
    "https://raw.githubusercontent.com/tsalisbury0/private_plmn/master/plmns.json",
]
# A frozen build cannot write beside its own executable when it is
# installed under Program Files, so the cache goes with the config.
CARRIER_CACHE = (
    CONFIG_DIR if getattr(sys, "frozen", False) else APP_DIR
) / "carrier_names.json"
if getattr(sys, "frozen", False):
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
CARRIER_REFRESH_SECONDS = 24 * 3600
CARRIER_BRANDS: dict[str, str] = {}


def _parse_carriers(raw: object) -> dict[str, str]:
    """`[{mcc, mnc, brand, ...}]` as `{"310-260": "T-Mobile"}`."""
    table: dict[str, str] = {}
    if not isinstance(raw, list):
        return table
    for row in raw:
        if not isinstance(row, dict):
            continue
        mcc = str(row.get("mcc") or "").strip()
        mnc = str(row.get("mnc") or "").strip()
        brand = row.get("brand")
        if mcc and mnc and isinstance(brand, str) and brand.strip():
            table[f"{mcc}-{mnc}"] = brand.strip()
    return table


def refresh_carrier_names(force: bool = False) -> dict[str, str]:
    """The operator list, from the cache or the app's own URLs. Never raises."""
    global CARRIER_BRANDS
    try:
        fresh = (
            not force
            and CARRIER_CACHE.exists()
            and time.time() - CARRIER_CACHE.stat().st_mtime < CARRIER_REFRESH_SECONDS
        )
    except OSError:
        fresh = False
    if not CARRIER_BRANDS:
        # The cache holds the table already keyed by PLMN, so it is read back as
        # it was written rather than parsed as the remote list again.
        try:
            cached = json.loads(CARRIER_CACHE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cached = {}
        if isinstance(cached, dict):
            CARRIER_BRANDS = {
                str(key): str(value)
                for key, value in cached.items()
                if isinstance(key, str) and isinstance(value, str) and value
            }
    if fresh:
        return CARRIER_BRANDS
    for url in CARRIER_URLS:
        try:
            with urllib.request.urlopen(url, timeout=6) as response:
                table = _parse_carriers(json.loads(response.read().decode("utf-8")))
        except Exception:  # noqa: BLE001 - being offline is normal, not an error
            continue
        if table:
            CARRIER_BRANDS = table
            try:
                CARRIER_CACHE.write_text(json.dumps(table), encoding="utf-8")
            except OSError:
                pass
            break
    return CARRIER_BRANDS


def serving_plmn(sim: dict) -> str:
    """The PLMN the SIM is registered on, as `310260`, or ""."""
    for cell in sim.get("cells") or []:
        if isinstance(cell, dict) and cell.get("registered"):
            plmn = plmn_of(cell)
            if plmn:
                return plmn
    return "".join(ch for ch in str(sim.get("plmn") or "") if ch.isdigit())


def carrier_name(sim: dict) -> str:
    """The operator's brand for this SIM, falling back to the SIM's own name."""
    sim_name = str(sim.get("carrierName") or "").strip()
    if not sim_name:
        sim_name = str(sim.get("label") or "").strip()
    plmn = serving_plmn(sim)
    if len(plmn) >= 5:
        brand = CARRIER_BRANDS.get(f"{plmn[:3]}-{plmn[3:]}")
        if brand:
            return brand
    return sim_name


def band_number(cell: dict) -> int | None:
    """The band a cell is on: the modem's own, else worked out from the channel."""
    bands = cell.get("bands") or []
    if bands:
        try:
            return int(bands[0])
        except (TypeError, ValueError):
            pass
    arfcn = _int_or(cell.get("arfcn"))
    if not arfcn:
        return None
    if cell.get("type") == "NR":
        return nr_band_from_arfcn(arfcn)
    return lte_band_from_earfcn(arfcn)


def is_sdl_lte(cell: dict) -> bool:
    """True for a downlink-only LTE carrier (29, 32, 67, 69, 75, 76)."""
    if cell.get("type") != "LTE":
        return False
    plan = LTE_BANDS.get(band_number(cell) or -1)
    return bool(plan and plan.get("mode") == "SDL")


# --- Shizuku carrier detail ------------------------------------------------
# A phone with the privileged reader bound sends its physical carriers in
# `carriers`: the only reading that says how wide each one is and which of them
# are aggregated. Each entry is the app's own JSON — `net`, `band`, `bw`, `pci`
# — so the console reads exactly what the phone card reads, without a second
# parser to drift out of step.


def carrier_tech(carrier: dict) -> str:
    """`NR` or `LTE` for one carrier, from the NETWORK_TYPE it was read with."""
    return "NR" if _int_or(carrier.get("net")) == 20 else "LTE"


def mhz_text(khz: int) -> str:
    """A carrier width in MHz, without a trailing zero: 10, not 10.00."""
    text = f"{khz / 1000:.2f}"
    if text.endswith(".00"):
        return text[:-3]
    return text[:-1] if text.endswith("0") else text


def carrier_rows(carriers: list[dict]) -> list[tuple[str, str]]:
    """One row per component carrier, then the width across all of them.

    Same shape as the phone's own carrier card: band and width on the row, the
    PCI when the framework named one, and an aggregate row underneath. A
    downlink-only band says SDL, because it has no uplink to pair with.
    """
    rows: list[tuple[str, str]] = []
    total = 0
    for carrier in carriers:
        band = _int_or(carrier.get("band"))
        tech = carrier_tech(carrier)
        width = _int_or(carrier.get("bw")) or 0
        total += width
        if band:
            label = band_name(band, tech)
            plan = LTE_BANDS.get(band) if tech == "LTE" else None
            if plan and plan.get("mode") == "SDL":
                label = f"{label} SDL"
        else:
            label = "band not reported"
        width_text = f"{mhz_text(width)} MHz" if width else "width not reported"
        pci = _int_or(carrier.get("pci"))
        rows.append(
            (f"{label} · {width_text}", "—" if pci is None else f"PCI {pci}")
        )
    count = len(carriers)
    rows.append(
        (
            "Aggregate",
            f"{count} carrier{'s' if count != 1 else ''} · {mhz_text(total)} MHz",
        )
    )
    return rows


def lte_secondaries(cells: list[dict]) -> list[dict]:
    """LTE carriers aggregated under the primary, the way the app counts them.

    Another registered LTE cell is one; so is a supplemental downlink, which a
    radio only reports while it is aggregating it. The S25 reports three band 29
    cells during 2+29 CA with none of them registered, so a supplemental carrier
    that never marks itself registered still counts — the strongest is taken and
    the rest stay neighbours.
    """
    lte = [c for c in cells if c.get("type") == "LTE"]
    primary = next(
        (c for c in lte if c.get("registered") and not is_sdl_lte(c)), None
    )
    if primary is None:
        primary = next((c for c in lte if c.get("registered")), None)
    candidates = [
        c for c in lte
        if c is not primary and (c.get("registered") or is_sdl_lte(c))
    ]
    if not candidates:
        return []
    registered = [c for c in candidates if c.get("registered")]
    if registered:
        return registered
    supplemental = [c for c in candidates if is_sdl_lte(c)]
    if not supplemental:
        return []
    strongest = max(
        supplemental,
        key=lambda c: c.get("dbm") if c.get("dbm") is not None else -140,
    )
    return [strongest]


def heard_neighbours(cells: list[dict]) -> list[dict]:
    """Cells heard but not serving, leaving out the aggregated secondaries."""
    secondaries = lte_secondaries(cells)
    return [
        c for c in cells
        if not c.get("registered") and not any(c is s for s in secondaries)
    ]


FR2_BANDS = frozenset({257, 258, 259, 260, 261, 262})


def nr_advanced_label(plmn: str) -> str | None:
    """The NR Advanced badge for a PLMN, or None when it has no house style."""
    if plmn in ATT_BADGE_PLMNS:
        return "5G+"
    if plmn == "310260":
        return "5GUC"
    if plmn == VERIZON_PLMN:
        return "5GUW"
    return None


def is_high_band_nr(cell: dict, sim: dict) -> bool:
    """True when the NR leg is on FR2: millimetre wave, above 24.25 GHz.

    The ARFCN is the authority when the modem reports one; the band covers the
    readings where it does not, including the carriers the Shizuku reader
    exposed when the cell itself had no band.
    """
    channel = _int_or(cell.get("arfcn"))
    if channel is not None and channel >= 2016667:
        return True
    if band_number(cell) in FR2_BANDS:
        return True
    if any(_int_or(band) in FR2_BANDS for band in (cell.get("bands") or [])):
        return True
    return any(
        _int_or(carrier.get("band")) in FR2_BANDS
        for carrier in (sim.get("carriers") or [])
        if isinstance(carrier, dict)
    )


def badge_for(sim: dict, cells: list[dict]) -> str:
    """The technology badge, mirroring `SignalIcon.labelFor` on the phone.

    5G is only claimed while an NR cell is attached. LTE+ appears whenever the
    LTE side is aggregating — a second carrier, a supplemental downlink, or the
    platform's own CA override — and 5GE is AT&T/FirstNet's name for
    LTE-Advanced Pro, never anyone else's.
    """
    serving = [c for c in cells if c.get("registered")]
    nr = next((c for c in serving if c.get("type") == "NR"), None)
    lte = next(
        (c for c in serving if c.get("type") == "LTE" and not is_sdl_lte(c)), None
    )
    if lte is None:
        lte = next((c for c in serving if c.get("type") == "LTE"), None)
    override = str(sim.get("overrideNetworkType") or "NONE")

    if nr is not None:
        plmn = plmn_of(nr) or plmn_of(lte) or str(sim.get("plmn") or "")
        advanced = nr_advanced_label(plmn)
        if advanced is not None:
            if override == "NR_ADVANCED":
                return advanced
            # Samsung still reports plain NR_SA on millimetre wave, where the
            # network keeps its Advanced badge.
            if is_high_band_nr(nr, sim):
                return advanced
        return "5G"
    if lte is None:
        return "—"
    plmn = plmn_of(lte) or str(sim.get("plmn") or "")
    # The reader's carriers are the strongest evidence of live CA: it labels an
    # aggregated LTE carrier with NETWORK_TYPE_LTE_CA (19), which the cell list
    # cannot show when the platform reports no second cell of its own.
    carriers = [c for c in (sim.get("carriers") or []) if isinstance(c, dict)]
    aggregating = lte_secondaries(cells) or any(
        _int_or(carrier.get("net")) == 19 for carrier in carriers
    )
    if override == "LTE_ADVANCED_PRO":
        return "5GE" if plmn in ATT_BADGE_PLMNS else "LTE+"
    if aggregating or override == "LTE_CA":
        return "LTE+"
    return "LTE"


def quality_label(bars: int) -> str:
    """The word under the meter, on the same scale the app uses."""
    if bars >= 5:
        return "Excellent"
    if bars == 4:
        return "Good"
    if bars == 3:
        return "Fair"
    if bars == 2:
        return "Weak"
    if bars == 1:
        return "Very weak"
    return "No signal"


def tac_label(cell: dict) -> str:
    return "LAC" if cell.get("type") in ("GSM", "WCDMA", "TDSCDMA") else "TAC"


def pci_label(cell: dict) -> str:
    return {
        "GSM": "BSIC",
        "WCDMA": "PSC",
        "TDSCDMA": "PSC",
        "CDMA": "SID",
    }.get(str(cell.get("type") or ""), "PCI")


def cell_ids(cell: dict) -> tuple[int | None, int | None]:
    """(site, sector) decoded from the cell identity, or (None, None).

    LTE packs a 20-bit eNB over an 8-bit sector; NR's split depends on the
    operator's gNB length, which is why the PLMN is needed to decode it.
    """
    cell_id = _int_or(cell.get("cellId"))
    if not cell_id or cell_id <= 0:
        return None, None
    if cell.get("type") == "NR":
        bits = gnb_bits(plmn_of(cell))
        sector_bits = 36 - bits
        return cell_id >> sector_bits, cell_id & ((1 << sector_bits) - 1)
    return cell_id >> 8, cell_id & 0xFF


# AT&T small cells and DAS use these eNB ranges, where the low byte is not a
# macro-sector number. The NSA gNB estimate is keyed to the macro plan, so those
# sites are left without one rather than given a tower number that is wrong.
ATT_UNMAPPED_ENB_PREFIXES = ("240", "241", "242", "243", "246", "248", "249")


def att_sector_plan_applies(cell: dict) -> bool:
    """True when this LTE cell sits on AT&T's macro plan, not a small cell/DAS."""
    site, _ = cell_ids(cell)
    if site is None:
        return False
    text = str(site)
    return not any(text.startswith(prefix) for prefix in ATT_UNMAPPED_ENB_PREFIXES)


def nsa_gnb_estimate(lte: dict | None, nr: dict | None) -> int | None:
    """The gNB an NSA leg hides, derived from the AT&T anchor as the app does."""
    if not lte or not nr or nr.get("cellId"):
        return None
    if plmn_of(lte) not in ATT_BADGE_PLMNS:
        return None
    if not att_sector_plan_applies(lte):
        return None
    site, _ = cell_ids(lte)
    return site + 12050000 if site else None


def downlink_mhz(cell: dict) -> float | None:
    """Downlink centre frequency, or None when the channel cannot place it."""
    arfcn = _int_or(cell.get("arfcn"))
    if not arfcn or arfcn <= 0:
        return None
    if cell.get("type") == "NR":
        return nr_mhz(arfcn)
    return lte_mhz(arfcn, band_number(cell))


def uplink_mhz(cell: dict) -> float | None:
    """Uplink centre frequency, or None for a downlink-only or unknown band."""
    down = downlink_mhz(cell)
    if down is None:
        return None
    band = band_number(cell) or -1
    arfcn = _int_or(cell.get("arfcn"))
    if cell.get("type") == "NR":
        plan = NR_BANDS.get(band)
        if not plan or plan.get("ulLow") is None:
            return None
        if plan.get("mode") == "TDD":
            return down
        offset = plan["ulLow"] - plan["dlLow"]
        high = plan.get("ulHigh")
        up = down + offset
        return min(up, high) if high is not None else up
    plan = LTE_BANDS.get(band)
    if not plan or plan.get("ulLow") is None or arfcn is None:
        return None
    if plan.get("mode") == "TDD":
        return down
    up = plan["ulLow"] + 0.1 * (arfcn - plan["first"])
    high = plan.get("ulHigh")
    return min(up, high) if high is not None else up


def serving_entries(
    cell: dict,
    corrections: bool = True,
    gnb_estimate: int | None = None,
    fallback_plmn: str | None = None,
) -> list[tuple[str, str]]:
    """The rows the phone's serving-cell card shows, for the same cell."""
    entries: list[tuple[str, str]] = []
    tech = cell.get("type")
    sdl = is_sdl_lte(cell)
    cell_id = _int_or(cell.get("cellId"))
    site, sector = cell_ids(cell)
    plmn = plmn_of(cell)

    if tech == "LTE":
        if not sdl:
            entries.append(("eNB (dec)", str(site) if site is not None else "—"))
            entries.append(
                ("Sector (dec)", str(sector) if sector is not None else "—")
            )
    elif tech == "NR":
        estimated = site is None and gnb_estimate is not None
        gnb = site if site is not None else gnb_estimate
        entries.append(
            (
                "gNB (est.)" if estimated else "gNB (dec)",
                str(gnb) if gnb is not None else "—",
            )
        )
        if not estimated and sector is not None:
            entries.append(("Sector (dec)", str(sector)))
        if cell_id:
            entries.append(("NCI (hex)", f"0x{cell_id:X}"))
    else:
        entries.append(("Cell ID", str(cell_id) if cell_id else "—"))

    if not sdl:
        tac = _int_or(cell.get("tac"))
        entries.append((tac_label(cell), str(tac) if tac is not None else "—"))
    pci = _int_or(cell.get("pci"))
    entries.append((pci_label(cell), str(pci) if pci is not None else "—"))

    band = band_label(cell, corrections)
    if band:
        entries.append(("Band", band))
    arfcn = _int_or(cell.get("arfcn"))
    entries.append(("ARFCN", str(arfcn) if arfcn else "—"))

    down, up = downlink_mhz(cell), uplink_mhz(cell)
    if down is not None and up is not None and abs(up - down) < 0.005:
        entries.append(("Downlink/Uplink", f"{down:.2f} MHz"))
    else:
        if down is not None:
            entries.append(("Downlink", f"{down:.2f} MHz"))
        if up is not None:
            entries.append(("Uplink", f"{up:.2f} MHz"))

    if plmn:
        entries.append(("PLMN", f"{plmn[:3]}-{plmn[3:]}"))
    elif fallback_plmn:
        entries.append(("PLMN", f"{fallback_plmn} (from primary cell)"))

    ta = _int_or(cell.get("timingAdvance"))
    if ta:
        metres = ta * 78
        entries.append(
            (
                "Distance (TA)",
                f"~{metres} m" if metres < 1000 else f"~{metres / 1000:.1f} km",
            )
        )
    return entries


def quality_for(cell: dict, prefix: str | None) -> list[tuple[str, str]]:
    """RSRP/RSRQ/SINR rows for one leg, named the way the card names them."""

    def label(name: str) -> str:
        return f"{prefix} {name}" if prefix else name

    entries: list[tuple[str, str]] = []
    if cell.get("rsrp") is not None:
        entries.append((label("RSRP"), f"{cell['rsrp']} dBm"))
    if cell.get("rsrq") is not None:
        entries.append((label("RSRQ"), f"{cell['rsrq']} dB"))
    if cell.get("sinr") is not None:
        entries.append((label("SINR"), f"{cell['sinr']} dB"))
    if cell.get("asu") is not None:
        entries.append((label("ASU"), str(cell["asu"])))
    entries.append((label("Platform level"), f"{_int_or(cell.get('level')) or 0} / 4"))
    return entries


def quality_entries(cells: list[dict]) -> list[tuple[str, str]]:
    """Radio-quality rows for a slot: one block per leg of an NSA pair."""
    registered = [c for c in cells if c.get("registered")]
    lte = next(
        (c for c in registered if c.get("type") == "LTE" and not is_sdl_lte(c)),
        None,
    )
    nr = next((c for c in registered if c.get("type") == "NR"), None)
    if lte is not None and nr is not None:
        return [*quality_for(lte, "LTE"), *quality_for(nr, "NR")]
    cell = nr or lte or (registered[0] if registered else None)
    return [] if cell is None else quality_for(cell, None)


def neighbour_frequency(cell: dict) -> str | None:
    """The compact ↓ / ↑ line a neighbour row carries."""
    down, up = downlink_mhz(cell), uplink_mhz(cell)
    if down is None:
        return None

    def short(value: float) -> str:
        text = f"{value:.2f}"
        if text.endswith(".00"):
            return text[:-3]
        return text[:-1] if text.endswith("0") else text

    if up is None:
        return f"↓ {short(down)} MHz"
    if abs(up - down) < 0.005:
        return f"↓↑ {short(down)} MHz"
    return f"↓ {short(down)} · ↑ {short(up)} MHz"


# -------------------------------------------------------------------------
# Test source: a synthetic snapshot in the phone's own payload shape
# -------------------------------------------------------------------------

def _cell(tech: str, **kw) -> dict:
    base = {
        "type": tech,
        "registered": True,
        "cellId": None,
        "tac": 12345,
        "pci": 100,
        "mcc": "310",
        "mnc": "260",
        "dbm": -90,
        "level": 3,
        "arfcn": None,
        "bands": [],
        "rsrp": None,
        "rsrq": None,
        "sinr": None,
        "timingAdvance": None,
    }
    base.update(kw)
    return base


def _sim(cells: list[dict], **kw) -> dict:
    base = {
        "slotIndex": 0,
        "subscriptionId": 1,
        "carrierName": "Test network",
        "isDefault": True,
        "simState": "READY",
        "networkTypeName": "LTE",
        "overrideNetworkType": "NONE",
        "cells": cells,
    }
    base.update(kw)
    return base


SCENARIOS: dict[str, dict] = {
    "T-Mobile n41 SA": {
        "sims": [
            _sim(
                [
                    _cell(
                        "NR",
                        cellId="4314132792",
                        pci=232,
                        arfcn=521310,
                        bands=[38],  # the modem's indicator; the app reads n41
                        mcc="310",
                        mnc="260",
                        dbm=-95,
                        rsrp=-95,
                        rsrq=-11,
                        sinr=18,
                    )
                ],
                carrierName="T-Mobile",
                networkTypeName="NR",
                overrideNetworkType="NR_SA",
            )
        ],
        "note": "2606.55 MHz read as n38 by the modem — exercises the n41 correction.",
    },
    "T-Mobile n71 SA (band unknown)": {
        "sims": [
            _sim(
                [
                    _cell(
                        "NR",
                        cellId="4314132792",
                        pci=984,
                        arfcn=126270,
                        bands=[],  # -1 in the field; the channel names n71
                        mcc="310",
                        mnc="260",
                        dbm=-97,
                    )
                ],
                carrierName="T-Mobile",
                networkTypeName="NR",
                overrideNetworkType="NR_SA",
            )
        ],
        "note": "No band from the radio — exercises naming the band from the ARFCN.",
    },
    "AT&T 5G NSA (5G+)": {
        "sims": [
            _sim(
                [
                    _cell(
                        "LTE",
                        cellId="7864964",
                        pci=76,
                        arfcn=9820,
                        bands=[30],
                        mcc="310",
                        mnc="410",
                        dbm=-104,
                    ),
                    _cell(
                        "NR",
                        cellId="12590807089",
                        pci=512,
                        arfcn=636666,
                        bands=[77],
                        mcc="310",
                        mnc="410",
                        dbm=-98,
                    ),
                ],
                carrierName="AT&T",
                isDefault=True,
                networkTypeName="LTE",
                overrideNetworkType="NR_ADVANCED",
            )
        ],
        "note": "LTE anchor plus an NR leg, NR Advanced — the 5G+ badge path.",
    },
    "Anterix B106 LTE-M": {
        "sims": [
            _sim(
                [
                    _cell(
                        "LTE",
                        cellId="62735294",  # eNB 195007, sector 11
                        pci=61,
                        arfcn=3580,
                        bands=[8],
                        mcc="313",
                        mnc="700",
                        dbm=-103,
                    )
                ],
                carrierName="Ameren",
                networkTypeName="LTE",
            )
        ],
        "note": "Band 8 raster; with the Anterix B106 switch on, the phone reads B106.",
    },
    "Dual SIM (T-Mobile + Verizon)": {
        "sims": [
            _sim(
                [
                    _cell(
                        "NR",
                        cellId="2157115002",
                        pci=532,
                        arfcn=647328,
                        bands=[77],
                        mcc="311",
                        mnc="480",
                        dbm=-108,
                    )
                ],
                carrierName="Verizon",
                slotIndex=0,
                subscriptionId=1,
                isDefault=True,
                networkTypeName="NR",
                overrideNetworkType="NR_SA",
            ),
            _sim(
                [
                    _cell(
                        "LTE",
                        cellId="2985284",
                        pci=44,
                        arfcn=8665,
                        bands=[25],
                        mcc="310",
                        mnc="260",
                        dbm=-112,
                    )
                ],
                carrierName="T-Mobile",
                slotIndex=1,
                subscriptionId=2,
                isDefault=False,
                networkTypeName="LTE",
            ),
        ],
        "note": "Two SIMs, two networks — the dual-SIM layout on one peer.",
    },
}


# -------------------------------------------------------------------------
# Custom source: every field set by hand
# -------------------------------------------------------------------------

CUSTOM_SCENARIO = "Custom — pick every field"


# The ceiling for NR_SA carrier aggregation; NR_NSA is one leg by definition.
MAX_NR_CARRIERS = 5

# How many extra LTE carriers the source will aggregate under the anchor. Real
# phones carry two or three at once; the ceiling keeps the editor a row per
# layer rather than a table.
MAX_LTE_LAYERS = 4


def lte_mhz(earfcn: int | None, band: int | None) -> float | None:
    """Downlink centre frequency of an LTE carrier."""
    if not earfcn or not band:
        return None
    plan = LTE_BANDS.get(band)
    if plan is None:
        return None
    return plan["dlLow"] + 0.1 * (earfcn - plan["first"])


def lte_earfcn(mhz: float | None, band: int | None) -> int | None:
    """The EARFCN for a downlink frequency, in that band's own raster."""
    if not mhz or not band:
        return None
    plan = LTE_BANDS.get(band)
    if plan is None:
        return None
    return round(plan["first"] + (mhz - plan["dlLow"]) / 0.1)


def nr_arfcn(mhz: float | None) -> int | None:
    """The NR-ARFCN for a downlink frequency."""
    if not mhz or mhz <= 0:
        return None
    if mhz < 3000:
        return round(mhz / 0.005)
    if mhz < 24250.08:
        return round(600000 + (mhz - 3000) / 0.015)
    return round(2016667 + (mhz - 24250.08) / 0.06)


def frequency_of(tech: str, band: int | None, channel: int | None) -> float | None:
    """MHz for a channel, or None when this band has no known mapping."""
    return nr_mhz(channel) if tech == "NR" else lte_mhz(channel, band)


def channel_of(tech: str, band: int | None, mhz: float | None) -> int | None:
    """The channel for a frequency, or None when it cannot be worked out."""
    return nr_arfcn(mhz) if tech == "NR" else lte_earfcn(mhz, band)


def max_nr_carriers(config: dict) -> int:
    """How many NR legs the override allows.

    NR_NSA is a single secondary carrier attached to an LTE anchor, so one.
    NR_SA can aggregate up to five. With no override stated the anchor decides:
    an LTE anchor means NSA, and no anchor at all means SA.
    """
    override = config.get("override")
    if override == "NR_SA":
        return MAX_NR_CARRIERS
    if override == "NR_NSA":
        return 1
    # NR_ADVANCED, and anything unset: the anchor that is actually serving
    # decides, so an anchor switched off leaves the source free to aggregate.
    return 1 if anchor_band(config) is not None else MAX_NR_CARRIERS


# The override list the editor offers, and the platform value each one sends.
#
# `NR_ADVANCED` is one value on the wire — the phone cannot tell you whether it
# is holding an NSA pair or a standalone carrier — so the two entries here send
# the same thing and differ in what they set up: the NSA flavour wants an LTE
# anchor and one NR leg, the SA flavour drops the anchor and opens the source to
# five aggregated carriers.
OVERRIDE_CHOICES: list[tuple[str, str]] = [
    ("NONE", "NONE"),
    ("LTE_CA", "LTE_CA"),
    ("LTE_ADVANCED_PRO", "LTE_ADVANCED_PRO"),
    ("NR_NSA", "NR_NSA"),
    ("NR_SA", "NR_SA"),
    ("NR_ADVANCED (NSA)", "NR_ADVANCED"),
    ("NR_ADVANCED (SA)", "NR_ADVANCED"),
]

# The overrides that describe an LTE-only connection. The phone has no NR cell
# at all in these states, so nothing NR is served — otherwise the app would
# correctly report 5G off the attached cell and the aggregation label would
# never be reachable. The NR rows are kept in the source so switching back to an
# NR override restores them.
LTE_ONLY_OVERRIDES = {"LTE_CA", "LTE_ADVANCED_PRO"}


def override_label(config: dict) -> str:
    """The editor entry that describes this source."""
    override = str(config.get("override") or "NONE")
    if override == "NR_ADVANCED":
        return "NR_ADVANCED (NSA)" if anchor_band(config) is not None else "NR_ADVANCED (SA)"
    return override


def override_wire(label: str) -> str:
    """The platform value for an editor entry."""
    return dict(OVERRIDE_CHOICES).get(label, "NONE")


# gNB ID lengths by operator. The phone splits the 36-bit NCI at 26 bits for
# AT&T, 24 for T-Mobile and 22 for everyone else, so the test source has to
# pack its gNB and sector the same way — otherwise the number read back on the
# phone is not the number that was typed.
ATT_PLMNS = {"310410", "310150", "310170", "310380", "313100"}


def gnb_bits(plmn: str) -> int:
    """Length of the gNB ID inside the NCI for this operator."""
    if plmn in ATT_PLMNS:
        return 26
    if plmn in TMOBILE_PLMNS:
        return 24
    return 22


def lte_cell_id(enb: int | None, sector: int | None) -> int | None:
    """28-bit ECI from eNB (top 20 bits) and sector (bottom 8)."""
    if enb is None:
        return None
    return ((enb & 0xFFFFF) << 8) | ((sector or 0) & 0xFF)


def pci_for(tech: str, value: int | None, fallback: int) -> int:
    """The PCI a cell of this technology can actually carry.

    LTE has 504 physical cell identities (0-503) and NR has 1008 (0-1007). A
    number outside the range is one no radio can report, so it is clamped here
    rather than served and quietly decoded wrong by the phone.
    """
    if value is None:
        return fallback
    limit = 1007 if tech == "NR" else 503
    return max(0, min(limit, value))


def nr_cell_id(gnb: int | None, sector: int | None, plmn: str) -> int | None:
    """36-bit NCI from gNB and sector, on this operator's bit split."""
    if gnb is None:
        return None
    bits = gnb_bits(plmn)
    return ((gnb & ((1 << bits) - 1)) << (36 - bits)) | (
        (sector or 0) & ((1 << (36 - bits)) - 1)
    )


# Defaults to an AT&T NSA pair, so the editor opens on a working layout. The
# identity defaults decode as eNB 30722 / sector 36 and gNB 12295710 / sector
# 49 — real, plausible sites rather than made-up round numbers.
# The port the desktop serves on, and the one it scans for. This is the same
# number the phone app uses (`LanSharingServer.sharePort`), so either side can
# find the other by knocking on it across the subnet rather than being told an
# address by hand.
DEFAULT_PORT = 41729

# How many neighbour cells the custom source will report. A real scan on a
# Samsung hands over five or six; the ceiling is here so the list stays a list.
MAX_NEIGHBOURS = 12

DEFAULT_CUSTOM: dict = {
    "plmn": "310410",
    "override": "NR_NSA",
    "lte": {
        "band": 30, "arfcn": 9820, "dbm": -104,
        "enb": 30722, "sector": 36, "pci": 76, "tac": 12345,
        "enabled": True,
    },
    # Extra LTE carriers aggregated under the anchor: a band 29 supplemental
    # downlink, or another band as a CA layer. Empty by default — the anchor
    # alone is the common case.
    "lte_layers": [],
    "nr": [
        {
            "band": 5, "arfcn": 176300, "dbm": -98,
            "gnb": 12295710, "sector": 49, "pci": 512, "tac": 12345,
            "enabled": True,
        }
    ],
    # Measured but not served. A modem reports these with no PLMN, no cell
    # identity and no TAC, so they arrive the way a phone really hears them.
    "neighbours": {"count": 0, "band": 2, "enabled": True},
}


def _int_or(value: object, fallback: int | None = None) -> int | None:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return fallback


def _float_or(value: object, fallback: float | None = None) -> float | None:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return fallback


def _band_number(text: object) -> int | None:
    """`n5`, `B30`, `band 5` and `5` all mean band 5."""
    cleaned = str(text or "").strip()
    for prefix in ("band", "Band", "BAND", "B", "b", "N", "n"):
        if cleaned.startswith(prefix):
            cleaned = cleaned[len(prefix):]
            break
    return _int_or(cleaned.strip())


def carrier_choices() -> list[tuple[str, str]]:
    """(label, mccmnc) read from the app's own operator list.

    The phone replaces the served `carrierName` with the brand its GitHub list
    gives for the PLMN, so the desktop offers the same PLMNs rather than a
    second list that could drift.
    """
    choices: list[tuple[str, str]] = []
    try:
        raw = json.loads(_data_file("plmns.json").read_text(encoding="utf-8"))
        for entry in raw:
            mcc = str(entry.get("mcc") or "")
            mnc = str(entry.get("mnc") or "")
            if not mcc or not mnc:
                continue
            brand = str(entry.get("brand") or f"{mcc}-{mnc}")
            choices.append((f"{brand} ({mcc}-{mnc})", mcc + mnc))
    except (OSError, json.JSONDecodeError, TypeError, AttributeError):
        choices = []
    if not choices:
        choices = [
            ("AT&T (310-410)", "310410"),
            ("T-Mobile (310-260)", "310260"),
            ("Verizon (311-480)", "311480"),
            ("FirstNet (313-100)", "313100"),
            ("Ameren (313-700)", "313700"),
            ("T-Satellite (310-830)", "310830"),
            ("T-911 (312-190)", "312190"),
        ]
    return choices


def _merge_row(raw: object, default: dict) -> dict:
    """One carrier row, with anything missing filled from the defaults."""
    row = dict(default)
    if not isinstance(raw, dict):
        return row
    for key, fallback in default.items():
        if key == "enabled":
            row["enabled"] = raw.get(key) is not False
        elif key in raw:
            # A cleared box stays cleared: the identity is then left out and
            # the payload falls back to a fixed, valid one.
            row[key] = _int_or(raw.get(key))
        else:
            row[key] = fallback
    return row


def merge_custom(raw: object) -> dict:
    """A saved custom source, filled out against the defaults."""
    config = json.loads(json.dumps(DEFAULT_CUSTOM))
    if not isinstance(raw, dict):
        return config
    plmn = raw.get("plmn")
    if isinstance(plmn, str) and len(plmn) >= 5:
        config["plmn"] = plmn
    if raw.get("override") in ({"NONE", "NR_NSA", "NR_SA", "NR_ADVANCED"} | LTE_ONLY_OVERRIDES):
        config["override"] = raw["override"]
    if isinstance(raw.get("lte"), dict):
        config["lte"] = _merge_row(raw["lte"], DEFAULT_CUSTOM["lte"])
    layers = raw.get("lte_layers")
    if isinstance(layers, list):
        # Empty is a real choice — no aggregation — so it is restored as empty
        # rather than refilled from the defaults.
        config["lte_layers"] = [
            _merge_row(entry, DEFAULT_CUSTOM["lte"])
            for entry in layers[:MAX_LTE_LAYERS]
            if isinstance(entry, dict)
        ]
    carriers = raw.get("nr")
    if isinstance(carriers, list):
        # An empty list is a real choice — every NR leg switched off — so it is
        # restored as empty rather than quietly refilled from the defaults.
        config["nr"] = [
            _merge_row(entry, DEFAULT_CUSTOM["nr"][0])
            for entry in carriers[:MAX_NR_CARRIERS]
            if isinstance(entry, dict)
        ]
    neighbours = raw.get("neighbours")
    if isinstance(neighbours, dict):
        merged = dict(DEFAULT_CUSTOM["neighbours"])
        count = _int_or(neighbours.get("count"))
        band = _int_or(neighbours.get("band"))
        if count is not None:
            merged["count"] = max(0, min(MAX_NEIGHBOURS, count))
        if band:
            merged["band"] = band
        if neighbours.get("enabled") is False:
            merged["enabled"] = False
        config["neighbours"] = merged
    # A hand-edited file can still ask for more legs than the override allows.
    config["nr"] = config["nr"][: max_nr_carriers(config)]
    return config


# FR2 — the millimetre-wave bands, 24 GHz and up. A modem cannot sit on one
# standalone: mmWave is only ever a secondary component of NR CA, so a single
# FR2 carrier is not a state a phone can be in.
FR2_BANDS = {257, 258, 259, 260, 261, 262}


def anchor_band(config: dict) -> int | None:
    """The LTE anchor band actually being served, or None."""
    lte = _merge_row(config.get("lte"), DEFAULT_CUSTOM["lte"])
    if lte.get("enabled") is False:
        return None
    return _int_or(lte.get("band"))


def served_nr_bands(config: dict) -> list[dict]:
    """The NR rows that reach the payload, in order.

    One rule is applied here rather than in the editor so the preview and the
    summary can never disagree with what is served: with no LTE anchor a lone
    FR2 carrier is dropped, because mmWave SA without CA is not a state any
    modem reports. Two or more NR carriers is CA, where FR2 belongs.
    """
    rows = [
        _merge_row(carrier, DEFAULT_CUSTOM["nr"][0])
        for carrier in (config.get("nr") or [])
    ]
    if str(config.get("override") or "") in LTE_ONLY_OVERRIDES:
        return []
    rows = [
        c for c in rows if c.get("enabled") is not False and _int_or(c.get("band"))
    ][: max_nr_carriers(config)]
    if anchor_band(config) is None and len(rows) == 1:
        if _int_or(rows[0].get("band")) in FR2_BANDS:
            return []
    return rows


def served_lte_layers(config: dict) -> list[dict]:
    """The extra LTE carriers that reach the payload, in order.

    A layer is aggregated under the anchor, so it needs one to aggregate under:
    with the anchor switched off the layers are held back rather than served as
    a second primary the phone would take for the serving cell.
    """
    if anchor_band(config) is None:
        return []
    layers = [
        _merge_row(layer, DEFAULT_CUSTOM["lte"])
        for layer in (config.get("lte_layers") or [])
    ]
    return [
        layer for layer in layers
        if layer.get("enabled") is not False and _int_or(layer.get("band"))
    ][:MAX_LTE_LAYERS]


def lte_layer_cells(config: dict, plmn: str) -> list[dict]:
    """The extra LTE carriers, as a modem hands them over.

    A band 29 layer is a supplemental downlink and arrives the way the radio
    really reports one: no cell identity, no TAC, and no PLMN until it is moving
    data. Any other band is a carrier-aggregation layer with its own eNB and
    sector, which is what tells it apart from the anchor on the phone.
    """
    mcc, mnc = plmn[:3], plmn[3:]
    cells: list[dict] = []
    for layer in served_lte_layers(config):
        band = _int_or(layer.get("band"))
        if not band:
            continue
        supplemental = band == 29
        cells.append(
            _cell(
                "LTE",
                registered=not supplemental,
                cellId=(
                    None if supplemental
                    else str(
                        lte_cell_id(
                            _int_or(layer.get("enb")), _int_or(layer.get("sector"))
                        )
                        or 7864964
                    )
                ),
                tac=None if supplemental else _int_or(layer.get("tac"), 12345),
                pci=pci_for("LTE", _int_or(layer.get("pci")), 200),
                arfcn=_int_or(layer.get("arfcn")) or LTE_CHANNELS.get(band),
                bands=[band],
                mcc=None if supplemental else mcc,
                mnc=None if supplemental else mnc,
                dbm=_int_or(layer.get("dbm"), -104),
            )
        )
    return cells


def custom_layout(config: dict) -> str:
    """The carriers the payload actually carries, in order.

    Built from [served_nr_bands], not from the editor's rows, so the read-back
    cannot promise a carrier that was dropped — an LTE-only override leaves the
    NR rows in the source for next time but sends none of them, and the summary
    says so. The one exception is a lone FR2 carrier, which is listed and marked
    because the drop is a fact worth explaining rather than hiding.
    """
    parts: list[str] = []
    lte_band = anchor_band(config)
    if lte_band:
        parts.append(f"B{lte_band} anchor")
    for layer in served_lte_layers(config):
        band = _int_or(layer.get("band"))
        if band:
            parts.append(f"B{band} SDL" if band == 29 else f"B{band} CA")
    for carrier in served_nr_bands(config):
        band = _int_or(carrier.get("band"))
        if band:
            parts.append(f"n{band}")
    if not served_nr_bands(config) and anchor_band(config) is None:
        enabled = [
            c for c in config.get("nr") or []
            if c.get("enabled") is not False and _int_or(c.get("band"))
        ]
        for carrier in enabled:
            parts.append(f"n{_int_or(carrier.get('band'))} (mmWave, not sent)")
    neigh = config.get("neighbours") or {}
    if neigh.get("enabled") is not False:
        count = _int_or(neigh.get("count"), 0) or 0
        if count:
            parts.append(f"{count} neighbours")
    return " + ".join(parts) if parts else "no carriers"


def neighbour_cells(config: dict, lte: dict) -> list[dict]:
    """Measured-but-not-serving LTE cells, the way a modem reports them.

    No PLMN, no cell identity and no TAC: Android fills those in only for the
    registered cell, so a neighbour arrives as a PCI, a band and a level. That
    is the shape the app's "hides neighbour cell IDs" note describes, and the
    only shape the neighbour card has to render.
    """
    cfg = config.get("neighbours") or {}
    if cfg.get("enabled") is False:
        return []
    count = max(0, min(MAX_NEIGHBOURS, _int_or(cfg.get("count"), 0) or 0))
    if not count:
        return []
    band = _int_or(cfg.get("band"), 2) or 2
    anchor_pci = _int_or(lte.get("pci"), 76) or 76
    anchor_dbm = _int_or(lte.get("dbm"), -100) or -100
    return [
        _cell(
            "LTE",
            registered=False,
            cellId=None,
            tac=None,
            pci=(anchor_pci + 40 * (index + 1)) % 504,
            arfcn=LTE_CHANNELS.get(band),
            bands=[band],
            mcc=None,
            mnc=None,
            dbm=anchor_dbm - 6 - 4 * index,
        )
        for index in range(count)
    ]


def nsa_mode(config: dict) -> bool:
    """True when the NR legs hang off an LTE anchor rather than standing alone.

    That is the case the radios hide the NR identity in: with NSA up, Samsung
    hands over the PCI, band and channel of the 5G leg but not the NCI, so
    there is no gNB and no sector to send — the phone derives an estimated gNB
    from the LTE eNB instead.
    """
    if str(config.get("override") or "") == "NR_SA":
        return False
    if anchor_band(config) is None:
        return False
    return bool(served_nr_bands(config))


def build_custom(config: dict) -> dict:
    """A snapshot assembled carrier by carrier.

    Nothing here is a preset: the anchor and every NR carrier come from the
    fields, so `B30 + n5`, `n5` on its own, and `B2 + n5 + n77` (two NR
    carriers, i.e. carrier aggregation) are all the same code path.
    """
    plmn = str(config.get("plmn") or "310410")
    mcc, mnc = plmn[:3], plmn[3:]
    brand = next(
        (label.split(" (")[0] for label, code in carrier_choices() if code == plmn),
        plmn,
    )

    lte = _merge_row(config.get("lte"), DEFAULT_CUSTOM["lte"])
    lte_band = anchor_band(config)
    nr_rows = served_nr_bands(config)
    # Under an LTE anchor the 5G leg arrives without its identity — no NCI, so
    # no sector, and no TAC either. Sending one would hide the app's estimate
    # path behind a number no phone would report.
    secondary = nsa_mode(config)

    cells: list[dict] = []
    if lte_band:
        cells.append(
            _cell(
                "LTE",
                cellId=str(
                    lte_cell_id(_int_or(lte.get("enb")),
                                _int_or(lte.get("sector")))
                    or 7864964  # eNB 30722, sector 36
                ),
                pci=pci_for("LTE", _int_or(lte.get("pci")), 76),
                tac=_int_or(lte.get("tac"), 12345),
                arfcn=_int_or(lte.get("arfcn")) or LTE_CHANNELS.get(lte_band),
                bands=[lte_band],
                mcc=mcc,
                mnc=mnc,
                dbm=_int_or(lte.get("dbm"), -100),
            )
        )

    for index, carrier in enumerate(nr_rows):
        band = _int_or(carrier.get("band"))
        if not band:
            continue
        cell_id = None if secondary else nr_cell_id(
            _int_or(carrier.get("gnb")), _int_or(carrier.get("sector")), plmn
        )
        cells.append(
            _cell(
                "NR",
                cellId=(
                    None if secondary
                    else str(cell_id if cell_id is not None
                             else 12590807089 + index)
                ),
                pci=pci_for("NR", _int_or(carrier.get("pci")), 512 + index),
                tac=None if secondary else _int_or(carrier.get("tac"), 12345),
                arfcn=_int_or(carrier.get("arfcn")) or NR_CHANNELS.get(band),
                bands=[band],
                mcc=mcc,
                mnc=mnc,
                dbm=_int_or(carrier.get("dbm"), -100),
            )
        )

    cells.extend(lte_layer_cells(config, plmn))
    cells.extend(neighbour_cells(config, lte))

    override = str(
        config.get("override")
        or ("NR_NSA" if lte_band else "NR_SA")
    )  # the platform value; the NSA/SA split is carried by the cells
    sim = _sim(
        cells,
        carrierName=brand,
        networkTypeName="LTE" if lte_band else "NR",
        overrideNetworkType=override,
    )
    return {"sims": [sim]}


class SpoofServer:
    """Answers `/snapshot` with a scenario, jittered so the peer sees updates."""

    def __init__(self) -> None:
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._scenario = "T-Mobile n41 SA"
        self._custom: dict = merge_custom(None)
        self._port = DEFAULT_PORT
        self._jitter = 0
        self._requests = 0

    # -- lifecycle --------------------------------------------------------
    def start(self, port: int, scenario: str) -> bool:
        self.stop()
        self._scenario = scenario
        self._port = port

        handler = self._handler()
        try:
            self._server = ThreadingHTTPServer(("0.0.0.0", port), handler)
        except OSError as error:
            self._server = None
            raise error
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return True

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
            self._thread = None

    @property
    def running(self) -> bool:
        return self._server is not None

    @property
    def requests(self) -> int:
        return self._requests

    def set_scenario(self, name: str) -> None:
        self._scenario = name

    def set_custom(self, config: dict) -> None:
        """Replace the field-by-field source (the caller passes a fresh dict)."""
        self._custom = config

    def _source(self) -> dict:
        """The scenario to serve: a preset, or the hand-built one."""
        if self._scenario == CUSTOM_SCENARIO:
            return build_custom(self._custom)
        return SCENARIOS[self._scenario]

    @property
    def scenario(self) -> str:
        return self._scenario

    # -- payload ----------------------------------------------------------
    def payload(self) -> dict:
        with self._lock:
            self._jitter = (self._jitter + 1) % 7
        drift = [-2, -1, 0, 1, 2, 1, 0][self._jitter]
        source = json.loads(json.dumps(self._source()))
        for sim in source["sims"]:
            for cell in sim["cells"]:
                if isinstance(cell.get("dbm"), int):
                    cell["dbm"] += drift
                    cell["level"] = min(4, max(0, round((cell["dbm"] + 120) / 10)))
        source.update(
            {
                "permissionGranted": True,
                "locationEnabled": True,
                "timestamp": int(time.time() * 1000),
                "deviceModel": "Sector Scout Desktop (test source)",
                "cellCount": sum(len(s["cells"]) for s in source["sims"]),
            }
        )
        return source

    def _handler(self):
        server = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):  # keep the console quiet
                pass

            def _send(self, code: int, body: bytes, content_type: str) -> None:
                self.send_response(code)
                self.send_header("Content-Type", content_type)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler name
                path = self.path.split("?")[0]
                if path in ("/", "/snapshot", "/api/snapshot"):
                    server._requests += 1
                    body = json.dumps(server.payload()).encode()
                    self._send(200, body, "application/json; charset=utf-8")
                elif path == "/health":
                    body = json.dumps(
                        {
                            "ok": True,
                            "port": server._port,
                            "dashboard": False,
                            "scenario": server._scenario,
                        }
                    ).encode()
                    self._send(200, body, "application/json; charset=utf-8")
                else:
                    body = json.dumps(
                        {
                            "error": "Not found",
                            "paths": ["/", "/snapshot", "/api/snapshot", "/health"],
                        }
                    ).encode()
                    self._send(404, body, "application/json; charset=utf-8")

        return Handler


# -------------------------------------------------------------------------
# Phones: one poller for every configured peer
# -------------------------------------------------------------------------

@dataclass
class Phone:
    """A phone being watched: one over Wi-Fi, or one over Bluetooth."""

    url: str = ""
    name: str = ""
    # "wifi" polls /snapshot over HTTP; "ble" reads the GATT share.
    transport: str = "wifi"
    address: str = ""
    # The BLEDevice a scan found, kept in memory only so a read does not have to
    # rediscover the phone on every poll.
    device: object | None = None
    # What the Bluetooth poll thread is doing right now, so the card is not a
    # blank "waiting" while a GATT read is in flight.
    status: str = ""
    # When the last Bluetooth attempt started, so a card that is still empty
    # says how long it has been trying instead of looking frozen.
    attempted: float = 0.0
    # A soft message for a read that did not finish, as opposed to an error.
    note: str = ""
    # How many reads have failed in a row, so one bad discovery is not treated
    # as the share having stopped.
    failures: int = 0
    snapshot: dict | None = None
    error: str | None = None
    updated: float = 0.0

    @property
    def label(self) -> str:
        if self.name:
            return self.name
        if self.transport == "ble":
            return self.address
        return self.url.replace("http://", "")


def local_ip() -> str | None:
    """This machine's address on the LAN, without sending a packet.

    A connected UDP socket only asks the routing table which interface would be
    used, so this costs nothing and works with no network reachability.
    """
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("8.8.8.8", 80))
            return probe.getsockname()[0]
        finally:
            probe.close()
    except OSError:
        return None


def scan_lan(port: int = DEFAULT_PORT, timeout: float = 0.35) -> list[str]:
    """Hosts on this subnet answering the share port with the app's JSON.

    Only a fixed port makes this possible at all — with an ephemeral one there
    would be nothing to knock on. `/health` is read rather than the socket just
    being probed, so a printer or a dev server that happens to sit on the port
    is not reported as a phone: the answer has to be this app's JSON.
    """
    ip = local_ip()
    if not ip:
        return []
    prefix = ip.rsplit(".", 1)[0]
    found: list[str] = []
    lock = threading.Lock()

    def probe(host: str) -> None:
        try:
            with socket.create_connection((host, port), timeout) as sock:
                sock.settimeout(timeout)
                sock.sendall(
                    f"GET /health HTTP/1.0\r\nHost: {host}\r\n\r\n".encode()
                )
                body = sock.recv(2048)
        except OSError:
            return
        if b'"ok"' in body and b"true" in body:
            with lock:
                found.append(f"{host}:{port}")

    threads: list[threading.Thread] = []
    for host in range(1, 255):
        if f"{prefix}.{host}" == ip:
            continue
        threads.append(
            threading.Thread(target=probe, args=(f"{prefix}.{host}",), daemon=True)
        )
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return sorted(found, key=lambda item: int(item.split(".")[3].split(":")[0]))


def normalise_url(text: str) -> str:
    """Accepts `10.1.1.47`, `10.1.1.47:37534`, or a full http URL."""
    text = text.strip()
    if not text:
        raise ValueError("Enter a phone address first.")
    if "://" not in text:
        text = "http://" + text
    from urllib.parse import urlsplit

    parts = urlsplit(text)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("That does not look like an address.")
    port = parts.port or 80
    return f"{parts.scheme}://{parts.hostname}:{port}"


def fetch_phone(phone: Phone) -> None:
    if phone.transport == "ble":
        try:
            phone.snapshot = _ble_read(phone)
            phone.error = None
            phone.note = ""
            phone.failures = 0
            phone.updated = time.time()
        except BleStalled:
            phone.failures += 1
            # Slow is not broken: keep any reading already shown and say that
            # another attempt is coming.
            phone.note = "The phone did not answer in time — retrying"
        except BleNotServing as error:
            phone.failures += 1
            if phone.failures >= BLE_NOT_SERVING_ALERTS:
                # Three in a row is no longer transient: say what to do, not
                # just that another attempt is coming.
                phone.error = (
                    f"{error} — if it keeps happening, switch Bluetooth "
                    "sharing off and on in the app"
                )
            else:
                phone.note = f"{error} (attempt {phone.failures})"
        except BleUnavailable as error:
            phone.failures += 1
            phone.error = str(error)
        except Exception as error:  # noqa: BLE001 - shown on the card
            phone.failures += 1
            phone.snapshot = None
            phone.error = f"Bluetooth read failed: {error}"
        return

    url = phone.url.rstrip("/") + "/snapshot"
    try:
        with urllib.request.urlopen(url, timeout=4) as response:
            raw = response.read().decode("utf-8", "replace")
        phone.snapshot = json.loads(raw)
        phone.error = None
        phone.updated = time.time()
    except urllib.error.HTTPError as error:
        phone.error = f"HTTP {error.code} from that address"
    except (urllib.error.URLError, TimeoutError, socket.timeout):
        phone.snapshot = None
        phone.error = "Not reachable — sharing on, same Wi-Fi?"
    except json.JSONDecodeError:
        phone.snapshot = None
        phone.error = "That address did not return cell JSON"


# --- Bluetooth LE share ----------------------------------------------------
# The app's Bluetooth mode advertises one GATT service and returns the same JSON
# `/snapshot` serves, in chunks: every read answers `[index, total, ...bytes]`.
# These are BleShare.kt's UUIDs, so the two ends cannot drift apart.
BLE_SERVICE = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d00"
BLE_DATA = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d01"
BLE_RESET = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d02"
BLE_SCAN_SECONDS = 6.0
# A read that never finishes must not wedge the polling thread.
BLE_READ_LIMIT = 96
# Android drops the GATT link when the screen has been off for a while, and
# Windows sometimes answers the first service discovery with an empty database,
# so a read is attempted a few times before the card is told it failed.
BLE_ATTEMPTS = 2
BLE_RETRY_PAUSE = 0.5
# Whole-attempt ceiling, including service discovery. Deliberately short: a
# failed read is retried on the next poll anyway, so waiting longer per attempt
# only parks the card on "Reading…" for nothing.
BLE_READ_SECONDS = 12.0
# Hard ceiling for the whole read, measured outside asyncio: a WinRT connect
# that never completes can leave the event loop unable to fire its own timeout,
# and the poll thread must not be lost to that.
BLE_HARD_LIMIT = 30.0
# Only look the phone up again once the reading in hand is old enough that the
# address really may have moved: a scan costs seconds, and one failed poll on a
# phone that answered a moment ago is worth a plain retry instead.
BLE_RESOLVE_AFTER = 20.0
# Per-chunk ceiling: a stalled read would otherwise sit on the link forever.
BLE_CHUNK_SECONDS = 6.0
# A kept link is dropped after this long without a read, so a phone that was
# put away is not left with a stale connection.
BLE_LINK_IDLE_SECONDS = 120.0
# One empty service discovery is not proof that sharing stopped; only a run of
# them is worth reddening the card for.
BLE_NOT_SERVING_ALERTS = 3


class BleUnavailable(RuntimeError):
    """Bluetooth cannot be used here, with the reason."""


class BleNotServing(BleUnavailable):
    """The phone advertises the share but does not expose its GATT service.

    Android keeps an advertisement in the Bluetooth controller for a while
    after the app's GATT server has closed, so a phone that was restarted, or
    whose share was switched, still looks present until Bluetooth is toggled.
    Retrying the same link cannot fix that, so the read fails immediately and
    says what to do instead of burning a minute on retries.
    """


def bleak_available() -> bool:
    """True when the `bleak` package is installed."""
    return importlib.util.find_spec("bleak") is not None


def scan_ble(timeout: float = BLE_SCAN_SECONDS) -> list[dict]:
    """Phones advertising the app's Bluetooth share, strongest first."""
    if not bleak_available():
        raise BleUnavailable(
            "Bluetooth scanning needs the bleak package: pip install bleak"
        )
    import asyncio

    from bleak import BleakScanner

    return asyncio.run(_scan_ble(timeout, BleakScanner))


async def _scan_ble(timeout: float, scanner) -> list[dict]:
    found = await scanner.discover(timeout=timeout, return_adv=True)
    phones: list[dict] = []
    for address, pair in found.items():
        device, adv = pair
        uuids = {str(uuid).lower() for uuid in (adv.service_uuids or [])}
        # Only this app advertises the service, so the watches, beacons and
        # appliances around it are not candidates.
        if BLE_SERVICE not in uuids:
            continue
        phones.append(
            {
                "address": address,
                "name": (device.name or adv.local_name or "").strip(),
                "rssi": adv.rssi,
                # Kept out of the saved config; used to skip a rediscovery.
                "device": device,
            }
        )
    phones.sort(key=lambda row: row["rssi"], reverse=True)
    return phones


def ble_snapshot(address: str, device: object | None = None) -> dict:
    """One phone's reading over GATT, as the same JSON `/snapshot` returns.

    [device] is the BLEDevice a scan already found; using it saves a second
    discovery per read, which on Windows is most of the wait.
    """
    if not bleak_available():
        raise BleUnavailable(
            "Bluetooth reading needs the bleak package: pip install bleak"
        )
    import asyncio

    from bleak import BleakClient

    reason = "the phone did not answer"
    for attempt in range(BLE_ATTEMPTS):
        try:
            return _ble_call(
                _ble_kept(address, device, BleakClient), BLE_READ_SECONDS
            )
        except BleNotServing:
            # The link is gone or half-built; the next attempt starts a new one,
            # and a phone that really stopped serving keeps failing there.
            _ble_close(address)
            if attempt == BLE_ATTEMPTS - 1:
                raise
            reason = "the phone returned no share service"
        except BleUnavailable:
            raise
        except Exception as error:  # noqa: BLE001 - retried, then reported
            _ble_close(address)
            reason = _ble_reason(error)
        if attempt < BLE_ATTEMPTS - 1:
            time.sleep(BLE_RETRY_PAUSE)
    raise RuntimeError(reason)


class BleStalled(RuntimeError):
    """A read outlived its deadline and was abandoned; the next poll retries."""


def _ble_read_with_deadline(address: str, device: object | None = None) -> dict:
    """`ble_snapshot` with a deadline that holds even when asyncio's does not.

    The read runs in its own thread and is abandoned on overrun, so a Windows
    BLE connect that never completes costs one attempt rather than the poll
    thread. The abandoned thread ends by itself when Windows gives up.
    """
    outcome: dict[str, object] = {}

    def work() -> None:
        try:
            outcome["value"] = ble_snapshot(address, device)
        except BaseException as error:  # noqa: BLE001 - handed to the caller
            outcome["error"] = error

    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    worker.join(BLE_HARD_LIMIT)
    if worker.is_alive():
        raise BleStalled(f"no answer in {int(BLE_HARD_LIMIT)}s")
    if "error" in outcome:
        raise outcome["error"]  # type: ignore[misc]
    return outcome["value"]  # type: ignore[return-value]


def _find_ble_phone(name: str) -> dict | None:
    """Look for the phone advertising the share right now."""
    try:
        found = scan_ble()
    except Exception:  # noqa: BLE001 - no fresh scan just means no refresh
        return None
    if not found:
        return None
    if name:
        same = [row for row in found if row["name"] == name]
        if same:
            return same[0]
    # Without a name to go on, only a lone candidate is trusted: reading a
    # different phone under this card would be worse than not reading at all.
    return found[0] if len(found) == 1 else None


def _ble_read(phone: Phone) -> dict:
    """A reading over Bluetooth, refreshing the address if it has gone stale.

    Samsung rotates the advertising address, and every restart of the share
    hands out a new one, so a saved address can point at a phone that is still
    on the desk but no longer reachable there. A failed read therefore looks the
    phone up again and retries once on the address it is using now.
    """
    try:
        return _ble_read_with_deadline(phone.address, phone.device)
    except BleUnavailable:
        # Missing bleak, or a phone that is not serving the share: another scan
        # cannot change either answer.
        raise
    except Exception as first:  # noqa: BLE001 - retried on a fresh address
        if time.time() - phone.updated < BLE_RESOLVE_AFTER:
            raise first
        fresh = _find_ble_phone(phone.name)
        if fresh is None:
            raise first
        phone.address = fresh["address"]
        phone.device = fresh.get("device")
        return _ble_read_with_deadline(phone.address, phone.device)


def _ble_reason(error: Exception) -> str:
    """What to tell the card when a read does not come back."""
    text = str(error)
    if "was not found" in text or "service" in text.lower():
        return (
            "the phone did not expose its share service — is Bluetooth "
            "sharing still on?"
        )
    if isinstance(error, asyncio_timeout_error()):
        return "the phone stopped answering part-way through the reading"
    return text or error.__class__.__name__


def asyncio_timeout_error() -> type[BaseException]:
    import asyncio

    return asyncio.TimeoutError


def _ble_client_kwargs(uncached: bool) -> dict:
    """Ask Windows for a freshly discovered GATT database.

    Windows caches a device's services, so a phone that restarted its GATT
    server can be answered from a stale copy — or from a partly-filled one.
    Alternating between the cached and the live database is what makes a read
    reliable rather than a coin toss.
    """
    if not uncached or sys.platform != "win32":
        return {}
    return {"winrt": {"use_cached_services": False}}


async def _ble_payload(client) -> dict:
    """The whole reading, from a link that is already open."""
    import asyncio

    # A phone whose GATT server has not finished registering, or a Windows
    # discovery that came back empty, shows up here rather than as a silent
    # empty payload. That is usually transient on a phone that is still
    # serving, so the card is told again only after a run of them fails.
    if client.services.get_characteristic(BLE_DATA) is None:
        raise BleNotServing(
            "Connected, but the phone returned no share service — retrying"
        )
    try:
        # Rewind this link's cursor first: the phone advances it per client, so
        # a read that stopped halfway would otherwise resume mid-payload.
        await client.write_gatt_char(BLE_RESET, b"\x00", response=True)
    except Exception:
        # A phone that refuses the reset still serves reads from wherever its
        # cursor is; the index in every chunk puts them back in order.
        pass
    chunks: dict[int, bytes] = {}
    total = 0
    index = 0
    for _ in range(BLE_READ_LIMIT):
        raw = await asyncio.wait_for(
            client.read_gatt_char(BLE_DATA), timeout=BLE_CHUNK_SECONDS
        )
        if not raw or len(raw) < 3:
            break
        index, total = raw[0], raw[1]
        chunks[index] = bytes(raw[2:])
        if len(chunks) >= total:
            break
    payload = b"".join(chunks.get(index, b"") for index in range(total))
    if not payload:
        raise RuntimeError("the phone returned no reading")
    return json.loads(payload.decode("utf-8", "replace"))


async def _read_ble(address: str, client_cls, uncached: bool = False) -> dict:
    """One reading over a link that is opened and closed around it."""
    async with client_cls(
        address, timeout=12.0, **_ble_client_kwargs(uncached)
    ) as client:
        return await _ble_payload(client)


# --- kept Bluetooth links --------------------------------------------------
# A fresh GATT connection per poll is what made a share that was working stop
# answering after a minute: every connect runs a full service discovery, the
# phone only accepts so many, and Windows holds the old links for a while. One
# link per phone is opened once and reused, and dropped only when it fails.
_BLE_LINKS: dict[str, object] = {}
_BLE_LINKS_USED: dict[str, float] = {}
_BLE_LOOP: dict[str, object] = {}
_BLE_LINKS_LOCK = threading.Lock()


def _ble_loop():
    """The one event loop every kept link lives on."""
    import asyncio

    with _BLE_LINKS_LOCK:
        loop = _BLE_LOOP.get("loop")
        if loop is None or loop.is_closed():
            loop = asyncio.new_event_loop()
            threading.Thread(
                target=loop.run_forever, name="ble-loop", daemon=True
            ).start()
            _BLE_LOOP["loop"] = loop
        return loop


def _ble_close(address: str) -> None:
    """Forget a link and disconnect it, without blocking the caller."""
    import asyncio

    _BLE_LINKS_USED.pop(address, None)
    client = _BLE_LINKS.pop(address, None)
    if client is None:
        return

    async def close() -> None:
        try:
            await client.disconnect()
        except Exception:  # noqa: BLE001 - it is already gone
            pass

    try:
        asyncio.run_coroutine_threadsafe(close(), _ble_loop()).result(5)
    except Exception:  # noqa: BLE001 - best effort
        pass


async def _ble_drop_stale() -> None:
    """Close links that have not been read from in a while."""
    now = time.time()
    stale = [
        address for address, used in list(_BLE_LINKS_USED.items())
        if now - used > BLE_LINK_IDLE_SECONDS
    ]
    for address in stale:
        client = _BLE_LINKS.pop(address, None)
        _BLE_LINKS_USED.pop(address, None)
        if client is not None:
            try:
                await client.disconnect()
            except Exception:  # noqa: BLE001 - it is already gone
                pass


async def _ble_kept(address: str, device, client_cls) -> dict:
    """Read over a link kept open between polls, opening one only if it is gone."""
    await _ble_drop_stale()
    client = _BLE_LINKS.get(address)
    if client is None or not client.is_connected:
        target = device if device is not None else address
        client = client_cls(target, timeout=12.0, **_ble_client_kwargs(False))
        await client.connect()
        _BLE_LINKS[address] = client
    try:
        payload = await _ble_payload(client)
    except Exception:
        # A link that failed once is not trusted twice: drop it, so the next
        # poll connects from scratch rather than repeating the same failure.
        _BLE_LINKS.pop(address, None)
        _BLE_LINKS_USED.pop(address, None)
        try:
            await client.disconnect()
        except Exception:  # noqa: BLE001 - it is already gone
            pass
        raise
    _BLE_LINKS_USED[address] = time.time()
    return payload


def _ble_call(coro, timeout: float):
    """Run one coroutine on the shared loop and wait for its result."""
    import asyncio

    try:
        return asyncio.run_coroutine_threadsafe(coro, _ble_loop()).result(timeout)
    except Exception:
        coro.close()
        raise



# -------------------------------------------------------------------------
# UI
# -------------------------------------------------------------------------

def phone_signature(phone: Phone, corrections: bool) -> str:
    """Everything a phone's card is drawn from.

    A card rebuilt for an unchanged reading is the flicker: the whole tree of
    labels is thrown away and made again every two seconds. Comparing this
    signature first means only cards whose content actually moved are rebuilt;
    the reading's age is refreshed separately, so it stays live either way.
    """
    try:
        payload = json.dumps(
            [
                phone.snapshot,
                phone.error,
                phone.status,
                phone.note,
                phone.address,
                phone.url,
                corrections,
            ],
            sort_keys=True,
            default=str,
        )
    except (TypeError, ValueError):
        payload = repr(phone.snapshot)
    return f"{id(phone)}|{payload}"


class CardSlot:
    """One phone's place in the grid, redrawn without ever showing a gap.

    The replacement is built into a frame of its own and packed before the old
    one is destroyed, so the two are swapped between paints: the poll stops
    flashing an empty card while it rebuilds.
    """

    def __init__(self, parent, index: int, columns: int) -> None:
        self.frame = tk.Frame(parent, bg=BG)
        self.body = tk.Frame(self.frame, bg=BG)
        self.body.pack(fill="both", expand=True)
        self.place(index, columns)
        self._signature: str | None = None
        self._tick = None

    def place(self, index: int, columns: int) -> None:
        self.frame.grid(
            row=index // columns,
            column=index % columns,
            sticky="nsew",
            padx=4,
            pady=(0, 16),
        )

    def render(self, signature: str, build) -> None:
        if signature == self._signature:
            return
        self._signature = signature
        fresh = tk.Frame(self.body, bg=BG)
        self._tick = build(fresh)
        fresh.pack(fill="x")
        for child in self.body.winfo_children():
            if child is not fresh:
                child.destroy()

    def tick(self) -> None:
        """Refresh the reading's age without touching the rest of the card."""
        if callable(self._tick):
            self._tick()


class BarMeter(tk.Canvas):
    """The phone's five-bar meter, drawn on a canvas.

    A canvas rather than a row of Labels because the bars are a bar *chart*:
    each one is a different height, and Tk has no stack that does that without
    a frame per bar.
    """

    FRACTIONS = (0.3, 0.46, 0.62, 0.8, 1.0)

    def __init__(
        self,
        parent,
        bars: int = 0,
        height: int = 56,
        bar_width: int = 10,
        gap: int = 6,
    ) -> None:
        width = bar_width * len(self.FRACTIONS) + gap * (len(self.FRACTIONS) - 1)
        super().__init__(
            parent, width=width, height=height, bg=SURFACE,
            highlightthickness=0, bd=0,
        )
        self._bars = max(0, min(len(self.FRACTIONS), bars))
        self._height = height
        self._bar_width = bar_width
        self._gap = gap
        self.draw()

    def set_bars(self, bars: int) -> None:
        bars = max(0, min(len(self.FRACTIONS), bars))
        if bars != self._bars:
            self._bars = bars
            self.draw()

    def draw(self) -> None:
        self.delete("all")
        active = bar_colour(self._bars)
        for index, fraction in enumerate(self.FRACTIONS):
            x = index * (self._bar_width + self._gap)
            top = self._height - self._height * fraction
            self.create_rectangle(
                x,
                top,
                x + self._bar_width,
                self._height,
                fill=active if index < self._bars else TRACK,
                outline="",
            )


class LevelSlider(tk.Canvas):
    """A dBm slider drawn by hand.

    `tk.Scale` nudged the value by a decibel or two wherever it was clicked
    instead of jumping to the pointer, which reads as broken. This maps the
    pointer straight onto the range and fills the track, so the level is
    legible at a glance as well as draggable.
    """

    def __init__(self, parent, value, on_change, minimum=-140, maximum=-40,
                 width=76, height=16):
        super().__init__(parent, width=width, height=height, bg=BG,
                         highlightthickness=0, bd=0, cursor="hand2")
        self._min, self._max = minimum, maximum
        self._width, self._height = width, height
        self._value = max(minimum, min(maximum, int(value)))
        self.on_change = on_change or (lambda _value: None)
        self._enabled = True
        self.bind("<Button-1>", self._pointer)
        self.bind("<B1-Motion>", self._pointer)
        self._draw()

    def set_enabled(self, enabled: bool) -> None:
        """Grey out for a carrier that is switched off, without losing it."""
        self._enabled = bool(enabled)
        self.configure(cursor="hand2" if self._enabled else "arrow")
        self._draw()

    def set(self, value: int) -> None:
        """Move the thumb without reporting a change (the entry did that)."""
        value = max(self._min, min(self._max, int(value)))
        if value != self._value:
            self._value = value
            self._draw()

    def get(self) -> int:
        return self._value

    def _pointer(self, event) -> None:
        if not self._enabled:
            return
        span = self._width - 8
        fraction = (self.canvasx(event.x) - 4) / span
        fraction = min(1.0, max(0.0, fraction))
        value = round(self._min + fraction * (self._max - self._min))
        if value != self._value:
            self._value = value
            self._draw()
            self.on_change(value)

    def _draw(self) -> None:
        self.delete("all")
        mid = self._height // 2
        span = self._width - 8
        fraction = (self._value - self._min) / (self._max - self._min)
        x = 4 + fraction * span
        dim = not self._enabled
        self.create_rectangle(4, mid - 2, 4 + span, mid + 2,
                              fill=BORDER, outline="")
        self.create_rectangle(
            4, mid - 2, max(x, 5), mid + 2,
            fill="#334155" if dim else bar_colour(bars_for(self._value)),
            outline="",
        )
        self.create_oval(x - 5, mid - 5, x + 5, mid + 5,
                         fill="#475569" if dim else TEXT, outline=BG)


class DesktopApp(tk.Tk):
    def __init__(self, port: int) -> None:
        super().__init__()
        self.title("Sector Scout Desktop")
        self.configure(bg=BG)
        # Lay out at the monitor's real pixel density. Without this Windows
        # bitmap-scales the whole window on a 125-150% display and the cards
        # look soft (and mis-sized in screenshots).
        dpi = self.winfo_fpixels("1i")
        self.tk.call("tk", "scaling", dpi / 72.0)
        scale = max(1.0, dpi / 96.0)
        # The custom editor's carrier rows are the widest thing in the app:
        # band, channel, frequency, level, eNB/gNB, sector, PCI, TAC. The floor
        # sits just under that so a row is never clipped at the right edge.
        self.minsize(int(950 * scale), int(620 * scale))
        self.geometry(f"{int(1040 * scale)}x{int(700 * scale)}")
        self._set_icon()

        self.server = SpoofServer()
        self.phones: list[Phone] = []
        self.corrections = tk.BooleanVar(value=True)
        # One slot per phone, kept between polls so a card can be swapped rather
        # than torn down and rebuilt in place.
        self._slots: dict[int, CardSlot] = {}
        self._columns = 0
        self.port_var = tk.IntVar(value=port)
        self.scenario_var = tk.StringVar(value=next(iter(SCENARIOS)))
        self.custom: dict = merge_custom(None)
        self.address_var = tk.StringVar()
        self.poll_var = tk.StringVar(value="Not polling yet")
        self._scanning = False
        self._stop = threading.Event()

        self._load_config()
        self._build_ui()
        # Content can ask for more room than the window was given (a long JSON
        # line in the preview, a wide row of cells). Re-apply the size once the
        # widgets exist, or the toplevel grows past the screen and clips.
        self.update_idletasks()
        self._place(scale)
        # The editor was built from the saved config before the server existed
        # as far as this source is concerned, so hand it over now.
        self._sync_custom_visibility()
        self.server.set_scenario(self.scenario_var.get())
        self.server.set_custom(self.custom)
        # The tab painted before the server knew which source to serve, so the
        # preview has to be redrawn now that it does.
        self.scenario_note.configure(text=self._note_text())
        self._refresh_preview()
        if os.environ.get("SECTOR_SCOUT_DEBUG"):
            self.after(1500, lambda: print(
                "DEBUG size", self.winfo_width(), self.winfo_height(),
                "screen", self.winfo_screenwidth(), self.winfo_screenheight(),
                "scaling", self.tk.call("tk", "scaling"),
                "dpi", self.winfo_fpixels("1i"), file=sys.stderr, flush=True))
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(400, self._start_polling)
        self.after(600, self._auto_start_server)

    # -- chrome -----------------------------------------------------------
    def _place(self, scale: float) -> None:
        """Size and centre the window inside the desktop work area.

        Tk sizes against the screen, not the work area, and its default
        position is a cascade offset — on a 125% display the window ended up
        with its bottom edge under the taskbar. The work area is what is
        actually free, so measure that.
        """
        left, top, right, bottom = self._work_area()
        avail_w = right - left
        avail_h = bottom - top
        # Leave the title bar and a margin of breathing room inside the area.
        width = min(int(1040 * scale), avail_w - int(40 * scale))
        height = min(int(700 * scale), avail_h - int(60 * scale))
        x = left + max(0, (avail_w - width) // 2)
        y = top + max(0, (avail_h - height) // 2)
        self.geometry(f"{width}x{height}+{x}+{y}")

    def _work_area(self) -> tuple[int, int, int, int]:
        """(left, top, right, bottom) of the taskbar-excluding desktop."""
        if sys.platform == "win32":
            try:
                rect = ctypes.wintypes.RECT()
                SPI_GETWORKAREA = 0x0030
                if ctypes.windll.user32.SystemParametersInfoW(
                    SPI_GETWORKAREA, 0, ctypes.byref(rect), 0
                ):
                    return rect.left, rect.top, rect.right, rect.bottom
            except Exception:
                pass
        return 0, 0, self.winfo_screenwidth(), self.winfo_screenheight()

    def _set_icon(self) -> None:
        try:
            self.iconbitmap(str(ICON_FILE))
        except Exception:
            pass
        # Group under our own taskbar entry instead of "python.exe".
        if sys.platform == "win32":
            try:
                ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(
                    "SectorScout.Desktop"
                )
            except Exception:
                pass

    def _build_ui(self) -> None:
        header = tk.Frame(self, bg=BG)
        header.pack(fill="x", padx=18, pady=(14, 6))
        # The status label is packed first: a right-hand widget packed after an
        # expanding one would be pushed out of the window.
        self.server_state = tk.Label(
            header, text="", bg=BG, fg=MUTED, font=("Consolas", 9),
        )
        self.server_state.pack(side="right")
        tk.Label(
            header, text="Sector Scout", bg=BG, fg=TEXT,
            font=("Segoe UI", 17, "bold"),
        ).pack(side="left")
        tk.Label(
            header, text="  Desktop console", bg=BG, fg=MUTED,
            font=("Segoe UI", 10),
        ).pack(side="left", pady=(6, 0))

        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        # "clam" draws its own light frame and trough, which reads as grey
        # boxes against this palette; every edge colour is pinned to BG.
        style.configure("TNotebook", background=BG, borderwidth=0,
                        lightcolor=BG, darkcolor=BG, bordercolor=BG,
                        tabmargins=(0, 0, 0, 0))
        style.configure("TNotebook.Tab", background=SURFACE_ALT, foreground=MUTED,
                        padding=(16, 7), borderwidth=0,
                        lightcolor=BG, darkcolor=BG, bordercolor=BG)
        style.map("TNotebook.Tab", background=[("selected", SURFACE)],
                  foreground=[("selected", TEXT)],
                  lightcolor=[("selected", SURFACE)],
                  darkcolor=[("selected", SURFACE)],
                  bordercolor=[("selected", SURFACE)])
        # "clam" names the oriented style as well as the plain one, and the
        # instance asks for `Vertical.TScrollbar`; style both or the trough
        # keeps its light default.
        for name in ("TScrollbar", "Vertical.TScrollbar"):
            style.configure(name, background=BORDER, troughcolor=BG,
                            bordercolor=BG, lightcolor=BORDER, darkcolor=BORDER,
                            arrowcolor=MUTED, relief="flat", borderwidth=0,
                            arrowsize=12)
            style.map(name, background=[("active", "#334155")],
                      arrowcolor=[("active", TEXT)])

        notebook = ttk.Notebook(self)
        notebook.pack(fill="both", expand=True, padx=14, pady=(4, 0))
        self.phones_tab = tk.Frame(notebook, bg=BG)
        self.source_tab = tk.Frame(notebook, bg=BG)
        notebook.add(self.phones_tab, text="Phones")
        notebook.add(self.source_tab, text="Test source")
        self._build_phones_tab()
        self._build_source_tab()

        footer = tk.Frame(self, bg=BG)
        footer.pack(fill="x", padx=18, pady=8)
        tk.Label(footer, textvariable=self.poll_var, bg=BG, fg=MUTED,
                 font=("Consolas", 9)).pack(side="left")
        tk.Checkbutton(
            footer, text="Display corrections", variable=self.corrections,
            command=self._render_phones, bg=BG, fg=MUTED, selectcolor=SURFACE,
            activebackground=BG, activeforeground=TEXT, bd=0,
            font=("Segoe UI", 9),
        ).pack(side="right")

    def _build_phones_tab(self) -> None:
        bar = tk.Frame(self.phones_tab, bg=BG)
        bar.pack(fill="x", padx=4, pady=(10, 6))
        # Right-hand widgets first, then the entry expands into what is left.
        self._button(bar, "Add phone", self._add_phone).pack(side="right")
        self.scan_button = self._button(bar, "Scan", self._scan_phones)
        self.scan_button.pack(side="right", padx=(0, 6))
        # Bluetooth reaches a phone with no network to join; without
        # bleak the button stays visible but disabled, so the reason is
        # on screen instead of missing.
        self.ble_button = self._button(
            bar, "Scan Bluetooth", self._scan_ble_phones)
        self.ble_button.pack(side="right", padx=(0, 6))
        if not bleak_available():
            self.ble_button.configure(state="disabled")
        tk.Label(
            bar, text="ip or ip:port", bg=BG, fg=MUTED, font=("Segoe UI", 9),
        ).pack(side="right", padx=(0, 8))
        entry = tk.Entry(
            bar, textvariable=self.address_var, bg=SURFACE, fg=TEXT,
            insertbackground=TEXT, relief="flat", font=("Consolas", 10),
            highlightthickness=1, highlightbackground=BORDER,
            highlightcolor=ACCENT,
        )
        entry.pack(side="left", fill="x", expand=True, padx=(0, 8), ipady=6)
        entry.bind("<Return>", lambda _e: self._add_phone())

        canvas = tk.Canvas(self.phones_tab, bg=BG, highlightthickness=0)
        scroll = ttk.Scrollbar(self.phones_tab, orient="vertical",
                               command=canvas.yview)
        self.card_canvas = canvas
        self.card_host = tk.Frame(canvas, bg=BG)
        window = canvas.create_window((0, 0), window=self.card_host, anchor="nw")
        canvas.configure(yscrollcommand=scroll.set)
        canvas.pack(side="left", fill="both", expand=True, padx=(4, 0), pady=4)
        scroll.pack(side="right", fill="y")

        def _resize(_event=None):
            canvas.itemconfigure(window, width=canvas.winfo_width())
            canvas.configure(scrollregion=canvas.bbox("all"))
            self._reflow(canvas.winfo_width())

        self.card_host.bind("<Configure>", _resize)
        canvas.bind("<Configure>", _resize)
        canvas.bind_all(
            "<MouseWheel>",
            lambda e: canvas.yview_scroll(int(-e.delta / 120), "units"),
        )

    def _build_source_tab(self) -> None:
        pad = tk.Frame(self.source_tab, bg=BG)
        pad.pack(fill="both", expand=True, padx=8, pady=12)

        row = tk.Frame(pad, bg=BG)
        row.pack(fill="x")
        tk.Label(row, text="Scenario", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left", padx=(0, 8))
        combo = ttk.Combobox(row, textvariable=self.scenario_var,
                             values=list(SCENARIOS) + [CUSTOM_SCENARIO],
                             state="readonly", width=32)
        combo.pack(side="left")
        combo.bind("<<ComboboxSelected>>", lambda _e: self._scenario_changed())

        # One port on both sides: the phone's sharing server, its LAN scan and
        # this source all use the same number, so there is nothing to choose.
        tk.Label(row, text="   Port", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left", padx=(14, 6))
        tk.Label(row, text=str(DEFAULT_PORT), bg=SURFACE, fg=TEXT,
                 font=("Consolas", 10), padx=6, pady=2).pack(side="left")
        tk.Label(row, text="fixed", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(6, 0))

        self.server_button = self._button(row, "Start server", self._toggle_server)
        self.server_button.pack(side="left", padx=12)

        # The hand-built source lives here; it is packed only while selected,
        # so the preset view keeps its full payload preview.
        self.editor_host = tk.Frame(pad, bg=BG)
        self.editor_host.pack(fill="x")
        self._build_custom_editor(self.editor_host)

        self.url_label = tk.Label(
            pad, text="", bg=BG, fg=ACCENT, font=("Consolas", 11),
            justify="left", anchor="w",
        )
        self.url_label.pack(fill="x", pady=(14, 4))

        tk.Label(
            pad,
            text="Point the phone app's “Watch another phone” at this URL. It is the\n"
                 "same JSON the phone serves, so badges, bands, bars and the band\n"
                 "corrections all exercise exactly as they would against a real phone.",
            bg=BG, fg=MUTED, justify="left", anchor="w", font=("Segoe UI", 9),
        ).pack(fill="x", pady=(0, 12))

        self.scenario_note = tk.Label(
            pad, text=self._note_text(), bg=BG, anchor="w",
            fg=MUTED, justify="left", font=("Segoe UI", 9, "italic"),
        )
        self.scenario_note.pack(fill="x", pady=(0, 10))

        tk.Label(pad, text="Payload preview", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w")
        self.preview = tk.Text(
            pad, height=16, width=70, bg=SURFACE_ALT, fg=TEXT,
            insertbackground=TEXT, relief="flat", font=("Consolas", 9),
            wrap="none",
        )
        self.preview.pack(fill="both", expand=True, pady=(4, 0))
        self._refresh_preview()

    def _button(self, parent, text, command):
        return tk.Button(
            parent, text=text, command=command, bg=SURFACE, fg=TEXT,
            activebackground=BORDER, activeforeground=TEXT, relief="flat",
            bd=0, padx=14, pady=6, font=("Segoe UI", 9, "bold"),
            cursor="hand2", highlightthickness=0,
        )

    # -- custom source editor ---------------------------------------------
    def _entry(self, parent, variable, width):
        return tk.Entry(
            parent, textvariable=variable, width=width, bg=SURFACE, fg=TEXT,
            disabledforeground=OFF, disabledbackground=SURFACE_ALT,
            insertbackground=TEXT, relief="flat", font=("Consolas", 9),
            highlightthickness=1, highlightbackground=BORDER,
            highlightcolor=ACCENT,
        )

    def _build_custom_editor(self, parent) -> None:
        frame = tk.Frame(parent, bg=BG)
        self.custom_frame = frame

        top = tk.Frame(frame, bg=BG)
        top.pack(fill="x", pady=(8, 0))
        tk.Label(top, text="Carrier", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left", padx=(0, 6))
        self.carrier_var = tk.StringVar()
        self.carrier_combo = ttk.Combobox(
            top, textvariable=self.carrier_var, state="readonly", width=22,
            values=[label for label, _code in carrier_choices()],
        )
        self.carrier_combo.pack(side="left")
        self.carrier_combo.bind(
            "<<ComboboxSelected>>", lambda _e: self._carrier_picked()
        )

        # MCC and MNC are the real fields; the list above only fills them in,
        # so a network that is not in plmns.json can still be dialled by hand.
        tk.Label(top, text="MCC", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left", padx=(14, 4))
        self.mcc_var = tk.StringVar()
        self._entry(top, self.mcc_var, 4).pack(side="left", ipady=2)
        tk.Label(top, text="MNC", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left", padx=(8, 4))
        self.mnc_var = tk.StringVar()
        self._entry(top, self.mnc_var, 4).pack(side="left", ipady=2)

        tk.Label(top, text="Override", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left", padx=(16, 6))
        self.override_var = tk.StringVar()
        self.override_combo = ttk.Combobox(
            top, textvariable=self.override_var, state="readonly", width=19,
            values=[label for label, _wire in OVERRIDE_CHOICES],
        )
        self.override_combo.pack(side="left")
        self.override_combo.bind(
            "<<ComboboxSelected>>", lambda _e: self._override_picked()
        )

        self.lte_host = tk.Frame(frame, bg=BG)
        self.lte_host.pack(fill="x", pady=(6, 0))
        lte = self.custom.get("lte") or {}
        self._lte_row = self._carrier_row(
            self.lte_host, "LTE anchor", "LTE", lte,
        )

        # Carriers aggregated under the anchor: a band 29 supplemental downlink,
        # or another band as a CA layer. Their own rows, so the anchor's fields
        # are not overwritten to test a second carrier.
        self.lte_layer_host = tk.Frame(frame, bg=BG)
        self.lte_layer_host.pack(fill="x")

        self.nr_host = tk.Frame(frame, bg=BG)
        self.nr_host.pack(fill="x")

        # The add button is built before the rows, because drawing the rows is
        # what decides whether there is room for another leg.
        actions = tk.Frame(frame, bg=BG)
        actions.pack(fill="x", pady=(6, 2))
        self.add_button = self._button(actions, "+ Add NR carrier", self._add_nr)
        self.add_button.pack(side="left")
        self.add_lte_button = self._button(
            actions, "+ Add LTE carrier", self._add_lte_layer
        )
        self.add_lte_button.pack(side="left", padx=(8, 0))
        tk.Label(
            actions,
            text="an LTE carrier on B29 is served as a downlink-only SDL",
            bg=BG, fg=MUTED, font=("Segoe UI", 8),
        ).pack(side="left", padx=(10, 0))

        self._render_lte_layer_rows()
        self._render_nr_rows()

        # Neighbour cells: measured but not served. Kept as a count and a band
        # rather than a row editor, because a neighbour carries nothing else a
        # phone would read — no PLMN, no identity, no TAC.
        self.neigh_host = tk.Frame(frame, bg=BG)
        self.neigh_host.pack(fill="x", pady=(6, 0))
        tk.Label(self.neigh_host, text="Neighbours", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left")
        self.neigh_count_var = tk.StringVar()
        self._entry(self.neigh_host, self.neigh_count_var, 3).pack(
            side="left", padx=(6, 4), ipady=2)
        tk.Label(self.neigh_host, text="on", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left")
        self.neigh_band_var = tk.StringVar()
        self.neigh_band_combo = ttk.Combobox(
            self.neigh_host, textvariable=self.neigh_band_var, state="readonly",
            width=6, values=[f"B{b}" for b in sorted(LTE_CHANNELS)],
        )
        self.neigh_band_combo.pack(side="left", padx=(6, 0))
        tk.Label(self.neigh_host, text="(PCI and band only)", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(10, 0))

        self._seed_custom_widgets()
        self._apply_identity_lock()

        # Traces go on last: seeding the widgets is not an edit, and an
        # override set while the frame is being built must not re-enter. The
        # override box is driven by its selection event instead — writing to it
        # from here would race the flavour's own anchor change.
        for variable in (self.mcc_var, self.mnc_var):
            variable.trace_add("write", lambda *_a: self._custom_changed())
        for variable in (self.neigh_count_var, self.neigh_band_var):
            variable.trace_add("write", lambda *_a: self._neighbours_changed())

    def _seed_custom_widgets(self) -> None:
        plmn = str(self.custom.get("plmn") or "310410")
        self.mcc_var.set(plmn[:3])
        self.mnc_var.set(plmn[3:])
        neigh = self.custom.get("neighbours") or DEFAULT_CUSTOM["neighbours"]
        self.neigh_count_var.set(str(neigh.get("count") or 0))
        self.neigh_band_var.set(f"B{neigh.get('band') or 2}")
        self.carrier_var.set(
            next(
                (name for name, code in carrier_choices() if code == plmn),
                "",
            )
        )
        self.override_var.set(override_label(self.custom))

    def _override_picked(self) -> None:
        """An advanced flavour sets the source up as well as naming it.

        The phone sends one `NR_ADVANCED` value for both cases, so what tells
        them apart is the anchor: NSA keeps it and carries a single NR leg, SA
        drops it and can aggregate five. Choosing the flavour sets that up,
        rather than leaving the name and the layout disagreeing.
        """
        label = self.override_var.get()
        if label == "NR_ADVANCED (NSA)":
            self._lte_row["enabled"].set(True)
        elif label == "NR_ADVANCED (SA)":
            self._lte_row["enabled"].set(False)
        self._custom_changed()

    def _carrier_picked(self) -> None:
        """The carrier list is a shortcut for the MCC/MNC boxes."""
        code = dict(carrier_choices()).get(self.carrier_var.get())
        if code and len(code) >= 5:
            self.mcc_var.set(code[:3])
            self.mnc_var.set(code[3:])

    def _carrier_row(self, host, title, tech, config, on_remove=None):
        """One editable carrier: band, channel or frequency, level, identity.

        The band list is a shortcut, not a constraint — any band number can be
        typed into it. Channel and frequency track each other, so whichever of
        the two you know is the one you can fill in. The identity fields are
        the site the carrier looks like: eNB/gNB plus sector, and the PCI and
        TAC the modem reports for it.

        The checkbox takes a carrier out of the payload without forgetting it,
        which is how you get the states a preset cannot: an LTE-only reading on
        an NSA network, or SA with no anchor at all.
        """
        row = tk.Frame(host, bg=BG)
        row.pack(fill="x", pady=1)

        enabled = tk.BooleanVar(value=config.get("enabled") is not False)
        tk.Checkbutton(
            row, variable=enabled, bg=BG, activebackground=BG,
            selectcolor=SURFACE, activeforeground=TEXT, highlightthickness=0,
            bd=0,
        ).pack(side="left", padx=(0, 2))

        heading = tk.Label(
            row, text=title, bg=BG, fg=MUTED if enabled.get() else OFF, width=10,
            anchor="w", font=("Segoe UI", 9),
        )
        heading.pack(side="left")

        table = NR_CHANNELS if tech == "NR" else LTE_CHANNELS
        prefix = "n" if tech == "NR" else "B"
        band = config.get("band")
        arfcn = config.get("arfcn")
        dbm = config.get("dbm")
        band_var = tk.StringVar(value=f"{prefix}{band}" if _int_or(band) else "")
        band_combo = ttk.Combobox(
            row, textvariable=band_var, width=5,
            values=[f"{prefix}{value}" for value in sorted(table)],
        )
        band_combo.pack(side="left")

        tk.Label(row, text="ARFCN" if tech == "NR" else "EARFCN", bg=BG,
                 fg=MUTED, font=("Segoe UI", 8)).pack(side="left", padx=(8, 3))
        arfcn_var = tk.StringVar(value="" if arfcn is None else str(arfcn))
        arfcn_entry = self._entry(row, arfcn_var, 7)
        arfcn_entry.pack(side="left", ipady=2)

        tk.Label(row, text="MHz", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(6, 3))
        mhz = frequency_of(tech, _int_or(band), arfcn)
        freq_var = tk.StringVar(value="" if mhz is None else f"{mhz:.2f}")
        freq_entry = self._entry(row, freq_var, 8)
        freq_entry.pack(side="left", ipady=2)

        dbm_var = tk.StringVar(value="" if dbm is None else str(dbm))
        slider = LevelSlider(row, dbm if dbm is not None else -100, None)
        slider.pack(side="left", padx=(8, 4))

        spin = tk.Spinbox(
            row, from_=-140, to=-40, width=5, textvariable=dbm_var, bg=SURFACE,
            fg=TEXT, disabledforeground=OFF, relief="flat",
            insertbackground=TEXT, font=("Consolas", 9),
        )
        spin.pack(side="left", ipady=2)
        tk.Label(row, text="dBm", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(3, 0))

        # -- identity -----------------------------------------------------
        site_key = "gnb" if tech == "NR" else "enb"
        site = config.get(site_key)
        tk.Label(row, text="gNB" if tech == "NR" else "eNB", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(7, 3))
        site_var = tk.StringVar(value="" if site is None else str(site))
        site_entry = self._entry(row, site_var, 8)
        site_entry.pack(side="left", ipady=2)

        sector = config.get("sector")
        tk.Label(row, text="Sector", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(5, 3))
        sector_var = tk.StringVar(value="" if sector is None else str(sector))
        sector_entry = self._entry(row, sector_var, 4)
        sector_entry.pack(side="left", ipady=2)

        pci = config.get("pci")
        tk.Label(row, text="PCI", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(5, 3))
        pci_var = tk.StringVar(value="" if pci is None else str(pci))
        pci_entry = self._entry(row, pci_var, 4)
        pci_entry.pack(side="left", ipady=2)

        tac = config.get("tac")
        tk.Label(row, text="TAC", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(5, 3))
        tac_var = tk.StringVar(value="" if tac is None else str(tac))
        tac_entry = self._entry(row, tac_var, 5)
        tac_entry.pack(side="left", ipady=2)

        if on_remove is not None:
            self._button(row, "−", on_remove).pack(side="left", padx=(6, 0))

        # `syncing` stops a write this code makes itself from being read back
        # as a keystroke — every one of these widgets edits a neighbour.
        syncing = [False]

        def show_frequency():
            syncing[0] = True
            mhz = frequency_of(
                tech, _band_number(band_var.get()), _int_or(arfcn_var.get())
            )
            freq_var.set("" if mhz is None else f"{mhz:.2f}")
            syncing[0] = False

        def band_changed(*_args):
            if syncing[0]:
                return
            chosen = _band_number(band_var.get())
            if chosen in table:
                syncing[0] = True
                arfcn_var.set(str(table[chosen]))
                syncing[0] = False
                show_frequency()
            self._custom_changed()

        def arfcn_changed(*_args):
            if syncing[0]:
                return
            show_frequency()
            self._custom_changed()

        def frequency_changed(*_args):
            if syncing[0]:
                return
            channel = channel_of(
                tech,
                _band_number(band_var.get()),
                _float_or(freq_var.get()),
            )
            if channel is not None:
                syncing[0] = True
                arfcn_var.set(str(channel))
                syncing[0] = False
            self._custom_changed()

        def dbm_changed(*_args):
            if syncing[0]:
                return
            value = _int_or(dbm_var.get())
            if value is not None:
                syncing[0] = True
                slider.set(value)
                syncing[0] = False
            self._custom_changed()

        def slider_moved(value):
            syncing[0] = True
            dbm_var.set(str(int(float(value))))
            syncing[0] = False
            self._custom_changed()

        def set_enabled(*_args) -> None:
            """Dim an off carrier so it is obvious it is not being served."""
            on = enabled.get()
            band_combo.configure(state="normal" if on else "disabled")
            for widget in (arfcn_entry, freq_entry, spin, site_entry,
                           sector_entry, pci_entry, tac_entry):
                widget.configure(state="normal" if on else "disabled")
            slider.set_enabled(on)
            heading.configure(fg=MUTED if on else OFF)
            self._custom_changed()

        slider.on_change = slider_moved
        band_var.trace_add("write", band_changed)
        arfcn_var.trace_add("write", arfcn_changed)
        freq_var.trace_add("write", frequency_changed)
        dbm_var.trace_add("write", dbm_changed)
        # Identity has no derived neighbours, but it still has to reach the
        # served payload the moment it is typed.
        for variable in (site_var, sector_var, pci_var, tac_var):
            variable.trace_add("write", lambda *_a: self._custom_changed())

        def pci_left(*_args) -> None:
            """Snap an out-of-range PCI to the limit once the box is left.

            LTE has 504 physical cell identities and NR has 1008, so a larger
            number is one no radio can report. Correcting it on the way out says
            so without fighting the keystrokes that are still being typed.
            """
            value = _int_or(pci_var.get())
            if value is None:
                return
            clamped = pci_for(tech, value, value)
            if clamped != value:
                syncing[0] = True
                pci_var.set(str(clamped))
                syncing[0] = False

        pci_entry.bind("<FocusOut>", pci_left)
        # Traces last, so seeding a row is not mistaken for an edit.
        enabled.trace_add("write", set_enabled)
        if not enabled.get():
            for widget in (band_combo, arfcn_entry, freq_entry, spin,
                           site_entry, sector_entry, pci_entry, tac_entry):
                widget.configure(state="disabled")
            slider.set_enabled(False)
        return {
            "band": band_var, "arfcn": arfcn_var, "dbm": dbm_var,
            "site": site_var, "sector": sector_var, "pci": pci_var,
            "tac": tac_var, "enabled": enabled,
            # The identity boxes are locked while NSA hides the NR identity.
            "identity_widgets": (site_entry, sector_entry, tac_entry),
        }

    def _render_lte_layer_rows(self) -> None:
        for child in self.lte_layer_host.winfo_children():
            child.destroy()
        self._lte_layer_rows = []
        for index, layer in enumerate(self.custom.get("lte_layers") or []):
            self._lte_layer_rows.append(
                self._carrier_row(
                    self.lte_layer_host, f"LTE layer {index + 1}", "LTE", layer,
                    on_remove=lambda i=index: self._remove_lte_layer(i),
                )
            )
        self._sync_add_lte_button()

    def _sync_add_lte_button(self) -> None:
        used = len(self.custom.get("lte_layers") or [])
        self.add_lte_button.configure(
            state="normal" if used < MAX_LTE_LAYERS else "disabled",
            text=f"+ Add LTE carrier ({used}/{MAX_LTE_LAYERS})",
        )

    def _add_lte_layer(self) -> None:
        self._read_custom()
        layers = self.custom.setdefault("lte_layers", [])
        if len(layers) >= MAX_LTE_LAYERS:
            return
        row = dict(DEFAULT_CUSTOM["lte"])
        # A second carrier is another cell: its own band, channel and PCI, and
        # a sector of its own so the payload does not repeat one identity.
        index = len(layers)
        row["band"] = 66
        row["arfcn"] = LTE_CHANNELS[66]
        row["dbm"] = -104
        row["pci"] = 200 + index
        row["sector"] = 37 + index
        layers.append(row)
        self._render_lte_layer_rows()
        self._custom_changed()

    def _remove_lte_layer(self, index: int) -> None:
        self._read_custom()
        layers = self.custom.get("lte_layers") or []
        if not layers:
            return
        layers.pop(index)
        self._render_lte_layer_rows()
        self._custom_changed()

    def _render_nr_rows(self) -> None:
        for child in self.nr_host.winfo_children():
            child.destroy()
        self._nr_rows = []
        for index, carrier in enumerate(self.custom.get("nr") or []):
            self._nr_rows.append(
                self._carrier_row(
                    self.nr_host, f"NR carrier {index + 1}", "NR", carrier,
                    on_remove=lambda i=index: self._remove_nr(i),
                )
            )
        self._sync_add_button()
        self._apply_identity_lock()

    def _sync_add_button(self) -> None:
        cap = max_nr_carriers(self.custom)
        used = len(self.custom.get("nr") or [])
        self.add_button.configure(
            state="normal" if used < cap else "disabled",
            text=f"+ Add NR carrier ({used}/{cap})",
        )

    def _neighbours_changed(self) -> None:
        """Keep the source's neighbour count and band in step with the boxes."""
        try:
            count = int(str(self.neigh_count_var.get()).strip() or "0")
        except ValueError:
            # Half-typed input is not a choice yet; leave the source alone.
            return
        count = max(0, min(MAX_NEIGHBOURS, count))
        band_text = str(self.neigh_band_var.get()).strip().lstrip("B")
        band = int(band_text) if band_text.isdigit() else 2
        self.custom["neighbours"] = {
            "count": count, "band": band, "enabled": True,
        }
        self._custom_changed()

    def _add_nr(self) -> None:
        self._read_custom()
        cap = max_nr_carriers(self.custom)
        if len(self.custom.get("nr") or []) >= cap:
            return
        row = dict(DEFAULT_CUSTOM["nr"][0])
        row["band"] = 5
        row["arfcn"] = NR_CHANNELS[5]
        row["dbm"] = -100
        # A second leg is a different cell on the same site: same gNB, and its
        # own sector and PCI, so the payload does not repeat one identity.
        index = len(self.custom["nr"])
        row["sector"] = 49 + index
        row["pci"] = 512 + index
        self.custom["nr"].append(row)
        self._render_nr_rows()
        self._custom_changed()

    def _remove_nr(self, index: int) -> None:
        self._read_custom()
        carriers = self.custom.get("nr") or []
        if not carriers:
            return
        carriers.pop(index)
        self._render_nr_rows()
        self._custom_changed()

    def _read_custom(self) -> None:
        """Pull every widget back into the config that is served."""
        mcc = (self.mcc_var.get() or "").strip()
        mnc = (self.mnc_var.get() or "").strip()
        # Half-typed values are ignored rather than allowed to blank the PLMN.
        if mcc.isdigit() and mnc.isdigit():
            self.custom["plmn"] = mcc + mnc
        # Keep the picker honest: it names a PLMN only while it matches one.
        known = next(
            (name for name, code in carrier_choices()
             if code == self.custom["plmn"]),
            "",
        )
        if self.carrier_var.get() != known:
            self.carrier_var.set(known)
        self.custom["lte"] = self._row_config(self._lte_row, "enb")
        self.custom["lte_layers"] = [
            self._row_config(row, "enb") for row in self._lte_layer_rows
        ]
        self.custom["nr"] = [
            self._row_config(row, "gnb") for row in self._nr_rows
        ]

        self.custom["override"] = override_wire(self.override_var.get())
        # The advanced entry names the flavour from the anchor, so ticking or
        # unticking the anchor renames it rather than leaving the two at odds.
        # It reads the rows above, so it has to come after they are collected.
        label = override_label(self.custom)
        if self.override_var.get() != label:
            self.override_var.set(label)

    @staticmethod
    def _row_config(variables: dict, site_key: str) -> dict:
        """One row's widgets as the dict the payload is built from."""
        return {
            "band": _band_number(variables["band"].get()),
            "arfcn": _int_or(variables["arfcn"].get()),
            "dbm": _int_or(variables["dbm"].get()),
            site_key: _int_or(variables["site"].get()),
            "sector": _int_or(variables["sector"].get()),
            "pci": _int_or(variables["pci"].get()),
            "tac": _int_or(variables["tac"].get()),
            "enabled": bool(variables["enabled"].get()),
        }

    def _custom_changed(self) -> None:
        if self.scenario_var.get() != CUSTOM_SCENARIO:
            return
        self._read_custom()
        cap = max_nr_carriers(self.custom)
        if len(self.custom.get("nr") or []) > cap:
            # An override change can invalidate extra legs (NSA is one carrier).
            self.custom["nr"] = self.custom["nr"][:cap]
            self._render_nr_rows()
        else:
            self._sync_add_button()
        self._sync_add_lte_button()
        self.server.set_custom(self.custom)
        self._apply_identity_lock()
        self.scenario_note.configure(text=self._note_text())
        self._refresh_preview()

    def _apply_identity_lock(self) -> None:
        """Grey out the NR identity boxes while an LTE anchor is serving.

        NSA radios hand the 5G leg over without its NCI, so there is no gNB or
        sector for the source to send and the app is left to estimate the gNB
        from the LTE eNB. The boxes keep their values for the SA case; they just
        cannot be edited while they are not being encoded.
        """
        locked = nsa_mode(self.custom)
        self.identity_locked = locked
        for row in self._nr_rows:
            editable = row["enabled"].get() and not locked
            for widget in row["identity_widgets"]:
                widget.configure(state="normal" if editable else "disabled")

    def _custom_summary(self) -> str:
        """What is actually being served, and what the phone will call it.

        Switched-off carriers are left out, so the read-back is the same thing
        the phone sees — `B30 anchor · NR_NSA → LTE only` is the anchor with
        its 5G leg gone, not a layout with an n5 in it.
        """
        layout = custom_layout(self.custom)
        override = override_label(self.custom)
        note = " (gNB est. — no NR identity)" if nsa_mode(self.custom) else ""
        return f"{layout} · {override} → {self._mode_text()}{note}"

    def _fr2_dropped(self) -> bool:
        """A lone FR2 carrier switched on but left out of the payload."""
        if anchor_band(self.custom) is not None:
            return False
        enabled = [
            c for c in self.custom.get("nr") or []
            if c.get("enabled") is not False and _int_or(c.get("band"))
        ]
        return bool(enabled) and not served_nr_bands(self.custom)

    def _mode_text(self) -> str:
        has_lte = anchor_band(self.custom)
        has_nr = bool(served_nr_bands(self.custom))
        if has_lte and has_nr:
            return "5G NSA"
        if has_lte:
            return "LTE only"
        if has_nr:
            return "5G SA"
        return "nothing served"

    def _note_text(self) -> str:
        name = self.scenario_var.get()
        if name == CUSTOM_SCENARIO:
            return self._custom_summary()
        return SCENARIOS[name]["note"]

    def _sync_custom_visibility(self) -> None:
        if self.scenario_var.get() == CUSTOM_SCENARIO:
            self.custom_frame.pack(fill="x")
        else:
            self.custom_frame.pack_forget()

    # -- server tab -------------------------------------------------------
    def _auto_start_server(self) -> None:
        try:
            self.server.start(self.port_var.get(), self.scenario_var.get())
        except OSError as error:
            self.url_label.configure(
                text=f"Could not listen on port {self.port_var.get()}: {error}",
                fg=DANGER,
            )
            return
        self._server_started()

    def _toggle_server(self) -> None:
        if self.server.running:
            self.server.stop()
            self.server_button.configure(text="Start server")
            self.url_label.configure(text="Server stopped.", fg=MUTED)
            self._update_state_label()
            return
        try:
            self.server.start(self.port_var.get(), self.scenario_var.get())
        except OSError as error:
            self.url_label.configure(text=f"Port busy: {error}", fg=DANGER)
            return
        self._server_started()

    def _server_started(self) -> None:
        self.server_button.configure(text="Stop server")
        ip = local_ip()
        port = self.server._port
        self.url_label.configure(
            text=f"http://{ip}:{port}/snapshot\nhttp://127.0.0.1:{port}/snapshot",
            fg=ACCENT,
        )
        self._update_state_label()

    def _scenario_changed(self) -> None:
        self._sync_custom_visibility()
        self.server.set_scenario(self.scenario_var.get())
        self.server.set_custom(self.custom)
        self.scenario_note.configure(text=self._note_text())
        self._save_config()
        self._refresh_preview()

    def _refresh_preview(self) -> None:
        # Always the composed payload, so the preview cannot disagree with
        # what a phone would actually receive.
        payload = self.server.payload()
        self.preview.configure(state="normal")
        self.preview.delete("1.0", "end")
        self.preview.insert("1.0", json.dumps(payload, indent=2))
        self.preview.configure(state="disabled")

    def _update_state_label(self) -> None:
        if self.server.running:
            self.server_state.configure(
                text=f"test source :{self.server._port} · "
                     f"{self.server.requests} requests",
                fg=ACCENT,
            )
        else:
            self.server_state.configure(text="test source stopped", fg=MUTED)

    # -- phones -----------------------------------------------------------
    def _scan_phones(self) -> None:
        """Sweep the subnet for phones, then add the ones not already listed."""
        if self._scanning:
            return
        self._scanning = True
        port = int(self.port_var.get())
        self.poll_var.set(f"Scanning the network on port {port}…")

        def work() -> None:
            try:
                found = scan_lan(port)
            except Exception as error:  # noqa: BLE001 - reported in the footer
                self.after(0, lambda: self._scan_done([], str(error)))
                return
            self.after(0, lambda: self._scan_done(found, None))

        threading.Thread(target=work, daemon=True).start()

    def _scan_done(self, found: list[str], error: str | None) -> None:
        self._scanning = False
        port = int(self.port_var.get())
        if error:
            self.poll_var.set(f"Scan failed: {error}")
            return
        added = 0
        for host in found:
            url = normalise_url(host)
            if any(p.url == url for p in self.phones):
                continue
            self.phones.append(Phone(url=url))
            added += 1
        if added:
            self._save_config()
            self._render_phones()
        if not found:
            self.poll_var.set(f"No phone answered on port {port}.")
        else:
            self.poll_var.set(f"Found {len(found)} on port {port}; added {added}.")

    def _scan_ble_phones(self) -> None:
        """Look for phones advertising the Bluetooth share, then list them."""
        if self._scanning:
            return
        if not bleak_available():
            self.poll_var.set(
                "Bluetooth scanning needs the bleak package: pip install bleak"
            )
            return
        self._scanning = True
        self.poll_var.set("Scanning Bluetooth for sharing phones…")

        def work() -> None:
            try:
                found = scan_ble()
            except Exception as error:  # noqa: BLE001 - reported in the footer
                self.after(0, lambda: self._ble_scan_done([], str(error)))
                return
            self.after(0, lambda: self._ble_scan_done(found, None))

        threading.Thread(target=work, daemon=True).start()

    def _ble_scan_done(self, found: list[dict], error: str | None) -> None:
        self._scanning = False
        if error:
            self.poll_var.set(f"Bluetooth scan failed: {error}")
            return
        added = 0
        for entry in found:
            address = entry["address"]
            if any(p.transport == "ble" and p.address == address
                   for p in self.phones):
                continue
            self.phones.append(
                Phone(
                    url="",
                    name=entry["name"],
                    transport="ble",
                    address=address,
                    device=entry.get("device"),
                )
            )
            added += 1
        if added:
            self._save_config()
            self._render_phones()
        if not found:
            self.poll_var.set(
                "No phone advertising the Bluetooth share — is Bluetooth "
                "sharing on in the app, and this PC's Bluetooth on?"
            )
        else:
            self.poll_var.set(
                f"Found {len(found)} over Bluetooth; added {added}."
            )


    def _add_phone(self) -> None:
        try:
            url = normalise_url(self.address_var.get())
        except ValueError as error:
            self.poll_var.set(str(error))
            return
        if any(p.url == url for p in self.phones):
            self.poll_var.set("That phone is already in the list.")
            return
        self.phones.append(Phone(url=url))
        self.address_var.set("")
        self._save_config()
        self._render_phones()

    def _remove_phone(self, phone: Phone) -> None:
        self.phones = [p for p in self.phones if p is not phone]
        self._save_config()
        self._render_phones()

    def _start_polling(self) -> None:
        # Two threads, not one: a GATT read can hold its link for seconds, and
        # sharing a thread with the Wi-Fi poll would stall every HTTP phone for
        # the duration of it.
        threading.Thread(target=self._poll_loop, daemon=True).start()
        threading.Thread(target=self._ble_poll_loop, daemon=True).start()
        # The operator list is fetched off the UI thread: the cards draw with the
        # SIM's own name until it lands, then redraw with the brand.
        threading.Thread(target=self._carrier_refresh, daemon=True).start()

    def _carrier_refresh(self) -> None:
        """Load the operator list, then redraw if it changed what is shown."""
        before = dict(CARRIER_BRANDS)
        try:
            refresh_carrier_names()
        except Exception:  # noqa: BLE001 - the SIM name is a fine fallback
            return
        if CARRIER_BRANDS != before:
            try:
                self.after(0, self._render_phones)
            except RuntimeError:
                # The window closed while the list was in flight; nothing to
                # redraw, and a traceback in a daemon thread would be noise.
                return

    def _poll_loop(self) -> None:
        while not self._stop.is_set():
            for phone in list(self.phones):
                if self._stop.is_set():
                    return
                if phone.transport == "ble":
                    continue
                try:
                    fetch_phone(phone)
                except Exception:  # noqa: BLE001 - one phone must not stop the rest
                    phone.error = "This phone could not be read"
            self.after(0, self._render_phones)
            self._stop.wait(POLL_SECONDS)

    def _ble_poll_loop(self) -> None:
        """Start a read for every Bluetooth phone, each independent of the rest.

        Reads used to run one after another on this single thread, so a phone
        that took ten seconds to answer held every other phone back for those
        ten seconds — the reason some cards sat on old data for a minute. Each
        phone now gets its own attempt, and a phone that is still reading is
        left alone until it finishes.
        """
        workers: dict[int, threading.Thread] = {}
        while not self._stop.is_set():
            phones = [p for p in list(self.phones) if p.transport == "ble"]
            live = {id(p) for p in phones}
            for key in [k for k in workers if k not in live]:
                workers.pop(key, None)
            for phone in phones:
                running = workers.get(id(phone))
                if running is not None and running.is_alive():
                    continue
                worker = threading.Thread(
                    target=self._ble_phone_read, args=(phone,), daemon=True
                )
                workers[id(phone)] = worker
                worker.start()
            self._stop.wait(BLE_POLL_SECONDS)

    def _ble_phone_read(self, phone: Phone) -> None:
        """One phone's attempt: mark it as reading, read it, record the answer."""
        address = phone.address
        # Say what is happening: a first read can take a few seconds, and an
        # empty card reads as broken in the meantime.
        phone.status = "Reading over Bluetooth…"
        phone.attempted = time.time()
        self.after(0, self._render_phones)
        try:
            fetch_phone(phone)
        except Exception:  # noqa: BLE001 - this phone only
            phone.error = "This phone could not be read over Bluetooth"
        phone.status = ""
        if phone.address != address:
            # The phone moved to a new advertising address: remember it, so the
            # next start does not have to hunt for it again.
            self.after(0, self._save_config)
        self.after(0, self._render_phones)

    def _card_columns(self, width: int) -> int:
        """How many cards sit side by side: one narrow, up to three wide.

        The divisor is the narrowest a card may get, not the width a card wants:
        at 640 the 1270-pixel panel in a normal window stayed a single column,
        because two of those do not fit. 600 lets two cards share that panel and
        still leaves each one wider than the phone's own screen.
        """
        if width <= 1:
            return 2
        return max(1, min(3, width // 600))

    def _show_empty(self, visible: bool) -> None:
        if not hasattr(self, "_empty"):
            self._empty = tk.Label(
                self.card_host,
                text="No phones yet. Type an address above, or use “Scan” for\n"
                     "Wi-Fi and “Scan Bluetooth” for the GATT share — the\n"
                     "phone must have sharing switched on for that transport.",
                bg=BG, fg=MUTED, justify="left", font=("Segoe UI", 10),
            )
        if visible:
            self._empty.grid(row=0, column=0, sticky="w", pady=24, padx=12)
        else:
            self._empty.grid_remove()

    def _reflow(self, width: int) -> None:
        """Re-lay the grid when the window becomes wide or narrow enough."""
        columns = self._card_columns(width)
        if columns == getattr(self, "_columns", None):
            return
        self._columns = columns
        self._render_phones()

    def _render_phones(self) -> None:
        canvas = getattr(self, "card_canvas", None)
        offset = canvas.yview()[0] if canvas is not None else 0.0
        width = canvas.winfo_width() if canvas is not None else 0
        columns = self._card_columns(width)
        corrections = bool(self.corrections.get())

        living = {id(phone) for phone in self.phones}
        for key in [k for k in self._slots if k not in living]:
            self._slots.pop(key).frame.destroy()

        if not self.phones:
            self._show_empty(True)
            self.poll_var.set("No phones configured")
            self._update_state_label()
            return

        self._show_empty(False)
        # A lone card takes the whole width: one phone sitting in half of a
        # two-column grid reads as a layout fault rather than a layout.
        columns = min(columns, len(self.phones))
        self._columns = columns
        for column in range(columns):
            self.card_host.grid_columnconfigure(column, weight=1, uniform="card")

        for index, phone in enumerate(self.phones):
            slot = self._slots.get(id(phone))
            if slot is None:
                slot = CardSlot(self.card_host, index, columns)
                self._slots[id(phone)] = slot
            slot.place(index, columns)
            slot.render(
                phone_signature(phone, corrections),
                lambda parent, p=phone: self._phone_card(p, parent),
            )
            slot.tick()

        if canvas is not None and offset > 0.0:
            def restore(_offset=offset) -> None:
                self.card_host.update_idletasks()
                canvas.yview_moveto(_offset)

            self.after_idle(restore)

        ok = sum(1 for p in self.phones if p.snapshot is not None)
        stamp = datetime.now().strftime("%H:%M:%S")
        self.poll_var.set(
            f"{ok}/{len(self.phones)} phones answering · refreshed {stamp}"
        )
        self._update_state_label()

    def _phone_card(self, phone: Phone, parent):
        """One phone, drawn the way the app draws a SIM: header, meter, rows.

        Returns a callable that refreshes the reading's age, so a card whose
        numbers have not moved still says how old it is without being rebuilt.
        """
        card = tk.Frame(parent, bg=BG)
        card.pack(fill="x")

        head = tk.Frame(card, bg=BG)
        head.pack(fill="x", padx=4)
        snapshot = phone.snapshot
        title = phone.label
        if snapshot and snapshot.get("deviceModel"):
            title = str(snapshot["deviceModel"])
        tk.Label(head, text=title, bg=BG, fg=TEXT,
                 font=("Segoe UI", 11, "bold")).pack(side="left")
        origin = (
            f"Bluetooth · {phone.address}"
            if phone.transport == "ble"
            else phone.url
        )
        tk.Label(head, text=f"  {origin}", bg=BG, fg=MUTED,
                 font=("Consolas", 8)).pack(side="left", pady=(2, 0))
        self._button(head, "Remove",
                     lambda p=phone: self._remove_phone(p)).pack(side="right")

        if phone.error:
            tk.Label(
                card, text=phone.error, bg=SURFACE, fg=DANGER,
                font=("Segoe UI", 9), justify="left", anchor="w", padx=14,
                pady=12, wraplength=620,
            ).pack(fill="x", pady=(6, 0))
            return None

        if not snapshot:
            if phone.status:
                waiting = phone.status
            elif phone.note:
                waiting = phone.note
            elif phone.attempted:
                tried = datetime.fromtimestamp(phone.attempted).strftime("%H:%M:%S")
                waiting = f"No answer yet — last attempt {tried}, retrying"
            else:
                waiting = "Waiting for the first reading…"
            tk.Label(
                card, text=waiting, bg=SURFACE, fg=MUTED,
                font=("Segoe UI", 9), anchor="w", padx=14, pady=12,
            ).pack(fill="x", pady=(6, 0))
            return None

        for sim in snapshot.get("sims") or []:
            if isinstance(sim, dict):
                self._sim_card(card, sim, phone.updated)

        age = tk.Label(card, text="", bg=BG, fg="#64748B",
                       font=("Segoe UI", 8))
        age.pack(anchor="e", padx=6, pady=(0, 4))

        def tick() -> None:
            seconds = int(time.time() - phone.updated) if phone.updated else None
            text = (
                ""
                if seconds is None
                else f"read {seconds}s ago · {snapshot.get('cellCount', 0)} cells"
            )
            if age.cget("text") != text:
                age.configure(text=text)

        tick()
        return tick

    # -- one SIM, in the app's own card layout -----------------------------
    def _sim_card(self, parent: tk.Frame, sim: dict, updated: float | None) -> None:
        cells = [c for c in (sim.get("cells") or []) if isinstance(c, dict)]
        carriers = [c for c in (sim.get("carriers") or []) if isinstance(c, dict)]
        registered = [c for c in cells if c.get("registered")]
        lte = next(
            (c for c in registered if c.get("type") == "LTE" and not is_sdl_lte(c)),
            None,
        )
        if lte is None:
            lte = next((c for c in registered if c.get("type") == "LTE"), None)
        nr = next((c for c in registered if c.get("type") == "NR"), None)
        serving = nr or lte or (registered[0] if registered else None)
        secondaries = lte_secondaries(cells)
        badge = badge_for(sim, cells)
        mode = mode_of(sim, cells)
        carrier = carrier_name(sim) or "SIM"
        paired = lte is not None and nr is not None

        card = tk.Frame(parent, bg=SURFACE, highlightthickness=1,
                        highlightbackground=BORDER)
        card.pack(fill="x", pady=(0, 12))
        body = tk.Frame(card, bg=SURFACE)
        body.pack(fill="x", padx=20, pady=18)

        # -- header: name, technology, slot, mode chip ---------------------
        head = tk.Frame(body, bg=SURFACE)
        head.pack(fill="x")
        chip = tk.Label(
            head, text=mode, bg=SURFACE_ALT,
            fg=ACCENT if nr is not None else MUTED,
            font=("Segoe UI", 8, "bold"), padx=9, pady=3,
            highlightthickness=1, highlightbackground=BORDER,
        )
        chip.pack(side="right", anchor="ne")

        names = tk.Frame(head, bg=SURFACE)
        names.pack(side="left", anchor="w", fill="x", expand=True)
        line = tk.Frame(names, bg=SURFACE)
        line.pack(anchor="w")
        tk.Label(line, text=carrier, bg=SURFACE, fg=TEXT,
                 font=("Segoe UI", 12, "bold")).pack(side="left")
        if badge != "—":
            five_g = badge.startswith("5G") and badge != "5GE"
            tk.Label(line, text=badge, bg=SURFACE,
                     fg=ACCENT if five_g else MUTED,
                     font=("Segoe UI", 8, "bold")).pack(side="left", padx=(7, 0))
        tk.Label(
            line, text=f"SIM {int(sim.get('slotIndex', 0)) + 1}",
            bg=SURFACE_ALT, fg=MUTED, font=("Segoe UI", 7),
            padx=5, pady=1, highlightthickness=1, highlightbackground=BORDER,
        ).pack(side="left", padx=(7, 0))
        tk.Label(names, text="SERVING CELL", bg=SURFACE, fg=MUTED,
                 font=("Segoe UI", 7)).pack(anchor="w", pady=(3, 0))

        # -- meter: one per leg of an NSA pair, else the serving cell ------
        meters = tk.Frame(body, bg=SURFACE)
        meters.pack(fill="x", pady=(16, 0))
        if paired:
            self._leg_meter(meters, "LTE anchor", lte)
            tk.Frame(meters, bg=BORDER, width=1, height=64).pack(
                side="left", padx=16, fill="y")
            self._leg_meter(meters, "5G NR", nr)
        else:
            self._primary_meter(meters, serving)

        # -- footer: the reading's age, as the card carries it -------------
        tk.Frame(body, bg=BORDER, height=1).pack(fill="x", pady=(14, 0))
        footer = tk.Frame(body, bg=SURFACE)
        footer.pack(fill="x", pady=(8, 0))
        stamp = (
            datetime.fromtimestamp(updated).strftime("%H:%M:%S")
            if updated else "—"
        )
        tk.Label(footer, text=f"Updated {stamp}", bg=SURFACE, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left")
        size = len(cells)
        tk.Label(
            footer, text=f"{size} cell{'s' if size != 1 else ''} visible",
            bg=SURFACE, fg=MUTED, font=("Segoe UI", 8),
        ).pack(side="right")

        # -- rows ----------------------------------------------------------
        def heading(text: str) -> None:
            tk.Frame(body, bg=SURFACE, height=14).pack(fill="x")
            tk.Label(body, text=text.upper(), bg=SURFACE, fg=MUTED,
                     font=("Segoe UI", 8, "bold")).pack(anchor="w", pady=(2, 5))

        if serving is not None:
            if paired:
                heading("4G anchor")
                self._detail_card(body, serving_entries(lte, self.corrections.get()))
                heading("5G NR secondary")
                self._detail_card(
                    body,
                    serving_entries(
                        nr,
                        self.corrections.get(),
                        gnb_estimate=nsa_gnb_estimate(lte, nr),
                    ),
                )
            else:
                heading("5G NR" if lte is None else "Serving cell")
                self._detail_card(
                    body, serving_entries(serving, self.corrections.get()))
            for secondary in secondaries:
                heading("4G LTE secondary")
                self._detail_card(
                    body,
                    serving_entries(
                        secondary,
                        self.corrections.get(),
                        fallback_plmn=plmn_of(lte) or plmn_of(nr),
                    ),
                )
            if carriers:
                heading("Carrier aggregation")
                self._detail_card(body, carrier_rows(carriers))
            heading("Radio quality")
            self._detail_card(body, quality_entries(cells))

        if cells:
            neighbours = heard_neighbours(cells)
            count = f" ({len(neighbours)})" if neighbours else ""
            heading(f"Neighbour cells{count}")
            self._neighbour_card(body, neighbours)

    def _primary_meter(self, parent: tk.Frame, cell: dict | None) -> None:
        dbm = _int_or(cell.get("dbm")) if cell else None
        bars = bars_for(dbm)
        colour = bar_colour(bars)
        row = tk.Frame(parent, bg=SURFACE)
        row.pack(fill="x")
        BarMeter(row, bars=bars, height=58, bar_width=11, gap=6).pack(
            side="left", anchor="s")
        text = tk.Frame(row, bg=SURFACE)
        text.pack(side="left", padx=(18, 0), anchor="w")
        line = tk.Frame(text, bg=SURFACE)
        line.pack(anchor="w")
        tk.Label(line, text=str(dbm) if dbm is not None else "—", bg=SURFACE,
                 fg=colour, font=("Consolas", 26)).pack(side="left")
        tk.Label(line, text="dBm", bg=SURFACE, fg=MUTED,
                 font=("Segoe UI", 8)).pack(side="left", padx=(6, 0), pady=(0, 7),
                                       anchor="s")
        tk.Label(text, text=quality_label(bars), bg=SURFACE, fg=colour,
                 font=("Segoe UI", 9)).pack(anchor="w", pady=(2, 0))

    def _leg_meter(self, parent: tk.Frame, label: str, cell: dict) -> None:
        column = tk.Frame(parent, bg=SURFACE)
        column.pack(side="left", anchor="n")
        tk.Label(column, text=label.upper(), bg=SURFACE, fg=MUTED,
                 font=("Segoe UI", 7, "bold")).pack(anchor="w")
        dbm = _int_or(cell.get("dbm"))
        bars = bars_for(dbm)
        row = tk.Frame(column, bg=SURFACE)
        row.pack(anchor="w", pady=(7, 0))
        BarMeter(row, bars=bars, height=40, bar_width=8, gap=4).pack(
            side="left", anchor="s")
        value = tk.Frame(row, bg=SURFACE)
        value.pack(side="left", padx=(10, 0))
        tk.Label(value, text=str(dbm) if dbm is not None else "—", bg=SURFACE,
                 fg=bar_colour(bars), font=("Consolas", 17)).pack(anchor="w")
        tk.Label(value, text="dBm", bg=SURFACE, fg=MUTED,
                 font=("Segoe UI", 7)).pack(anchor="w")
        tk.Label(column, text=quality_label(bars), bg=SURFACE,
                 fg=bar_colour(bars), font=("Segoe UI", 8)).pack(
            anchor="w", pady=(6, 0))

    def _detail_card(self, parent: tk.Frame, rows: list[tuple[str, str]]) -> None:
        card = tk.Frame(parent, bg=SURFACE, highlightthickness=1,
                        highlightbackground=BORDER)
        card.pack(fill="x")
        for index, (label, value) in enumerate(rows):
            if index:
                tk.Frame(card, bg=BORDER, height=1).pack(fill="x", padx=14)
            row = tk.Frame(card, bg=SURFACE)
            row.pack(fill="x", padx=14, pady=7)
            tk.Label(row, text=label, bg=SURFACE, fg=MUTED,
                     font=("Segoe UI", 9)).pack(side="left")
            tk.Label(row, text=value, bg=SURFACE, fg=TEXT,
                     font=("Consolas", 9)).pack(side="right")

    def _neighbour_card(self, parent: tk.Frame, cells: list[dict]) -> None:
        card = tk.Frame(parent, bg=SURFACE, highlightthickness=1,
                        highlightbackground=BORDER)
        card.pack(fill="x")
        if not cells:
            tk.Label(
                card,
                text="The modem is not reporting any neighbour cells right now.",
                bg=SURFACE, fg=MUTED, font=("Segoe UI", 9), justify="left",
                anchor="w", padx=14, pady=14,
            ).pack(fill="x")
            return

        for index, cell in enumerate(cells):
            if index:
                tk.Frame(card, bg=BORDER, height=1).pack(fill="x", padx=14)
            row = tk.Frame(card, bg=SURFACE)
            row.pack(fill="x", padx=14, pady=10)

            tech = str(cell.get("type") or "?")
            tk.Label(
                row, text=tech, bg=SURFACE_ALT, fg=MUTED,
                font=("Segoe UI", 7, "bold"), padx=5, pady=2,
                highlightthickness=1, highlightbackground=BORDER,
            ).pack(side="left", anchor="n")

            info = tk.Frame(row, bg=SURFACE)
            info.pack(side="left", fill="x", expand=True, padx=(10, 10))
            cell_id = _int_or(cell.get("cellId"))
            site, _ = cell_ids(cell)
            if site is not None:
                title = f"{'gNB' if tech == 'NR' else 'eNB'} {site}"
            elif cell_id:
                title = f"Cell {cell_id}"
            elif cell.get("pci") is not None:
                title = f"{pci_label(cell)} {cell.get('pci')}"
            else:
                title = "Unknown cell"
            details = []
            if cell_id and cell.get("pci") is not None:
                details.append(f"{pci_label(cell)} {cell.get('pci')}")
            band = band_label(cell, self.corrections.get())
            if band:
                details.append(band)
            if cell.get("tac") is not None:
                details.append(f"{tac_label(cell)} {cell.get('tac')}")
            plmn = plmn_of(cell)
            if plmn:
                details.append(f"{plmn[:3]}-{plmn[3:]}")

            tk.Label(info, text=title, bg=SURFACE, fg=TEXT,
                     font=("Consolas", 9)).pack(anchor="w")
            if details:
                tk.Label(info, text=" · ".join(details), bg=SURFACE, fg=MUTED,
                         font=("Segoe UI", 8)).pack(anchor="w", pady=(2, 0))
            frequency = neighbour_frequency(cell)
            if frequency:
                tk.Label(info, text=frequency, bg=SURFACE, fg="#64748B",
                         font=("Consolas", 8)).pack(anchor="w", pady=(2, 0))

            dbm = _int_or(cell.get("dbm"))
            bars = bars_for(dbm)
            tk.Label(
                row, text=f"{dbm} dBm" if dbm is not None else "—", bg=SURFACE,
                fg=bar_colour(bars), font=("Consolas", 8),
            ).pack(side="left", padx=(0, 10))
            BarMeter(row, bars=bars, height=22, bar_width=4, gap=3).pack(
                side="left")

    # -- config -----------------------------------------------------------
    def _load_config(self) -> None:
        try:
            data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            # ValueError covers both a malformed file and one written in
            # another encoding; either way the defaults are better than a
            # window that never opens.
            return
        if not isinstance(data, dict):
            return
        # The port is not a setting: an old file may name 8090, but both ends
        # only find each other on the fixed one.
        self.port_var.set(DEFAULT_PORT)
        scenario = data.get("scenario")
        if scenario in SCENARIOS or scenario == CUSTOM_SCENARIO:
            self.scenario_var.set(scenario)
        self.custom = merge_custom(data.get("custom"))
        self.corrections.set(bool(data.get("corrections", True)))
        for entry in data.get("phones", []):
            if not isinstance(entry, dict):
                continue
            transport = "ble" if entry.get("transport") == "ble" else "wifi"
            address = str(entry.get("address") or "")
            url = str(entry.get("url") or "")
            if transport == "ble" and not address:
                continue
            if transport == "wifi" and not url:
                continue
            self.phones.append(
                Phone(
                    url=url,
                    name=str(entry.get("name") or ""),
                    transport=transport,
                    address=address,
                )
            )

    def _save_config(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "port": DEFAULT_PORT,
            "scenario": self.scenario_var.get(),
            "corrections": self.corrections.get(),
            "custom": self.custom,
            "phones": [
                {
                    "url": p.url,
                    "name": p.name,
                    "transport": p.transport,
                    "address": p.address,
                }
                for p in self.phones
            ],
        }
        try:
            CONFIG_FILE.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        except OSError:
            pass

    def _on_close(self) -> None:
        self._stop.set()
        self._save_config()
        self.server.stop()
        self.destroy()


APP_VERSION = "1.1.1-beta"
RELEASES_URL = (
    "https://api.github.com/repos/tsalisbury0/sector-scout/releases?per_page=10"
)


def version_key(tag: str) -> tuple[int, int, int, int, int]:
    """Where a release tag sorts: numbers, stable-above-beta, beta number.

    `1.1.0-beta` and `1.1.0-beta2` both reduce to 1.1.0, so the number after
    the word is what tells a beta bump from the build already installed.
    """
    text = tag.lstrip("v")
    core = text.split("-")[0].split("+")[0]
    numbers = [int(part) for part in core.split(".") if part.isdigit()][:3]
    while len(numbers) < 3:
        numbers.append(0)
    lowered = text.lower()
    ordinal = 0
    if "beta" in lowered:
        tail = lowered.split("beta", 1)[1].lstrip(".-_")
        digits = ""
        for character in tail:
            if character.isdigit():
                digits += character
            else:
                break
        ordinal = int(digits) if digits else 0
    return (
        numbers[0],
        numbers[1],
        numbers[2],
        0 if "-" in text else 1,
        ordinal,
    )


def _download_console_zip(tag: str) -> Path:
    """Fetches this console's own release zip into Downloads."""
    version = tag.lstrip("v")
    url = (
        "https://github.com/tsalisbury0/sector-scout/releases/download/"
        f"{tag}/sector-scout-desktop-{version}.zip"
    )
    folder = Path.home() / "Downloads"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f"sector-scout-desktop-{version}.zip"
    request = urllib.request.Request(
        url, headers={"User-Agent": "sector-scout-console-update"}
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        target.write_bytes(response.read())
    return target


def _install_console_zip(archive: Path) -> bool:
    """Replaces this script with the copy inside the release zip."""
    import zipfile

    target = Path(__file__).resolve()
    with zipfile.ZipFile(archive) as bundle:
        member = next(
            (
                name
                for name in bundle.namelist()
                if name.endswith("sector_scout_desktop.py")
            ),
            None,
        )
        if member is None:
            return False
        code = bundle.read(member)
    if not code.strip():
        return False
    target.with_suffix(".py.bak").write_bytes(target.read_bytes())
    target.write_bytes(code)
    return True


def _updates_pref() -> Path:
    """Where the console remembers skipped versions, outside the repo."""
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    return Path(base) / "SectorScout" / "updates.json"


def _start_update_check(app) -> None:
    """Check GitHub for a newer console release, stably and off the UI thread.

    Prereleases are skipped: betas live on the phone app's own release channel.
    A newer stable asks once, with Skip this version remembered across runs.
    """

    def worker() -> None:
        try:
            request = urllib.request.Request(
                RELEASES_URL,
                headers={
                    "User-Agent": "sector-scout-console-update",
                    "Accept": "application/vnd.github+json",
                },
            )
            releases = json.loads(urllib.request.urlopen(request, timeout=15))
            skip = ""
            try:
                stored = json.loads(_updates_pref().read_text(encoding="utf-8"))
                skip = stored.get("skip", "")
            except (OSError, ValueError):
                pass
            best = None
            for release in releases:
                if release.get("draft"):
                    continue
                tag = release.get("tag_name") or ""
                # Betas are this console's own channel now, and the number
                # after the word is what makes 1.1.0-beta2 newer than
                # 1.1.0-beta; both reduce to 1.1.0 on their own.
                key = version_key(tag)
                if not tag or tag == f"v{APP_VERSION}" or tag == skip:
                    continue
                if best is None or key > best[0]:
                    best = (key, tag, release.get("html_url", ""))

            def ask() -> None:
                if best is None:
                    return
                _key, tag_name, page = best
                answer = messagebox.askyesno(
                    "Sector Scout update",
                    f"{tag_name} is available (this console: v{APP_VERSION}).\n\n"
                    "Download and install it now?",
                )
                if answer:
                    try:
                        archive = _download_console_zip(tag_name)
                        installed = _install_console_zip(archive)
                    except Exception as error:  # network, disk, or a bad zip
                        messagebox.showerror("Update failed", str(error))
                        return
                    pref = _updates_pref()
                    try:
                        json.dump(
                            {"version": APP_VERSION},
                            pref.open("w", encoding="utf-8"),
                        )
                    except OSError:
                        pass
                    if installed:
                        messagebox.showinfo(
                            "Sector Scout update",
                            f"{tag_name} is installed. The console will restart.",
                        )
                        import sys as _sys

                        os.execv(
                            _sys.executable,
                            [_sys.executable, str(Path(__file__).resolve())],
                        )
                    else:
                        os.startfile(archive.parent)
                elif answer is False and page:
                    pref = _updates_pref()
                    try:
                        pref.parent.mkdir(parents=True, exist_ok=True)
                        json.dump(
                            {"version": APP_VERSION, "skip": tag_name},
                            pref.open("w", encoding="utf-8"),
                        )
                    except OSError:
                        pass

            app.after(0, ask)
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            # Offline, rate-capped, or an odd answer: a failed check is
            # silent, and the next launch asks again.
            return

    threading.Thread(target=worker, daemon=True).start()


def local_ip() -> str:
    """Best guess at this PC's LAN address, for the URL a phone should use."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def _enable_dpi_awareness() -> None:
    """Ask Windows for real pixels instead of a bitmap-scaled window."""
    if sys.platform != "win32":
        return
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)  # per-monitor v1
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass


def main() -> int:
    _enable_dpi_awareness()
    app = DesktopApp(DEFAULT_PORT)
    _start_update_check(app)
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
