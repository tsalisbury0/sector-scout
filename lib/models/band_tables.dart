// GENERATED FILE — do not edit by hand.
//
// Produced by `tool/gen_bands.py` from 3GPP TS 36.101 and TS 38.104, so the
// desktop test source and the app decode a channel the same way. Regenerate
// after updating `tool/banddata`.
//
// `first`/`last` are channel numbers (EARFCN for LTE, NR-ARFCN for NR) and
// `dlLow`/`ulLow` are the lowest frequencies of the band's blocks in MHz.

/// How a band pairs its two directions.
enum BandMode {
  /// Separate uplink and downlink blocks.
  fdd,

  /// One block, used for both directions.
  tdd,

  /// Downlink only: no uplink exists on this band (band 29, n67…).
  sdl,
}

/// One band's channel window and its lowest frequencies.
class BandPlan {
  const BandPlan(
    this.first,
    this.last,
    this.dlLow,
    this.ulLow,
    this.ulHigh,
    this.mode,
  );

  final int first;
  final int last;
  final double dlLow;

  /// Lowest uplink frequency, or null on a downlink-only band.
  final double? ulLow;

  /// Highest uplink frequency, for the bands whose uplink block is narrower
  /// than the downlink one (66 and 70 on LTE, n66 on NR).
  final double? ulHigh;
  final BandMode mode;

  bool get isTdd => mode == BandMode.tdd;
  bool get isDlOnly => ulLow == null;

  /// Distance from the downlink block to the uplink one, in MHz.
  double? get uplinkOffset => ulLow == null ? null : ulLow! - dlLow;
}

/// LTE bands (TS 36.101), by band number.
const Map<int, BandPlan> lteBandPlans = {
  1: BandPlan(0, 599, 2110, 1920, 1980, BandMode.fdd),
  2: BandPlan(600, 1199, 1930, 1850, 1910, BandMode.fdd),
  3: BandPlan(1200, 1949, 1805, 1710, 1785, BandMode.fdd),
  4: BandPlan(1950, 2399, 2110, 1710, 1755, BandMode.fdd),
  5: BandPlan(2400, 2649, 869, 824, 849, BandMode.fdd),
  6: BandPlan(2650, 2749, 875, 830, 840, BandMode.fdd),
  7: BandPlan(2750, 3449, 2620, 2500, 2570, BandMode.fdd),
  8: BandPlan(3450, 3799, 925, 880, 915, BandMode.fdd),
  9: BandPlan(3800, 4149, 1844.9, 1749.9, 1784.9, BandMode.fdd),
  10: BandPlan(4150, 4749, 2110, 1710, 1770, BandMode.fdd),
  11: BandPlan(4750, 4949, 1475.9, 1427.9, 1447.9, BandMode.fdd),
  12: BandPlan(5010, 5179, 729, 699, 716, BandMode.fdd),
  13: BandPlan(5180, 5279, 746, 777, 787, BandMode.fdd),
  14: BandPlan(5280, 5379, 758, 788, 798, BandMode.fdd),
  17: BandPlan(5730, 5849, 734, 704, 716, BandMode.fdd),
  18: BandPlan(5850, 5999, 860, 815, 830, BandMode.fdd),
  19: BandPlan(6000, 6149, 875, 830, 845, BandMode.fdd),
  20: BandPlan(6150, 6449, 791, 832, 862, BandMode.fdd),
  21: BandPlan(6450, 6599, 1495.9, 1447.9, 1462.9, BandMode.fdd),
  22: BandPlan(6600, 7399, 3510, 3410, 3490, BandMode.fdd),
  23: BandPlan(7500, 7699, 2180, 2000, 2020, BandMode.fdd),
  24: BandPlan(7700, 8039, 1525, 1626.5, 1660.5, BandMode.fdd),
  25: BandPlan(8040, 8689, 1930, 1850, 1915, BandMode.fdd),
  26: BandPlan(8690, 9039, 859, 814, 849, BandMode.fdd),
  27: BandPlan(9040, 9209, 852, 807, 824, BandMode.fdd),
  28: BandPlan(9210, 9659, 758, 703, 748, BandMode.fdd),
  29: BandPlan(9660, 9769, 717, null, null, BandMode.sdl),
  30: BandPlan(9770, 9869, 2350, 2305, 2315, BandMode.fdd),
  31: BandPlan(9870, 9919, 462.5, 452.5, 457.5, BandMode.fdd),
  32: BandPlan(9920, 10359, 1452, null, null, BandMode.sdl),
  33: BandPlan(36000, 36199, 1900, 1900, 1920, BandMode.tdd),
  34: BandPlan(36200, 36349, 2010, 2010, 2025, BandMode.tdd),
  35: BandPlan(36350, 36949, 1850, 1850, 1910, BandMode.tdd),
  36: BandPlan(36950, 37549, 1930, 1930, 1990, BandMode.tdd),
  37: BandPlan(37550, 37749, 1910, 1910, 1930, BandMode.tdd),
  38: BandPlan(37750, 38249, 2570, 2570, 2620, BandMode.tdd),
  39: BandPlan(38250, 38649, 1880, 1880, 1920, BandMode.tdd),
  40: BandPlan(38650, 39649, 2300, 2300, 2400, BandMode.tdd),
  41: BandPlan(39650, 41589, 2496, 2496, 2690, BandMode.tdd),
  42: BandPlan(41590, 43589, 3400, 3400, 3600, BandMode.tdd),
  43: BandPlan(43590, 45589, 3600, 3600, 3800, BandMode.tdd),
  44: BandPlan(45590, 46589, 703, 703, 803, BandMode.tdd),
  45: BandPlan(46590, 46789, 1447, 1447, 1467, BandMode.tdd),
  46: BandPlan(46790, 54539, 5150, 5150, 5925, BandMode.tdd),
  47: BandPlan(54540, 55239, 5855, 5855, 5925, BandMode.tdd),
  48: BandPlan(55240, 56739, 3550, 3550, 3700, BandMode.tdd),
  49: BandPlan(56740, 58239, 3550, 3550, 3700, BandMode.tdd),
  50: BandPlan(58240, 59089, 1432, 1432, 1517, BandMode.tdd),
  51: BandPlan(59090, 59139, 1427, 1427, 1432, BandMode.tdd),
  52: BandPlan(59140, 60139, 3300, 3300, 3400, BandMode.tdd),
  53: BandPlan(60140, 60254, 2483.5, 2483.5, 2495, BandMode.tdd),
  54: BandPlan(60255, 60304, 1670, 1670, 1675, BandMode.tdd),
  65: BandPlan(65536, 66435, 2110, 1920, 2010, BandMode.fdd),
  66: BandPlan(66436, 67335, 2110, 1710, 1780, BandMode.fdd),
  67: BandPlan(67336, 67535, 738, null, null, BandMode.sdl),
  68: BandPlan(67536, 67835, 753, 698, 728, BandMode.fdd),
  69: BandPlan(67836, 68335, 2570, null, null, BandMode.sdl),
  70: BandPlan(68336, 68585, 1995, 1695, 1710, BandMode.fdd),
  71: BandPlan(68586, 68935, 617, 663, 698, BandMode.fdd),
  72: BandPlan(68936, 68985, 461, 451, 456, BandMode.fdd),
  73: BandPlan(68986, 69035, 460, 450, 455, BandMode.fdd),
  74: BandPlan(69036, 69465, 1475, 1427, 1470, BandMode.fdd),
  75: BandPlan(69466, 70315, 1432, null, null, BandMode.sdl),
  76: BandPlan(70316, 70365, 1427, null, null, BandMode.sdl),
  85: BandPlan(70366, 70545, 728, 698, 716, BandMode.fdd),
  87: BandPlan(70546, 70595, 420, 410, 415, BandMode.fdd),
  88: BandPlan(70596, 70645, 422, 412, 417, BandMode.fdd),
  103: BandPlan(70646, 70655, 757, 787, 788, BandMode.fdd),
  106: BandPlan(70656, 70705, 935, 896, 901, BandMode.fdd),
};

/// NR bands (TS 38.104), by band number.
const Map<int, BandPlan> nrBandPlans = {
  1: BandPlan(422000, 434000, 2110, 1920, 1980, BandMode.fdd),
  2: BandPlan(386000, 398000, 1930, 1850, 1910, BandMode.fdd),
  3: BandPlan(361000, 376000, 1805, 1710, 1785, BandMode.fdd),
  5: BandPlan(173800, 178800, 869, 824, 849, BandMode.fdd),
  7: BandPlan(524000, 538000, 2620, 2500, 2570, BandMode.fdd),
  8: BandPlan(185000, 192000, 925, 880, 915, BandMode.fdd),
  12: BandPlan(145800, 149200, 729, 699, 716, BandMode.fdd),
  13: BandPlan(149200, 151200, 746, 777, 787, BandMode.fdd),
  14: BandPlan(151600, 153600, 758, 788, 798, BandMode.fdd),
  18: BandPlan(172000, 175000, 860, 815, 830, BandMode.fdd),
  20: BandPlan(158200, 164200, 791, 832, 862, BandMode.fdd),
  24: BandPlan(305000, 311800, 1525, null, null, BandMode.sdl),
  25: BandPlan(386000, 399000, 1930, 1850, 1915, BandMode.fdd),
  26: BandPlan(171800, 178800, 859, 814, 849, BandMode.fdd),
  28: BandPlan(151600, 160600, 758, 703, 748, BandMode.fdd),
  29: BandPlan(143400, 145600, 717, null, null, BandMode.sdl),
  30: BandPlan(470000, 472000, 2350, 2305, 2315, BandMode.fdd),
  34: BandPlan(402000, 405000, 2010, 2010, 2025, BandMode.tdd),
  38: BandPlan(514000, 524000, 2570, 2570, 2620, BandMode.tdd),
  39: BandPlan(376000, 384000, 1880, 1880, 1920, BandMode.tdd),
  40: BandPlan(460000, 480000, 2300, 2300, 2400, BandMode.tdd),
  41: BandPlan(499200, 538000, 2496, 2496, 2690, BandMode.tdd),
  46: BandPlan(743333, 795000, 5150, 5150, 5925, BandMode.tdd),
  48: BandPlan(636667, 646667, 3550, 3550, 3700, BandMode.tdd),
  50: BandPlan(286400, 303400, 1432, 1432, 1517, BandMode.tdd),
  51: BandPlan(285400, 286400, 1427, 1427, 1432, BandMode.tdd),
  54: BandPlan(334000, 335000, 1670, 1670, 1675, BandMode.tdd),
  65: BandPlan(422000, 440000, 2110, 1920, 2010, BandMode.fdd),
  66: BandPlan(422000, 440000, 2110, 1710, 1780, BandMode.fdd),
  67: BandPlan(147600, 151600, 738, null, null, BandMode.sdl),
  70: BandPlan(399000, 404000, 1995, 1695, 1710, BandMode.fdd),
  71: BandPlan(123400, 130400, 617, 663, 698, BandMode.fdd),
  72: BandPlan(92200, 93200, 461, 451, 456, BandMode.fdd),
  74: BandPlan(295000, 303600, 1475, 1427, 1470, BandMode.fdd),
  75: BandPlan(286400, 303400, 1432, null, null, BandMode.sdl),
  76: BandPlan(285400, 286400, 1427, null, null, BandMode.sdl),
  77: BandPlan(620000, 680000, 3300, 3300, 4200, BandMode.tdd),
  78: BandPlan(620000, 653333, 3300, 3300, 3800, BandMode.tdd),
  79: BandPlan(693333, 733333, 4400, 4400, 5000, BandMode.tdd),
  85: BandPlan(145600, 149200, 728, 698, 716, BandMode.fdd),
  90: BandPlan(499200, 538000, 2496, 2496, 2690, BandMode.tdd),
  91: BandPlan(285400, 286400, 1427, 832, 862, BandMode.fdd),
  92: BandPlan(286400, 303400, 1432, 832, 862, BandMode.fdd),
  93: BandPlan(285400, 286400, 1427, 880, 915, BandMode.fdd),
  94: BandPlan(286400, 303400, 1432, 880, 915, BandMode.fdd),
  96: BandPlan(795000, 875000, 5925, 5925, 7125, BandMode.tdd),
  101: BandPlan(380000, 382000, 1900, 1900, 1910, BandMode.tdd),
  102: BandPlan(795000, 828333, 5925, 5925, 6425, BandMode.tdd),
  104: BandPlan(828333, 875000, 6425, 6425, 7125, BandMode.tdd),
  105: BandPlan(122400, 130400, 612, 663, 703, BandMode.fdd),
  106: BandPlan(187000, 188000, 935, 896, 901, BandMode.fdd),
  109: BandPlan(286400, 303400, 1432, 703, 733, BandMode.fdd),
  257: BandPlan(2054166, 2104166, 26500, 26500, 29500, BandMode.tdd),
  258: BandPlan(2016667, 2070832, 24250, 24250, 27500, BandMode.tdd),
  259: BandPlan(2270832, 2337499, 39500, 39500, 43500, BandMode.tdd),
  260: BandPlan(2229166, 2279166, 37000, 37000, 40000, BandMode.tdd),
  261: BandPlan(2070832, 2084999, 27500, 27500, 28350, BandMode.tdd),
  262: BandPlan(2399166, 2415832, 47200, 47200, 48200, BandMode.tdd),
  263: BandPlan(2562499, 2795832, 57000, 57000, 71000, BandMode.tdd),
};
