import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  bool get running => _server != null;
  String? get failure => _failure;
  int? get port => _server?.port;

  /// The reading served right now; changing it takes effect on the next request.
  Scenario scenario;

  Uri? get uri => _server == null
      ? null
      : Uri.parse('http://127.0.0.1:${_server!.port}/snapshot');

  /// Returns null when it bound, or the reason it could not.
  Future<String?> start() async {
    if (_server != null) return null;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, preferredPort);
      server.listen(_handle);
      _server = server;
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
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.contentType = ContentType.json;
    try {
      final path = request.uri.path;
      if (path == '/health') {
        response.write(jsonEncode({'ok': true}));
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
