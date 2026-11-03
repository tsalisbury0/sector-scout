import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/cell_snapshot.dart';
import '../services/ble_link.dart';
import '../services/carrier_names.dart';
import '../services/cell_tower_service.dart';
import '../services/lan_discovery.dart';
import '../services/lan_server.dart';
import '../services/remote_client.dart';
import '../services/serving_view.dart';
import '../services/signal_notification.dart';
import 'settings_screen.dart';
import '../theme/app_colors.dart';
import '../widgets/signal_bars.dart';
import '../widgets/tech_badge.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// How the app reaches another phone.
enum RemoteTransport { wifi, ble }

/// Outcome of starting a share: the peer-visible name, or why it failed.
class ShareStartResult {
  const ShareStartResult({this.name, this.error});

  final String? name;
  final String? error;
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final CellTowerService _service = CellTowerService();

  StreamSubscription<CellSnapshot>? _subscription;
  CellSnapshot? _snapshot;
  PermissionStatus? _locationStatus;
  String? _error;
  bool _bootstrapped = false;
  bool _live = false;

  /// One page per SIM, swiped left/right.
  final PageController _pageController = PageController();
  int _pageIndex = 0;

  /// Optional Wi-Fi share of the current reading.
  final LanSharingServer _share = LanSharingServer();
  bool _sharing = false;

  /// Optional Bluetooth share, for when there is no Wi-Fi to join.
  final BleShareLink _bleShare = BleShareLink();
  bool _bleSharing = false;

  /// Warnings the user has closed, keyed per SIM slot. Cleared automatically
  /// once that slot reports cells again, so a later dropout is announced.
  final Set<String> _dismissedNotices = <String>{};

  /// Optional pinned notification carrying this phone's own signal.
  final SignalNotification _notification = SignalNotification();
  bool _notificationOn = false;

  /// Optional view of another phone's reading, over Wi-Fi or Bluetooth.
  RemoteClient? _remote;
  BleClient? _bleRemote;

  /// What the banner calls the peer: an address, or a Bluetooth name.
  String? _remoteLabel;
  CellSnapshot? _remoteSnapshot;
  String? _remoteError;
  Timer? _remoteTimer;
  bool _polling = false;

  /// Consecutive Bluetooth polls that returned nothing, so a dropped link is
  /// reported instead of leaving a stale reading under a LIVE chip.
  int _bleMisses = 0;

  /// False while Android is free to freeze this app in the background, which
  /// is what makes the pinned notification go stale.
  bool _backgroundExempt = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    _loadCarrierNames();
    _notification.isOn().then((on) {
      if (mounted && on != _notificationOn) {
        setState(() => _notificationOn = on);
      }
    });
    _refreshBackgroundState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The battery exemption is granted in a system screen, so the app can only
    // learn the answer once it is back in front.
    if (state == AppLifecycleState.resumed) {
      _refreshBackgroundState();
      _notification.isOn().then((on) {
        if (mounted && on != _notificationOn) {
          setState(() => _notificationOn = on);
        }
      });
    }
  }

  Future<void> _refreshBackgroundState() async {
    final exempt = await _notification.backgroundExempt();
    if (mounted && exempt != _backgroundExempt) {
      setState(() => _backgroundExempt = exempt);
    }
  }

  Future<void> _requestBackgroundExemption() async {
    final opened = await _notification.requestBackgroundExemption();
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Android did not open its battery settings.'),
          backgroundColor: AppColors.surface,
        ),
      );
    }
  }

  /// Loads the PLMN → brand list: the copy stored on the device first (so the
  /// first frame already has names, offline included), then the GitHub file.
  ///
  /// The same list is handed to the pinned notification, which draws itself
  /// natively and keeps running when the app is closed.
  Future<void> _loadCarrierNames() async {
    // Names and the satellite bars offsets travel together, so a phone that
    // starts with no network counts a satellite link the same way.
    final names = await _notification.cachedCarrierNames();
    final boosts = await _notification.cachedCarrierBoosts();
    if (names.isNotEmpty) {
      CarrierNames.seed(names, boosts: boosts);
      if (mounted) setState(() {});
    }

    await CarrierNames.load();
    final table = CarrierNames.table;
    if (table.isNotEmpty) {
      await _notification.pushCarrierNames(table);
      await _notification.pushCarrierFlags(
        CarrierNames.boosts,
        CarrierNames.satellites,
        CarrierNames.lteMs,
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _remoteTimer?.cancel();
    _remote?.dispose();
    _bleRemote?.dispose();
    _pageController.dispose();
    _share.stop();
    _bleShare.stop();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (!_service.isSupported) {
      setState(() {
        _bootstrapped = true;
        _error = 'Cell tower data is only available in the Android build.';
      });
      return;
    }

    final status = await Permission.location.request();
    if (!mounted) return;
    setState(() => _locationStatus = status);

    if (status.isGranted || status.isLimited) {
      // Best effort: unlocks the per-SIM subscription list and operator names.
      try {
        await Permission.phone.request();
      } catch (_) {
        // Devices without telephony simply ignore this.
      }
      if (!mounted) return;
      await _startStreaming();
    }

    if (mounted) setState(() => _bootstrapped = true);
  }

  Future<void> _startStreaming() async {
    await _subscription?.cancel();
    await _refresh();
    _subscription = _service.watch().listen(
      (snapshot) {
        if (!mounted) return;
        _share.update(snapshot);
        if (_bleSharing) _bleShare.update(snapshot);
        setState(() {
          _snapshot = snapshot;
          _error = null;
          _live = true;
          _clearRecoveredNotices(snapshot);
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _error = error.toString();
          _live = false;
        });
      },
    );
  }

  Future<void> _refresh() async {
    if (!CarrierNames.isLoaded) _loadCarrierNames();
    try {
      final snapshot = await _service.snapshot();
      if (!mounted) return;
      _share.update(snapshot);
      if (_bleSharing) _bleShare.update(snapshot);
      setState(() {
        _snapshot = snapshot;
        _error = null;
        _clearRecoveredNotices(snapshot);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  Future<void> _requestPermission() async {
    final status = await Permission.location.request();
    if (!mounted) return;
    setState(() => _locationStatus = status);
    if (status.isGranted || status.isLimited) {
      await _startStreaming();
    }
  }

  /// Opens the share dialog: Wi-Fi or Bluetooth, started or stopped there.
  Future<void> _openShareDialog() async {
    String? wifiUrl;
    if (_sharing) {
      try {
        wifiUrl = await _share.url();
      } on Object {
        wifiUrl = null;
      }
    }
    final needsWifi = (await LanSharingServer.localAddresses()).isEmpty;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _ShareDialog(
        initialTransport: _bleSharing && !_sharing
            ? RemoteTransport.ble
            : RemoteTransport.wifi,
        wifiRunning: _sharing,
        wifiUrl: wifiUrl,
        needsWifi: needsWifi,
        serveDashboard: _share.serveDashboard,
        onDashboardChanged: (value) => _share.serveDashboard = value,
        bleRunning: _bleSharing,
        bleName: _bleShare.name,
        onStart: _startSharing,
        onStop: _stopSharing,
      ),
    );
  }

  /// Starts one transport, returning an error (and the advertiser's name) for
  /// the dialog.
  Future<ShareStartResult> _startSharing(RemoteTransport transport) async {
    if (transport == RemoteTransport.wifi) {
      try {
        await _share.start(snapshot: _snapshot);
        if (mounted) setState(() => _sharing = true);
        return const ShareStartResult();
      } on Object catch (error) {
        return ShareStartResult(error: '$error');
      }
    }

    final started = await _bleShare.start();
    if (!started.ok) {
      return ShareStartResult(
        error: started.error ?? 'Bluetooth sharing did not start.',
      );
    }

    // Advertising answers asynchronously, and a phone or ROM can refuse it, so
    // the switch only follows a confirmed advertiser.
    var running = false;
    for (var attempt = 0; attempt < 8 && !running; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      running = await _bleShare.isRunning();
    }
    if (!running) {
      return const ShareStartResult(
        error: 'Android did not start the Bluetooth advertisement.',
      );
    }

    if (mounted) setState(() => _bleSharing = true);
    if (_snapshot != null) await _bleShare.update(_snapshot!);
    return ShareStartResult(name: _bleShare.name ?? started.name);
  }

  Future<void> _stopSharing(RemoteTransport transport) async {
    if (transport == RemoteTransport.wifi) {
      await _share.stop();
      if (mounted) setState(() => _sharing = false);
      return;
    }
    await _bleShare.stop();
    if (mounted) setState(() => _bleSharing = false);
  }

  /// Opens the settings and re-reads the state it may have changed.
  ///
  /// The band switches are plain flags on [BandFilters], so a rebuild is all
  /// the cards need; the notification is owned by the service, so its switch
  /// state is read back rather than assumed.
  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    if (!mounted) return;
    final on = await _notification.isOn();
    if (!mounted) return;
    setState(() => _notificationOn = on);
    _refreshBackgroundState();
  }

  // -------------------------------------------------------------------------
  // Pinned notification
  // -------------------------------------------------------------------------

  /// Pins or unpins the signal notification.
  ///
  /// The switch follows the service, not the tap: Android can refuse (not
  /// notification permission) or decline to start the service, and the card
  /// must not claim it is pinned when it is not.

  // -------------------------------------------------------------------------
  // Remote viewing (another phone, same Wi-Fi)
  // -------------------------------------------------------------------------

  bool get _isRemote => _remote != null || _bleRemote != null;

  bool get _remoteTransport => _bleRemote != null;

  bool get _remoteLive =>
      _isRemote && _remoteSnapshot != null && _remoteError == null;

  /// The reading on screen: the peer's when watching remotely, else local.
  CellSnapshot? get _display => _isRemote ? _remoteSnapshot : _snapshot;

  Future<void> _openRemoteDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _RemoteDialog(
        current: _remote?.baseUri.toString(),
        currentBle: _bleRemote?.peer,
        onConnect: _connectRemote,
        onConnectBle: _connectBle,
        onDisconnect: _disconnectRemote,
      ),
    );
  }

  /// Validates and opens the peer, returning an error message or null.
  Future<String?> _connectRemote(Uri uri) async {
    final previous = _remote;
    final client = RemoteClient(uri);
    try {
      final snapshot = await client.fetch();
      if (!mounted) {
        client.dispose();
        return null;
      }
      _remoteTimer?.cancel();
      previous?.dispose();
      _bleRemote?.dispose();
      setState(() {
        _remote = client;
        _bleRemote = null;
        _remoteLabel = uri.host;
        _remoteSnapshot = snapshot;
        _remoteError = null;
      });
      _remoteTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _pollRemote(),
      );
      return null;
    } on RemoteException catch (error) {
      client.dispose();
      return error.message;
    } on Object {
      client.dispose();
      return 'Could not read ${uri.host}.';
    }
  }

  /// Opens a peer over Bluetooth, returning an error message or null.
  ///
  /// The advertiser only answers with a payload once it has a reading, so the
  /// first fetch is retried for a few seconds before giving up.
  Future<String?> _connectBle(BlePeer peer) async {
    final client = BleClient(peer);
    try {
      final name = await client.connect();
      CellSnapshot? snapshot;
      for (var attempt = 0; attempt < 8 && snapshot == null; attempt++) {
        snapshot = await client.fetch();
        if (snapshot == null) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      if (snapshot == null) {
        client.dispose();
        return '${peer.label} answered over Bluetooth but has no reading yet.';
      }
      if (!mounted) {
        client.dispose();
        return null;
      }
      _remoteTimer?.cancel();
      _remote?.dispose();
      _bleRemote?.dispose();
      _bleMisses = 0;
      setState(() {
        _remote = null;
        _bleRemote = client;
        // The scan may only know the address; the connected peer reports its
        // own Bluetooth name, which is the model on most phones.
        _remoteLabel = (name == null || name.isEmpty) ? peer.label : name;
        _remoteSnapshot = snapshot;
        _remoteError = null;
      });
      _remoteTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _pollRemote(),
      );
      return null;
    } on RemoteException catch (error) {
      client.dispose();
      return error.message;
    } on Object catch (error) {
      client.dispose();
      return 'Bluetooth link failed: $error';
    }
  }

  void _disconnectRemote() {
    _remoteTimer?.cancel();
    _remoteTimer = null;
    _remote?.dispose();
    _remote = null;
    _bleRemote?.dispose();
    _bleRemote = null;
    _bleMisses = 0;
    if (!mounted) return;
    setState(() {
      _remoteLabel = null;
      _remoteSnapshot = null;
      _remoteError = null;
    });
  }

  /// Pulls the peer's latest reading. Overlapping polls are skipped so a slow
  /// peer cannot queue up requests.
  Future<void> _pollRemote() async {
    final wifi = _remote;
    final bluetooth = _bleRemote;
    if ((wifi == null && bluetooth == null) || _polling) return;
    final label = wifi?.baseUri.host ?? _remoteLabel ?? 'the other phone';

    bool stillCurrent() {
      if (!mounted) return false;
      if (wifi != null) return _remote == wifi;
      return _bleRemote == bluetooth;
    }

    _polling = true;
    try {
      final snapshot = await (wifi?.fetch() ?? bluetooth!.fetch());
      // Bluetooth has nothing to give while the peer is idle; keep the last
      // reading instead of blanking the screen, but say so once it stops
      // answering altogether.
      if (snapshot == null) {
        if (bluetooth != null && stillCurrent()) {
          _bleMisses++;
          if (_bleMisses >= 3) {
            setState(
              () => _remoteError = 'Lost contact with $label over Bluetooth.',
            );
          }
        }
        return;
      }
      if (!stillCurrent()) return;
      _bleMisses = 0;
      setState(() {
        _remoteSnapshot = snapshot;
        _remoteError = null;
        _clearRecoveredNotices(snapshot);
      });
    } on RemoteException catch (error) {
      if (!stillCurrent()) return;
      setState(() => _remoteError = error.message);
    } on Object {
      if (!stillCurrent()) return;
      setState(() => _remoteError = 'Lost contact with $label.');
    } finally {
      _polling = false;
    }
  }

  /// Drops a slot's dismissed warnings once it has cells again.
  void _clearRecoveredNotices(CellSnapshot snapshot) {
    if (_dismissedNotices.isEmpty) return;
    for (final sim in snapshot.sims) {
      if (sim.hasSim && sim.cells.isNotEmpty) {
        _dismissedNotices.remove('sim-${sim.slotIndex}');
      }
    }
  }

  bool _isDismissed(SimReading sim) =>
      _dismissedNotices.contains('sim-${sim.slotIndex}');

  void _dismissNotice(SimReading sim) {
    setState(() => _dismissedNotices.add('sim-${sim.slotIndex}'));
  }

  bool get _granted =>
      (_locationStatus?.isGranted ?? false) ||
      (_locationStatus?.isLimited ?? false) ||
      (_snapshot?.permissionGranted ?? false);

  @override
  Widget build(BuildContext context) {
    final snapshot = _display;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Sector Scout',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            Text(
              _isRemote
                  ? 'Remote · ${_remoteLabel ?? 'phone'}'
                  : _subtitle(snapshot),
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ],
        ),
        actions: [
          if (_isRemote ? _remoteLive : _live)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: _LiveChip(),
            ),
          IconButton(
            onPressed: _openRemoteDialog,
            tooltip: _isRemote
                ? 'Watching another phone'
                : 'Watch another phone',
            // Four actions plus the live chip: compact so the app name still
            // fits beside them on a 360 dp screen.
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 40, height: 44),
            icon: Icon(
              _isRemote ? Icons.devices_other_rounded : Icons.phonelink_rounded,
              color: _isRemote ? AppColors.accent : null,
            ),
          ),
          IconButton(
            onPressed: _openShareDialog,
            tooltip: _sharing || _bleSharing
                ? 'Sharing this phone\'s reading'
                : 'Share this phone\'s reading',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 40, height: 44),
            icon: Icon(
              _sharing
                  ? Icons.wifi_tethering_rounded
                  : _bleSharing
                  ? Icons.bluetooth_connected_rounded
                  : Icons.share_rounded,
              color: _sharing || _bleSharing ? AppColors.accent : null,
            ),
          ),
          // No refresh button: pull down on the page, and the stream updates
          // the cards on its own every few seconds.
          IconButton(
            onPressed: _openSettings,
            tooltip: 'Settings',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 40, height: 44),
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _isRemote
          ? Column(
              children: [
                _RemoteBanner(
                  label: _remoteLabel ?? 'Phone',
                  viaBluetooth: _remoteTransport,
                  deviceModel: _remoteSnapshot?.deviceModel ?? '',
                  error: _remoteError,
                  onDisconnect: _disconnectRemote,
                ),
                Expanded(child: _pager(snapshot)),
              ],
            )
          : _pager(snapshot),
    );
  }

  String _subtitle(CellSnapshot? snapshot) {
    if (snapshot == null) return 'Android telephony';
    final model = snapshot.deviceModel.isEmpty
        ? 'Android'
        : snapshot.deviceModel;
    final sims = snapshot.activeSims.length;
    return '$model · $sims SIM${sims == 1 ? '' : 's'} · ${snapshot.cellCount} cells';
  }

  /// The body: one scrolling page per SIM, swiped left and right. A single-SIM
  /// device keeps the plain scrolling view.
  Widget _pager(CellSnapshot? snapshot) {
    final pages = _pages(snapshot);
    if (pages.length == 1) return _scroll(pages.single);

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: pages.length,
            onPageChanged: (index) {
              if (index != _pageIndex) setState(() => _pageIndex = index);
            },
            itemBuilder: (context, index) =>
                _scroll(pages[index], pageIndex: index),
          ),
        ),
        _PageDots(count: pages.length, index: _pageIndex),
      ],
    );
  }

  Widget _scroll(List<Widget> children, {int? pageIndex}) {
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: _isRemote ? _pollRemote : _refresh,
      child: ListView(
        key: pageIndex == null
            ? null
            : PageStorageKey<String>('sim-$pageIndex'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          (pageIndex == null ? 32 : 20) +
              MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: children,
      ),
    );
  }

  List<List<Widget>> _pages(CellSnapshot? snapshot) {
    // A remote peer has already granted its own permissions, so the local
    // permission gate and bootstrap state do not apply to it.
    if (_isRemote && snapshot == null) {
      return [
        [
          if (_remoteError != null)
            _ErrorCard(message: _remoteError!)
          else
            const _LoadingCard(),
        ],
      ];
    }
    if (!_isRemote && !_bootstrapped) {
      return const [
        [_LoadingCard()],
      ];
    }
    if (!_isRemote && !_granted) {
      return [
        [_permissionCard()],
      ];
    }

    if (snapshot == null) {
      return [
        [
          if (_error != null) _ErrorCard(message: _error!),
          if (_error == null) const _LoadingCard(),
        ],
      ];
    }

    final sims = snapshot.activeSims.isEmpty
        ? snapshot.sims
        : snapshot.activeSims;
    if (sims.isEmpty) {
      return const [
        [
          _NoticeCard(
            icon: Icons.sim_card_alert_rounded,
            message: 'The modem did not report any SIM slots.',
          ),
        ],
      ];
    }

    // Android exposes a single neighbour scan for the modem; show it once.
    final sharedNeighbours = _sameNeighbours(sims);

    return [
      for (var i = 0; i < sims.length; i++)
        _simPage(
          sims[i],
          snapshot,
          dual: snapshot.isDualSim,
          showNeighbours: !sharedNeighbours || i == 0,
          sharedNeighbours: sharedNeighbours,
          firstSimLabel: sims.first.label,
        ),
    ];
  }

  /// Contents of a single SIM page.
  List<Widget> _simPage(
    SimReading sim,
    CellSnapshot snapshot, {
    required bool dual,
    required bool showNeighbours,
    required bool sharedNeighbours,
    required String firstSimLabel,
  }) {
    // A peer that stops answering keeps its last reading on screen; the banner
    // above already carries the reason, so it is not repeated here.
    final problem = _isRemote ? null : _error;
    return [
      if (problem != null) ...[
        _ErrorCard(message: problem),
        const SizedBox(height: 12),
      ],
      if (!snapshot.locationEnabled) ...[
        const _NoticeCard(
          icon: Icons.location_off_rounded,
          message:
              'Location services are off. Android hides cell identities '
              'from apps while location is disabled — turn it on to see '
              'tower details.',
        ),
        const SizedBox(height: 12),
      ],
      ..._simSection(
        sim,
        snapshot,
        dual: dual,
        showNeighbours: showNeighbours,
        sharedNeighbours: sharedNeighbours,
      ),
      if (!showNeighbours) ...[
        const SizedBox(height: 12),
        _FootNote(
          'The radio scans neighbours once for both slots — the list is on the '
          '$firstSimLabel page.',
        ),
      ],
      if (_notificationOn && !_backgroundExempt) ...[
        const SizedBox(height: 8),
        _BackgroundCard(onAllow: _requestBackgroundExemption),
      ],
      const SizedBox(height: 24),
      _FootNote(
        _isRemote
            ? 'Read over ${_remoteTransport ? 'Bluetooth' : 'the LAN'} from '
                  '${_remoteLabel ?? 'the other phone'}, refreshed every 2 s '
                  'through the same JSON the app serves. ${snapshot.activeSims.length} '
                  'active SIM${snapshot.activeSims.length == 1 ? '' : 's'}.'
            : 'Read from TelephonyManager · '
                  '${snapshot.activeSims.length} active '
                  'SIM${snapshot.activeSims.length == 1 ? '' : 's'}. NSA bars show '
                  'the LTE anchor and the 5G secondary separately; SA uses the '
                  'single NR meter. Neighbour visibility depends on the modem and '
                  'Android version.',
      ),
    ];
  }

  /// True when every slot was handed the same neighbour scan.
  ///
  /// Compares identity only (tech, PCI, band) — never dBm, since the reads
  /// happen moments apart and the level always wobbles.
  bool _sameNeighbours(List<SimReading> sims) {
    if (sims.length < 2) return false;
    List<String> key(SimReading sim) =>
        sim.neighbours
            .map((cell) => '${cell.tech.raw}/${cell.pci}/${cell.bandLabel}')
            .toList()
          ..sort();
    final first = key(sims.first);
    if (first.isEmpty) return false;
    return sims.skip(1).every((sim) {
      final other = key(sim);
      return other.length == first.length &&
          List.generate(
            first.length,
            (i) => other[i] == first[i],
          ).every((m) => m);
    });
  }

  List<Widget> _simSection(
    SimReading sim,
    CellSnapshot snapshot, {
    required bool dual,
    required bool showNeighbours,
    required bool sharedNeighbours,
  }) {
    final prefix = dual ? '${sim.label} · ' : '';
    final problem = sim.problem(locationEnabled: snapshot.locationEnabled);
    final lte = sim.lteServing;
    final nr = sim.nrServing;

    return [
      SimHeaderCard(
        sim: sim,
        dual: dual,
        capturedAt: snapshot.capturedAt,
        carrierName: _carrierName(sim),
      ),
      if ((!sim.hasSim || sim.cells.isEmpty) && !_isDismissed(sim))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _NoticeCard(
            icon: Icons.warning_amber_rounded,
            message: problem ?? 'No cells reported yet.',
            onDismiss: () => _dismissNotice(sim),
          ),
        ),
      // A slot the platform calls empty can still report a cell (the A10e does
      // exactly this), so the modem's own list decides whether there is
      // anything to show.
      if (sim.serving != null) ...[
        const SizedBox(height: 20),
        _SectionLabel(
          sim.isNsa && lte != null && nr != null
              ? '${prefix}4G anchor'
              : '$prefix${sim.isSa ? '5G NR' : 'Serving cell'}',
        ),
        const SizedBox(height: 8),
        _DetailCard(
          // [SimReading.serving] prefers the NR leg so the header meter has a
          // cell to read, but the anchor card must show the LTE cell itself —
          // otherwise an NSA pair renders the 5G card twice and the eNB,
          // sector and anchor band disappear.
          entries: _servingEntries(
            sim.isNsa && lte != null && nr != null ? lte : sim.serving!,
          ),
        ),
        if (sim.isNsa && nr == null) ...[
          const SizedBox(height: 8),
          _FootNote(
            'The platform reports the NR leg connected (NR state: '
            '${sim.nrState.isEmpty ? 'not reported' : sim.nrState}) while '
            'the radio is not exposing an NR cell right now — Samsung only '
            'hands the NR leg to apps while it is carrying data. The 5G '
            'badge is the platform’s word, not a cell: the meter above is '
            'the LTE anchor.',
          ),
        ],
        if (sim.isNsa && lte != null && nr != null) ...[
          const SizedBox(height: 16),
          _SectionLabel('${prefix}5G NR secondary'),
          const SizedBox(height: 8),
          _DetailCard(
            entries: _servingEntries(nr, gnbEstimate: sim.nsaGnbEstimate),
          ),
          if (nr.gnb == null) ...[
            const SizedBox(height: 8),
            _FootNote(
              sim.nsaGnbEstimate != null
                  ? 'This radio hides the NR cell identity while NSA is up, '
                        'so the gNB marked “est.” is derived from the LTE anchor. '
                        'There is no sector to report without the NCI; PCI, band '
                        'and ARFCN are reported directly.'
                  : 'This radio hides the NR cell identity while NSA is up, so '
                        'gNB and sector are unavailable — PCI, band and ARFCN '
                        'still identify the carrier.',
            ),
          ],
        ],
        // LTE B29 is a supplemental downlink: it only shows up once it is
        // aggregated under the primary, and it arrives with no ECI at all, so
        // there is no eNB or sector to draw. CellMapper shows the same carrier
        // and the same gap.
        if (sim.lteSecondaries.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionLabel('${prefix}4G LTE secondary'),
          const SizedBox(height: 8),
          for (final secondary in sim.lteSecondaries) ...[
            _DetailCard(
              entries: _servingEntries(
                secondary,
                fallbackPlmn: sim.registeredPlmn,
              ),
            ),
            const SizedBox(height: 8),
          ],
          const _FootNote(
            'Secondaries are aggregated under the primary LTE cell. Band 29 is '
            'a downlink-only supplemental carrier: the radio reports it with a '
            'PCI, band and channel but no cell identity, so there is no eNB, '
            'sector or TAC to show — and no uplink frequency, because the band '
            'has none. Its MCC/MNC only come through while it is carrying '
            'data, which is why the PLMN falls back to the network the primary '
            'cell is registered on.',
          ),
        ],
        const SizedBox(height: 20),
        _SectionLabel('${prefix}Radio quality'),
        const SizedBox(height: 8),
        _DetailCard(entries: _qualityEntries(sim)),
      ] else if (sim.cells.isNotEmpty) ...[
        // Cells but no registration: on a dual-SIM modem this happens when the
        // other slot is carrying the radio. Say so instead of presenting the
        // neighbour scan as a serving cell.
        const SizedBox(height: 20),
        const _NoticeCard(
          icon: Icons.portable_wifi_off_rounded,
          message:
              'No cell on this SIM is registered right now, so there is no '
              'serving cell to show. Its neighbours are still listed below.',
        ),
      ],
      if (sim.cells.isNotEmpty) ...[
        if (showNeighbours) ...[
          const SizedBox(height: 20),
          _SectionLabel(
            '${prefix}Neighbour cells'
            '${sim.neighbours.isEmpty ? '' : ' (${sim.neighbours.length})'}'
            '${sharedNeighbours ? ' · shared radio' : ''}',
          ),
          const SizedBox(height: 8),
          _NeighbourCard(neighbours: sim.neighbours),
          if (sim.neighbours.any((cell) => cell.cellId == null)) ...[
            const SizedBox(height: 8),
            const _FootNote(
              'Android 12+ hides neighbour cell IDs from apps, so those rows '
              'are identified by PCI and band instead.',
            ),
          ],
        ],
      ],
    ];
  }

  String _carrierName(SimReading sim) => ServingView.carrierName(sim);

  List<MapEntry<String, String>> _servingEntries(
    CellTower cell, {
    int? gnbEstimate,
    String? fallbackPlmn,
  }) =>
      ServingView.entries(
        cell,
        gnbEstimate: gnbEstimate,
        fallbackPlmn: fallbackPlmn,
      );

  List<MapEntry<String, String>> _qualityEntries(SimReading sim) =>
      ServingView.qualityEntries(sim);

  Widget _permissionCard() {
    final permanentlyDenied = _locationStatus?.isPermanentlyDenied ?? false;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.sensors_rounded, size: 32, color: AppColors.accent),
          const SizedBox(height: 16),
          const Text(
            'Location access needed',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Android only reveals cell identity and signal level to apps with '
            'fine-location permission. Nothing is uploaded — readings stay on '
            'this device.',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: permanentlyDenied
                  ? openAppSettings
                  : _requestPermission,
              icon: Icon(
                permanentlyDenied
                    ? Icons.settings_rounded
                    : Icons.my_location_rounded,
              ),
              label: Text(
                permanentlyDenied ? 'Open app settings' : 'Grant permission',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (permanentlyDenied) ...[
            const SizedBox(height: 12),
            const Text(
              'Permission was denied permanently. Enable Location for this app '
              'in system settings, then come back.',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

/// Serving-cell header for one SIM slot.
///
/// NSA shows the LTE anchor and the 5G secondary as two meters; SA and
/// LTE-only use the single meter, exactly as requested.
class SimHeaderCard extends StatelessWidget {
  const SimHeaderCard({
    super.key,
    required this.sim,
    required this.dual,
    required this.capturedAt,
    this.carrierName,
  });

  final SimReading sim;
  final bool dual;
  final DateTime capturedAt;

  /// Brand resolved from the PLMN; falls back to the SIM's own name.
  final String? carrierName;

  @override
  Widget build(BuildContext context) {
    final lte = sim.lteServing;
    final nr = sim.nrServing;
    final serving = sim.serving;
    final badge = badgeForSim(sim);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
        gradient: const LinearGradient(
          colors: [AppColors.surface, AppColors.surfaceAlt],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            carrierName ??
                                (sim.carrierName.isEmpty
                                    ? sim.label
                                    : sim.carrierName),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        // The technology reads as part of the name now: plain
                        // text to its right, then the slot. It stays put when
                        // the mode chip greys out — an LTE anchor with its 5G
                        // leg gone still reads LTE.
                        //
                        // A satellite link shows `SAT` here instead. The two
                        // never appear together: one names the path, the other
                        // names the radio.
                        if (sim.isSatellite) ...[
                          const SizedBox(width: 7),
                          const SatelliteTag(),
                        ] else if (badge != null) ...[
                          const SizedBox(width: 7),
                          TechBadge(label: badge),
                        ],
                        if (dual) ...[
                          const SizedBox(width: 8),
                          _SlotBadge(label: sim.label),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'SERVING CELL',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.1,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              // Green only while the 5G leg is really there: with the NR
              // carrier gone the chip keeps the words but drops the colour.
              // An `lteM`-tagged network reads `4G LTE-M` here instead of
              // `4G LTE`, without claiming the 5G colour.
              _TechChip(
                label: sim.modeLabel,
                // Green while the leg is really up: an NR cell attached, or the
                // platform's own NR state saying CONNECTED.
                attached: (sim.isNsa && nr != null) || sim.nrConnected,
              ),
            ],
          ),
          const SizedBox(height: 22),
          if (sim.isNsa && lte != null && nr != null)
            Row(
              children: [
                Expanded(
                  child: _LegMeter(label: 'LTE anchor', cell: lte),
                ),
                Container(width: 1, height: 62, color: AppColors.border),
                const SizedBox(width: 16),
                Expanded(
                  child: _LegMeter(label: '5G NR', cell: nr),
                ),
              ],
            )
          else
            _PrimaryMeter(cell: serving),
          const SizedBox(height: 18),
          Container(height: 1, color: AppColors.border),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.schedule_rounded,
                size: 13,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Updated ${_clock(capturedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${sim.cells.length} '
                  'cell${sim.cells.length == 1 ? '' : 's'} visible',
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Single meter, used for LTE-only and for SA (5G on its own).
class _PrimaryMeter extends StatelessWidget {
  const _PrimaryMeter({required this.cell});

  final CellTower? cell;

  @override
  Widget build(BuildContext context) {
    final bars = cell?.bars ?? 0;
    final color = AppColors.forBars(bars);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SignalBars(bars: bars, height: 62, barWidth: 11, gap: 6),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    cell?.dbm?.toString() ?? '—',
                    style: monospace.copyWith(
                      fontSize: 34,
                      height: 1,
                      fontWeight: FontWeight.w400,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'dBm',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                SignalQuality.label(bars),
                style: TextStyle(fontSize: 12, color: color),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One leg of an NSA pair: LTE anchor or 5G NR secondary.
class _LegMeter extends StatelessWidget {
  const _LegMeter({required this.label, required this.cell});

  final String label;
  final CellTower cell;

  @override
  Widget build(BuildContext context) {
    final bars = cell.bars;
    final color = AppColors.forBars(bars);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 9.5,
            letterSpacing: 1,
            fontWeight: FontWeight.w600,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SignalBars(bars: bars, height: 40, barWidth: 8, gap: 4),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cell.dbm?.toString() ?? '—',
                    style: monospace.copyWith(
                      fontSize: 21,
                      height: 1,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'dBm',
                    style: TextStyle(fontSize: 9.5, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          SignalQuality.label(bars),
          style: TextStyle(fontSize: 11, color: color),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.entries});

  final List<MapEntry<String, String>> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(height: 1, color: AppColors.border),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entries[i].key,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  Text(
                    entries[i].value,
                    style: monospace.copyWith(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NeighbourCard extends StatelessWidget {
  const _NeighbourCard({required this.neighbours});

  final List<CellTower> neighbours;

  @override
  Widget build(BuildContext context) {
    if (neighbours.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: const Text(
          'The modem is not reporting any neighbour cells right now.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textMuted,
            height: 1.4,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < neighbours.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(height: 1, color: AppColors.border),
              ),
            _NeighbourRow(cell: neighbours[i]),
          ],
        ],
      ),
    );
  }
}

class _NeighbourRow extends StatelessWidget {
  const _NeighbourRow({required this.cell});

  final CellTower cell;

  @override
  Widget build(BuildContext context) {
    final hasCellId = cell.cellId != null;
    // A neighbour that reports an identity is split the same way the serving
    // card splits it, so a row reads `eNB 195007` / `gNB 1053255` rather than
    // an opaque `Cell <eCI>`. The raw identity is only the fallback for a cell
    // whose technology is unknown, where the split cannot be derived.
    final neighbourId = switch (cell.tech) {
      CellTech.lte => cell.enb,
      CellTech.nr => cell.gnb,
      _ => null,
    };
    final title = neighbourId != null
        ? '${cell.tech == CellTech.nr ? 'gNB' : 'eNB'} $neighbourId'
        : hasCellId
        ? 'Cell ${cell.cellId}'
        : (cell.pci != null ? '${cell.pciLabel} ${cell.pci}' : 'Unknown cell');
    final details = [
      if (hasCellId && cell.pci != null) '${cell.pciLabel} ${cell.pci}',
      if (cell.bandLabel != null) cell.bandLabel!,
      if (cell.tac != null) '${cell.tacLabel} ${cell.tac}',
      if (cell.plmn != null) cell.plmn!,
    ].join(' · ');
    // Compact here: the row also carries PCI, band and bars.
    final frequency = ServingView.neighbourFrequency(cell);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              cell.tech.raw.isEmpty ? '?' : cell.tech.raw,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: AppColors.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: monospace.copyWith(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    details,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
                if (frequency != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    frequency,
                    style: monospace.copyWith(
                      fontSize: 10.5,
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            cell.dbm == null ? '—' : '${cell.dbm} dBm',
            style: monospace.copyWith(
              fontSize: 12,
              color: AppColors.forBars(cell.bars),
            ),
          ),
          const SizedBox(width: 12),
          SignalBars(bars: cell.bars, height: 22, barWidth: 4, gap: 3),
        ],
      ),
    );
  }
}

class _SlotBadge extends StatelessWidget {
  const _SlotBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

class _TechChip extends StatelessWidget {
  const _TechChip({required this.label, this.attached = true});

  final String label;

  /// False when the label names 5G but no NR carrier is attached right now —
  /// the platform keeps reporting `NR_NSA` for a while after the leg is gone.
  final bool attached;

  @override
  Widget build(BuildContext context) {
    final is5g = attached && label.contains('5G');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: (is5g ? AppColors.accent : AppColors.textMuted).withValues(
          alpha: 0.12,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (is5g ? AppColors.accent : AppColors.textMuted).withValues(
            alpha: 0.35,
          ),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: is5g ? AppColors.accent : AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _LiveChip extends StatelessWidget {
  const _LiveChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          const Text(
            'LIVE',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.message,
    this.onDismiss,
  });

  final IconData icon;
  final String message;

  /// When set, the card gets a close button and the parent decides to hide it.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: AppColors.textMuted,
              ),
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDismiss,
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              icon: const Icon(
                Icons.close_rounded,
                size: 16,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Offers the battery exemption that stops Android freezing the app.
///
/// A foreground service keeps the notification pinned, but Doze and OEM battery
/// managers still freeze a backgrounded app, which leaves the shade showing a
/// reading from minutes ago. Exempting the app is the supported fix.
class _BackgroundCard extends StatelessWidget {
  const _BackgroundCard({required this.onAllow});

  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.battery_alert_rounded,
            size: 18,
            color: AppColors.warning,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Keep the reading fresh in the background',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Android is optimising this app, so it can freeze while the '
                  'screen is off and the notification goes stale. Allow it to '
                  'run without restrictions.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: onAllow,
            child: const Text(
              'Allow',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppColors.danger,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.accent,
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 10,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w600,
        color: AppColors.textMuted,
      ),
    );
  }
}

class _FootNote extends StatelessWidget {
  const _FootNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        height: 1.5,
        color: Color(0xFF64748B),
      ),
    );
  }
}

String _clock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// Shares this phone's reading, over Wi-Fi or Bluetooth.
///
/// Wi-Fi serves the same JSON on the LAN (plus an optional browser page), and
/// Bluetooth advertises it for a phone with no network to join.
class _ShareDialog extends StatefulWidget {
  const _ShareDialog({
    required this.initialTransport,
    required this.wifiRunning,
    required this.wifiUrl,
    required this.needsWifi,
    required this.serveDashboard,
    required this.onDashboardChanged,
    required this.bleRunning,
    required this.bleName,
    required this.onStart,
    required this.onStop,
  });

  final RemoteTransport initialTransport;
  final bool wifiRunning;
  final String? wifiUrl;
  final bool needsWifi;
  final bool serveDashboard;
  final ValueChanged<bool> onDashboardChanged;
  final bool bleRunning;
  final String? bleName;
  final Future<ShareStartResult> Function(RemoteTransport transport) onStart;
  final Future<void> Function(RemoteTransport transport) onStop;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  late RemoteTransport _transport = widget.initialTransport;
  late bool _wifiRunning = widget.wifiRunning;
  late bool _bleRunning = widget.bleRunning;
  late bool _serveDashboard = widget.serveDashboard;
  late String? _bleName = widget.bleName;
  bool _busy = false;
  String? _error;

  bool get _running =>
      _transport == RemoteTransport.wifi ? _wifiRunning : _bleRunning;

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.onStart(_transport);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result.error;
      if (result.error == null) {
        if (_transport == RemoteTransport.wifi) {
          _wifiRunning = true;
        } else {
          _bleRunning = true;
          _bleName = result.name ?? _bleName;
        }
      }
    });
  }

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final transport = _transport;
    await widget.onStop(transport);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (transport == RemoteTransport.wifi) {
        _wifiRunning = false;
      } else {
        _bleRunning = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Row(
        children: [
          Icon(Icons.share_rounded, color: AppColors.accent, size: 20),
          SizedBox(width: 8),
          Text('Share this reading', style: TextStyle(fontSize: 16)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TransportPicker(
            value: _transport,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _transport = value;
                    _error = null;
                  }),
          ),
          const SizedBox(height: 12),
          if (_transport == RemoteTransport.wifi)
            ..._wifiSection()
          else
            ..._bleSection(),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AppColors.danger,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _running && !_busy ? _stop : null,
          child: const Text('Stop sharing'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  if (_running) {
                    Navigator.of(context).pop();
                  } else {
                    _start();
                  }
                },
          child: Text(_running ? 'Done' : 'Start sharing'),
        ),
      ],
    );
  }

  List<Widget> _wifiSection() {
    final url = widget.wifiUrl;
    return [
      Text(
        _wifiRunning
            ? (_serveDashboard
                  ? 'Open this on another device on the same network:'
                  : 'Point the other app at this JSON endpoint:')
            : 'Serve the reading as JSON on your local network. The other phone '
                  'connects by address.',
        style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
      ),
      if (_wifiRunning && url != null) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: SelectableText(
            url,
            style: monospace.copyWith(fontSize: 14, color: AppColors.accent),
          ),
        ),
      ],
      if (widget.needsWifi) ...[
        const SizedBox(height: 10),
        const Text(
          'This phone is not on Wi-Fi right now — join the same network as the '
          'other device, or use Bluetooth instead.',
          style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.warning),
        ),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        activeThumbColor: AppColors.accent,
        value: _serveDashboard,
        title: const Text(
          'Browser dashboard',
          style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
        ),
        subtitle: const Text(
          'Off serves JSON only',
          style: TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        onChanged: (value) {
          setState(() => _serveDashboard = value);
          widget.onDashboardChanged(value);
        },
      ),
    ];
  }

  List<Widget> _bleSection() {
    final name = _bleName ?? 'this phone';
    return [
      Text(
        _bleRunning
            ? 'Advertising as “$name”. On the other phone choose Watch another '
                  'phone → Bluetooth and pick it from the scan.'
            : 'Advertise the reading over Bluetooth LE. It works with no Wi-Fi '
                  'and no mobile data: keep Bluetooth on for both phones and leave '
                  'the app open here.',
        style: const TextStyle(
          fontSize: 12.5,
          height: 1.4,
          color: AppColors.textMuted,
        ),
      ),
      if (_bleRunning) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.bluetooth_connected_rounded,
                size: 16,
                color: AppColors.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: monospace.copyWith(
                    fontSize: 13,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ];
  }
}

/// Strip above the pages while watching another phone.
class _RemoteBanner extends StatelessWidget {
  const _RemoteBanner({
    required this.label,
    required this.viaBluetooth,
    required this.deviceModel,
    required this.error,
    required this.onDisconnect,
  });

  /// Address for Wi-Fi, Bluetooth name for BLE.
  final String label;
  final bool viaBluetooth;
  final String deviceModel;
  final String? error;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final lost = error != null;
    final tint = lost ? AppColors.warning : AppColors.accent;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            viaBluetooth
                ? Icons.bluetooth_connected_rounded
                : Icons.devices_other_rounded,
            size: 16,
            color: tint,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  lost
                      ? 'Connection lost · $label'
                      : '${deviceModel.isEmpty ? 'Remote phone' : deviceModel} · '
                            '$label${viaBluetooth ? ' (Bluetooth)' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: tint,
                  ),
                ),
                if (lost)
                  Text(
                    error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.3,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onDisconnect,
            tooltip: 'Stop watching',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Connects to another phone's share endpoint.
class _RemoteDialog extends StatefulWidget {
  const _RemoteDialog({
    required this.current,
    required this.currentBle,
    required this.onConnect,
    required this.onConnectBle,
    required this.onDisconnect,
  });

  final String? current;
  final BlePeer? currentBle;

  /// Returns an error message, or null when the peer answered.
  final Future<String?> Function(Uri uri) onConnect;
  final Future<String?> Function(BlePeer peer) onConnectBle;
  final VoidCallback onDisconnect;

  @override
  State<_RemoteDialog> createState() => _RemoteDialogState();
}

class _RemoteDialogState extends State<_RemoteDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current ?? '',
  );
  late RemoteTransport _transport = widget.currentBle != null
      ? RemoteTransport.ble
      : RemoteTransport.wifi;
  bool _busy = false;
  bool _scanning = false;
  List<BlePeer> _peers = const [];

  /// Results of the last network sweep, and whether one is running.
  bool _lanScanning = false;
  List<LanPeer> _lanPeers = const [];
  String? _connecting;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Sweeps the subnet for phones sharing on [LanSharingServer.sharePort].
  ///
  /// Only possible because the port is fixed — an ephemeral one would have to
  /// be typed in by hand every time, which is what this replaces.
  Future<void> _scanLan() async {
    // The results land under the address field, which a raised keyboard covers
    // on a short screen — so put it away before showing them.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _lanScanning = true;
      _error = null;
      _lanPeers = const [];
    });
    try {
      final peers = await LanDiscovery.scan();
      if (!mounted) return;
      setState(() {
        _lanScanning = false;
        _lanPeers = peers;
        if (peers.isEmpty) {
          _error =
              'No phone answered on port '
              '${LanSharingServer.sharePort}. Check that the other phone is '
              'sharing, and that both are on the same Wi-Fi.';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _lanScanning = false;
        _error = 'Could not scan the network ($error).';
      });
    }
  }

  Future<void> _connectWifi() async {
    final Uri uri;
    try {
      uri = normalizeRemote(_controller.text);
    } on RemoteException catch (error) {
      setState(() => _error = error.message);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.onConnect(uri);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _peers = const [];
    });
    try {
      final peers = await BleClient.scan();
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _peers = peers;
        if (peers.isEmpty) {
          _error =
              'No sharing phone answered. Start its Bluetooth share, then '
              'scan again.';
        }
      });
    } on RemoteException catch (error) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = error.message;
      });
    }
  }

  Future<void> _connectBle(BlePeer peer) async {
    setState(() {
      _connecting = peer.address;
      _error = null;
    });
    final error = await widget.onConnectBle(peer);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _connecting = null;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    final currentBle = widget.currentBle;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Row(
        children: [
          Icon(Icons.devices_other_rounded, color: AppColors.accent, size: 20),
          SizedBox(width: 8),
          Text('Watch another phone', style: TextStyle(fontSize: 16)),
        ],
      ),
      // Scrollable: the scan row made this taller than a keyboard-up dialog,
      // and a short screen would otherwise clip the results list.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TransportPicker(
              value: _transport,
              onChanged: _busy || _scanning
                  ? null
                  : (value) => setState(() {
                      _transport = value;
                      _error = null;
                    }),
            ),
            const SizedBox(height: 12),
            if (_transport == RemoteTransport.wifi)
              ..._wifiSection()
            else
              ..._bleSection(),
            if (_busy) ...[
              const SizedBox(height: 12),
              const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Asking that phone…',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: AppColors.danger,
                ),
              ),
            ],
            const SizedBox(height: 4),
          ],
        ),
      ),
      actions: [
        if (current != null || currentBle != null)
          TextButton(
            onPressed: () {
              widget.onDisconnect();
              Navigator.of(context).pop();
            },
            child: const Text(
              'Disconnect',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        TextButton(
          onPressed: _busy || _scanning
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_transport == RemoteTransport.wifi)
          FilledButton(
            onPressed: _busy ? null : _connectWifi,
            child: const Text('Connect'),
          )
        else
          FilledButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.textMuted,
                    ),
                  )
                : const Icon(Icons.bluetooth_searching_rounded, size: 16),
            label: Text(_scanning ? 'Scanning…' : 'Scan'),
          ),
      ],
    );
  }

  List<Widget> _wifiSection() {
    return [
      const Text(
        'Open sharing on the other phone, then scan for it — or type the '
        'address it shows. Both phones need to be on the same Wi-Fi.',
        style: TextStyle(
          fontSize: 12.5,
          height: 1.4,
          color: AppColors.textMuted,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _controller,
        enabled: !_busy,
        autofocus: widget.current == null && widget.currentBle == null,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _connectWifi(),
        style: monospace.copyWith(fontSize: 14, color: AppColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: '10.1.1.47:41729',
          hintStyle: monospace.copyWith(
            fontSize: 14,
            color: const Color(0xFF64748B),
          ),
          filled: true,
          fillColor: AppColors.surfaceAlt,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          OutlinedButton.icon(
            onPressed: _busy || _lanScanning ? null : _scanLan,
            icon: _lanScanning
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.textMuted,
                    ),
                  )
                : const Icon(Icons.radar_rounded, size: 16),
            label: Text(_lanScanning ? 'Scanning…' : 'Scan network'),
          ),
          const SizedBox(width: 8),
          Text(
            'port ${LanSharingServer.sharePort}',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ],
      ),
      if (_lanPeers.isNotEmpty) ...[
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 150),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _lanPeers.length,
            itemBuilder: (context, index) {
              final peer = _lanPeers[index];
              return InkWell(
                onTap: _busy || _lanScanning
                    ? null
                    : () {
                        setState(() {
                          _controller.text = peer.label;
                          _error = null;
                        });
                        _connectWifi();
                      },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.smartphone_rounded,
                        size: 16,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        peer.label,
                        style: monospace.copyWith(
                          fontSize: 13,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ];
  }

  List<Widget> _bleSection() {
    return [
      const Text(
        'Start Bluetooth sharing on the other phone (keep its app open), turn '
        'Bluetooth on here, then scan. No Wi-Fi or mobile data is needed.',
        style: TextStyle(
          fontSize: 12.5,
          height: 1.4,
          color: AppColors.textMuted,
        ),
      ),
      const SizedBox(height: 8),
      if (_peers.isEmpty)
        const Text(
          'Scan to list nearby phones.',
          style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
        )
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _peers.length,
            itemBuilder: (context, index) {
              final peer = _peers[index];
              final connecting = _connecting == peer.address;
              return InkWell(
                onTap: _busy || _connecting != null
                    ? null
                    : () => _connectBle(peer),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.bluetooth_rounded,
                        size: 15,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peer.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              peer.address,
                              style: monospace.copyWith(
                                fontSize: 10.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (connecting)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.accent,
                          ),
                        )
                      else
                        Text(
                          '${peer.rssi} dBm',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
    ];
  }
}

/// Wi-Fi / Bluetooth switch shared by both dialogs.
class _TransportPicker extends StatelessWidget {
  const _TransportPicker({required this.value, required this.onChanged});

  final RemoteTransport value;
  final ValueChanged<RemoteTransport>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<RemoteTransport>(
      segments: const [
        ButtonSegment(
          value: RemoteTransport.wifi,
          icon: Icon(Icons.wifi_rounded, size: 14),
          label: Text('Wi-Fi'),
        ),
        ButtonSegment(
          value: RemoteTransport.ble,
          icon: Icon(Icons.bluetooth_rounded, size: 14),
          label: Text('Bluetooth'),
        ),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: onChanged == null
          ? null
          : (selection) => onChanged!(selection.first),
      style: SegmentedButton.styleFrom(
        backgroundColor: AppColors.surfaceAlt,
        foregroundColor: AppColors.textMuted,
        selectedBackgroundColor: AppColors.accent.withValues(alpha: 0.16),
        selectedForegroundColor: AppColors.accent,
        side: const BorderSide(color: AppColors.border),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Page indicator for the per-SIM pages.
class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'SIM ${index + 1} of $count',
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          8 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == index ? 20 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: i == index ? AppColors.accent : AppColors.track,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
