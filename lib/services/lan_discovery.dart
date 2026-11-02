import 'dart:convert';
import 'dart:io';

import 'lan_server.dart';

/// A phone found on the local network that is publishing a reading.
class LanPeer {
  const LanPeer({required this.host, required this.port});

  final String host;
  final int port;

  /// Address to type by hand, the same shape the dialog accepts.
  String get label => '$host:$port';

  Uri get snapshotUri =>
      Uri(scheme: 'http', host: host, port: port, path: '/snapshot');

  @override
  bool operator ==(Object other) =>
      other is LanPeer && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Finds sharing phones by knocking on [LanSharingServer.sharePort] across the
/// subnet.
///
/// A scan is possible at all only because that port is fixed: with an ephemeral
/// port the viewer would have to be told an address every time. Each host is
/// asked for `/health` rather than merely probed for an open socket, so a
/// printer or a dev server that happens to sit on 41729 is not mistaken for a
/// phone — the answer has to be this app's `{"ok": true}` JSON.
class LanDiscovery {
  LanDiscovery._();

  /// How long a host gets to answer. A phone on the same Wi-Fi replies in
  /// single-digit milliseconds; this only has to outlast a sleeping device.
  static const Duration timeout = Duration(milliseconds: 400);

  /// Hosts probed at once. Opening 254 sockets in one burst is more than a
  /// phone's stack enjoys, and the batch keeps the sweep quick anyway.
  static const int batch = 48;

  /// Every other host on this phone's subnets that answers with a reading.
  ///
  /// Returns an empty list when the phone has no LAN address at all, which is
  /// the mobile-data-only case — there is nothing to sweep in that state.
  static Future<List<LanPeer>> scan({
    int port = LanSharingServer.sharePort,
  }) async {
    final addresses = await LanSharingServer.localAddresses();
    if (addresses.isEmpty) return const [];
    final own = addresses.toSet();
    final client = HttpClient()..connectionTimeout = timeout;
    final peers = <LanPeer>[];
    try {
      for (final address in addresses) {
        final dot = address.lastIndexOf('.');
        if (dot <= 0) continue;
        final prefix = address.substring(0, dot);
        for (var start = 1; start <= 254; start += batch) {
          final stop = start + batch - 1;
          final found = await Future.wait([
            for (var host = start; host <= (stop > 254 ? 254 : stop); host++)
              _probe(client, '$prefix.$host', port),
          ]);
          for (final peer in found) {
            if (peer != null && !own.contains(peer.host)) peers.add(peer);
          }
        }
      }
    } finally {
      client.close(force: true);
    }
    peers.sort((a, b) => a.host.compareTo(b.host));
    return peers;
  }

  /// The host's `/health`, or null when nothing answers like this app.
  static Future<LanPeer?> _probe(
    HttpClient client,
    String host,
    int port,
  ) async {
    try {
      final request = await client
          .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/health'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['ok'] != true) return null;
      return LanPeer(host: host, port: port);
    } on Object {
      return null;
    }
  }
}
