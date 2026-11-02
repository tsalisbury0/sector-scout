/// Switches for the band corrections, set on the Settings page.
///
/// They sit here rather than being threaded through every call because the
/// corrections are read by plain getters on `CellTower`, evaluated wherever a
/// cell is drawn — the serving card, the neighbour rows, a remote phone's JSON.
/// One source of truth keeps those in step, and the Settings page only has to
/// flip a flag and rebuild.
class BandFilters {
  const BandFilters._();

  /// T-Mobile's narrower-band corrections: n38 → n41 and n2 → n25.
  static bool tmobileBands = true;

  /// A CBRS carrier (3550–3700 MHz) named n77 by the modem reads as n48.
  static bool cbrs = true;

  /// Read the 313-700 carrier as **B106** (Anterix numbering) instead of the
  /// band 8 the modem reports.
  ///
  /// This used to be a separate build chosen at compile time; it is a switch
  /// now, so one APK serves every phone and the numbering survives a reinstall
  /// rather than depending on which file was sideloaded. Off by default — every
  /// other network, and every other band, keeps its 3GPP label.
  static bool anterixB106 = false;

  /// Restores the defaults, so one test cannot leak a switch into the next.
  static void reset() {
    tmobileBands = true;
    cbrs = true;
    anterixB106 = false;
  }
}
