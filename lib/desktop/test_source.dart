import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../services/lan_discovery.dart';
import 'scenario.dart';

/// Serves a [Scenario] as the phone's own `/snapshot` JSON, on the same fixed
/// port the phones use, so a handset can watch this PC instead of a modem.
///
/// A real `HttpServer`, not a shim: the phone app's own client fetches it.
class DesktopTestSource {
  DesktopTestSource({Scenario? scenario, this.preferredPort = 41729})
      : scenario = scenario ?? Scenario.presets.first;

  static const int defaultPort = 41729;

  final int preferredPort;
  final Random _drift = Random();

  HttpServer? _server;
  String? _failure;
  String? _lanHost;

  bool get running => _server != null;
  String? get failure => _failure;
  int? get port => _server?.port;

  /// The reading served right now; changing it takes effect on the next request.
  Scenario scenario;

  Uri? get uri => _server == null
      ? null
      : Uri.parse('http://127.0.0.1:${_server!.port}/snapshot');

  /// The same address on this machine's LAN, which is the one to type on a
  /// phone; null when the PC has no LAN address.
  Uri? get lanUri => _server == null || _lanHost == null
      ? null
      : Uri.parse('http://$_lanHost:${_server!.port}/snapshot');

  /// Returns null when it bound, or the reason it could not.
  Future<String?> start() async {
    if (_server != null) return null;
    try {
      // Bound to every interface, not loopback: the phone that watches this
      // has to be able to reach it across the network, which is the whole
      // point of the test source.
      final server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
      server.listen(_handle);
      _server = server;
      final addresses = await LanDiscovery.localAddresses();
      _lanHost = addresses.isEmpty ? null : addresses.first;
      _failure = null;
      return null;
    } on Object catch (error) {
      _failure = '$error';
      return _failure;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _lanHost = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.contentType = ContentType.json;
    try {
      final path = request.uri.path;
      if (path == '/health') {
        response.write(jsonEncode({
          'ok': true,
          'port': _server?.port,
          'dashboard': false,
        }));
      } else if (path == '/snapshot' || path == '/api/snapshot' || path == '/') {
        response.write(jsonEncode(scenario.payload(drift: Scenario.drift(_drift))));
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'no such path: $path'}));
      }
    } on Object catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'error': '$error'}));
    }
    await response.close();
  }
}
