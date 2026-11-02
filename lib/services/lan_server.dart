import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/cell_snapshot.dart';
import 'dashboard_html.dart';

/// Opt-in HTTP endpoint that republishes this phone's reading on the local
/// network, so a second phone (or any app on it) can watch this one.
///
/// The socket is bound to the LAN only: nothing leaves the network, the payload
/// is whatever the modem last reported, and stopping the share closes it.
class LanSharingServer {
  /// The one port the app shares on, and the one discovery probes.
  ///
  /// Fixed rather than "first free": a peer you have not been told about can
  /// only be found if there is a known port to knock on. It sits high and well
  /// clear of the 8000/8080/8090 range that dev servers, printers and routers
  /// occupy, so a scan on this port finds this app and little else.
  static const int sharePort = 41729;

  /// Binds [LanSharingServer.sharePort] unless told otherwise.
  ///
  /// The override exists for tests: rebinding one fixed port over and over
  /// trips Windows' TIME_WAIT, so a suite that starts and stops the server
  /// repeatedly can ask for an ephemeral one instead.
  LanSharingServer({int port = sharePort}) : _preferredPort = port;

  final int _preferredPort;

  HttpServer? _server;
  CellSnapshot? _latest;

  /// When false the server is API-only: no HTML at any path, and `/` answers
  /// with the same JSON as `/snapshot`. Read per request, so it can be flipped
  /// while sharing without rebinding the port.
  bool serveDashboard = true;

  bool get isRunning => _server != null;

  int? get port => _server?.port;

  /// Latest reading; the UI pushes one on every modem update.
  void update(CellSnapshot snapshot) => _latest = snapshot;

  /// Binds the first free port and returns the address to type on the other
  /// phone, e.g. `http://10.1.1.47:8080`.
  Future<Uri> start({CellSnapshot? snapshot}) async {
    if (snapshot != null) _latest = snapshot;
    if (_server != null) return Uri.parse(await url());

    // A port released a moment ago can still be in TIME_WAIT — on Windows even
    // after a clean close — so stopping and restarting sharing gets a few short
    // attempts rather than failing on the first bind.
    SocketException? lastError;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          _preferredPort,
        );
        _server = server;
        server.listen(_handle);
        return Uri.parse(await url());
      } on SocketException catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    throw LanShareException(
      'Port $_preferredPort is already in use on this phone, so sharing could '
      'not start. Close whatever is holding it and try again ($lastError).',
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _latest = null;
    await server?.close(force: true);
  }

  /// Address to hand out: the Wi-Fi interface first, loopback if the phone is
  /// not on a network.
  Future<String> url() async {
    final boundPort = _server?.port;
    if (boundPort == null) {
      throw const LanShareException('Sharing is not running.');
    }
    final addresses = await localAddresses();
    final host = addresses.isEmpty ? '127.0.0.1' : addresses.first;
    return 'http://$host:$boundPort';
  }

  /// IPv4 addresses on a LAN interface (Wi-Fi, hotspot, Ethernet, USB
  /// tether) that another device can reach.
  ///
  /// The cellular interface is deliberately excluded: its address is behind
  /// the carrier's NAT, so advertising it would hand out a URL that never
  /// works. No LAN address means the phone is on mobile data only, and the UI
  /// asks the user to join Wi-Fi.
  static Future<List<String>> localAddresses() async {
    const prefixes = ['wlan', 'ap', 'swlan', 'eth', 'rndis', 'p2p'];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final addresses = <String>[];
      for (final interface in interfaces) {
        if (!prefixes.any(interface.name.startsWith)) continue;
        for (final address in interface.addresses) {
          final ip = address.address;
          if (ip.startsWith('169.254.')) continue;
          addresses.add(ip);
        }
      }
      return addresses;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Cache-Control', 'no-store');
    try {
      switch (request.uri.path) {
        case '/':
        case '/index.html':
          if (serveDashboard) {
            _writeHtml(response, DashboardHtml.page(_latest));
          } else {
            // API-only mode: the root is the payload, never a page.
            _writeSnapshot(response);
          }
        case '/view':
          // The live region the page swaps in place. Rendering it here rather
          // than in the browser's JavaScript is what keeps the page and the app
          // showing the same fields: both read this phone's model.
          if (serveDashboard) {
            _writeHtml(response, DashboardHtml.body(_latest));
          } else {
            _notFound(response);
          }
        case '/snapshot':
        case '/api/snapshot':
          _writeSnapshot(response);
        case '/health':
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({
            'ok': true,
            'port': _server?.port,
            'dashboard': serveDashboard,
          }));
        default:
          _notFound(response);
      }
    } catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      response.write('Server error: $error');
    } finally {
      await response.close();
    }
  }

  void _writeHtml(HttpResponse response, String html) {
    response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
    response.write(html);
  }

  void _notFound(HttpResponse response) {
    response.statusCode = HttpStatus.notFound;
    if (serveDashboard) {
      response.write('Not found');
      return;
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({
      'error': 'Not found',
      'paths': ['/', '/view', '/snapshot', '/api/snapshot', '/health'],
    }));
  }

  void _writeSnapshot(HttpResponse response) {
    response.headers.contentType = ContentType.json;
    final snapshot = _latest;
    if (snapshot == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.write(jsonEncode({'error': 'No reading yet.'}));
      return;
    }
    response.write(jsonEncode(snapshot.toJsonMap()));
  }
}

class LanShareException implements Exception {
  const LanShareException(this.message);

  final String message;

  @override
  String toString() => message;
}
