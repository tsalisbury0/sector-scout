# Sector Scout

An Android app that reads the phone's own modem and shows what it is actually
seeing: every SIM's serving cell, its signal bars, band, channel, uplink and
downlink frequencies, and the neighbour cells around it. A small Windows console
shows the same readings on a PC and can feed test readings to a phone.

## Download

Nothing built is stored in this repository. Both files come from the Releases
page:

**[Download the latest release](https://github.com/tsalisbury0/sector-scout/releases/latest)**

- **Windows app** — `Sector Scout Desktop Setup <version>.exe`. Run the
  installer and it appears in the Start menu; it needs no Python and no
  anything else installed.
- **Android app** — `sector-scout-<version>.apk`. Sideload it: open the file on
  the phone and allow installs from that source. It is signed with Android's
  debug key, so it installs fine but is not a Play Store upload.
- **Desktop console** — `sector-scout-desktop-<version>.zip`. Unzip it, keeping
  `bands.json` in the same folder as the `desktop` directory, then run:

  ```
  python desktop\sector_scout_desktop.py
  ```

  Python 3 is all it needs. Bluetooth sharing and watching need one extra
  package: `pip install -r desktop/requirements.txt`. Everything else is
  standard library.

## What the app shows

- Per SIM: serving cell (eNB/gNB and sector), TAC, PCI, band, channel, downlink
  and uplink frequencies, PLMN, and a five-bar signal meter.
- Every neighbour cell the radio can hear, strongest first.
- NSA and SA 5G, with a separate meter for the LTE anchor and the 5G leg.
- Optional carrier detail through [Shizuku](https://shizuku.rikka.app/): the
  band and width of **every** aggregated carrier, the aggregate, and the QCI of
  the data bearer.
- Sharing with another phone over Wi-Fi or Bluetooth, so a second phone or the
  desktop console can watch this one.

Dual SIM phones get one swipeable page per SIM.

## Adding a PLMN

Carrier names are not built into the app. They come from a list in
[`tsalisbury0/private_plmn`](https://github.com/tsalisbury0/private_plmn).

If your network is missing, shows the wrong name, or needs a bar offset or a
satellite / LTE-M tag, open an issue here:

**https://github.com/tsalisbury0/sector-scout/issues/new**

Please include:

- the PLMN, for example `310-260`
- the name it should show
- anything unusual about the network (satellite link, LTE-M only, regional
  carrier)

## Building it yourself

```
flutter pub get
flutter run                  # on a connected phone
flutter build apk --release  # writes build/app/outputs/flutter-apk/
```

The release APK and the desktop zip are built by
`.github/workflows/release.yml` whenever a `v*` tag is pushed, and attached to
that release.

## Desktop console

`desktop/sector_scout_desktop.py` does two jobs:

- **Test source** — serves the app's own `/snapshot` JSON on port 41729, so a
  phone can watch this PC and try out badges, bands and layouts without a modem.
- **Phones** — polls phones that have sharing turned on and draws their readings
  side by side, which the phone app cannot do (it watches one peer at a time).

## Desktop

The desktop build is the same Flutter app: on Windows it opens
`lib/screens/desktop_home.dart` instead of the phone screen, which draws one
card per watched phone side by side using the same `ServingView` rows,
`SignalBars` and `TechBadge` the phone uses, so the two cannot drift apart.

```
flutter run -d windows
flutter build windows --release
```

Watching a phone is the same as on the handset: the peer must have sharing on,
and the desktop polls `http://<phone>:41729/snapshot` every two seconds.

Building for Windows needs Visual Studio's **Desktop development with C++**
workload; Flutter's doctor reports the toolchain as incomplete until it is
installed.

## Native Windows app

`native/SectorScout` is the console rewritten for Windows in .NET 10 with WPF:
a real executable, no Python at runtime. It reads the same `bands.json`, serves
the same test source on 41729 and draws one card per phone side by side. Build
and run it with:

```
dotnet build native/SectorScout/SectorScout.csproj -c Release
```

It covers watching phones over Wi-Fi and the test source. Bluetooth watching,
the scenario editor and the display corrections are still only in the Python
console for now.

## Carrier detail (Shizuku)

The width of each aggregated carrier, and the QCI of the data bearer, are not in
any public Android API. They sit behind hidden telephony calls that only the
shell user may make. The app reads them through Shizuku: a Shizuku user service
runs this app's own code as uid 2000 (adb) or 0 (root) and answers one JSON
reading per SIM.

1. Install Shizuku, and start it once over adb — or from Android 11's wireless
   debugging, with no computer involved.
2. Open Settings in this app and grant the reader access.

With that, the signal card gains `Bandwidth (CA)`, `Carriers` and `QCI` rows,
and the LAN dashboard and desktop app show them too. Without it nothing breaks:
the rows are simply absent and every other reading is unchanged. The reader is
read-only — it reports what the modem already knows and changes nothing on the
radio.

## Permissions

Android treats cell data as location data, so the app needs **fine location**
with **location services switched on**, plus **phone state** for the SIM list.
Readings stay on the phone; nothing is uploaded anywhere.

## Tests

```
flutter test
cd android && ./gradlew :app:testDebugUnitTest
```
