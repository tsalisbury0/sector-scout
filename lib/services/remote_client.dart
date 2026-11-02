import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/cell_snapshot.dart';

/// Reads another phone's Sector Scout over the LAN.
///
/// The peer runs the share from the app bar; this client polls its `/snapshot`
/// JSON (the same payload the local native bridge produces) and hands it to the
/// normal model parser, so the remote view uses the same cards as a local read.
class RemoteClient {
  RemoteClient(this.baseUri) : _http = HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 3);
  }

  /// Peer root, e.g. `http://10.1.1.47:8080`.
  final Uri baseUri;
  final HttpClient _http;

  /// `http://host:port/snapshot`, whatever path the user typed.
  Uri get snapshotUri => Uri(
        scheme: baseUri.scheme,
        host: baseUri.host,
        port: baseUri.port,
        path: '/snapshot',
      );

  Future<CellSnapshot> fetch() async {
    final HttpClientResponse response;
    try {
      final request = await _http
          .getUrl(snapshotUri)
          .timeout(const Duration(seconds: 4));
      response = await request.close().timeout(const Duration(seconds: 4));
    } on Object {
      throw RemoteException(
        'Could not reach ${baseUri.host} — is that phone sharing, on the same '
        'Wi-Fi, and still running the app?',
      );
    }

    final body =
        await response.transform(utf8.decoder).join().timeout(
              const Duration(seconds: 4),
            );

    if (response.statusCode == HttpStatus.serviceUnavailable) {
      throw const RemoteException('That phone has not produced a reading yet.');
    }
    if (response.statusCode != HttpStatus.ok) {
      throw RemoteException(
        'That phone answered HTTP ${response.statusCode}. Check the address '
        'and that sharing is on.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const RemoteException(
        'That address did not return cell-tower JSON. Is it the right port?',
      );
    }
    if (decoded is! Map<Object?, Object?>) {
      throw const RemoteException('Unexpected response shape from that phone.');
    }

    try {
      return CellSnapshot.fromMap(decoded);
    } on Object {
      throw const RemoteException(
        'That phone sent data this build cannot read. Update both apps.',
      );
    }
  }

  void dispose() => _http.close(force: true);
}

/// Turns what the user typed into a peer root.
///
/// Accepts `10.1.1.47`, `10.1.1.47:8080`, `http://10.1.1.47:8080/` and the
/// `/snapshot` URL itself, adding the scheme and the default port as needed.
Uri normalizeRemote(String input) {
  var text = input.trim();
  if (text.isEmpty) {
    throw const RemoteException('Enter the other phone\'s address first.');
  }
  if (!text.contains('://')) text = 'http://$text';

  final parsed = Uri.tryParse(text);
  if (parsed == null || parsed.host.isEmpty) {
    throw const RemoteException(
      'That does not look like an address. Try 10.1.1.47 or 10.1.1.47:8080.',
    );
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    throw const RemoteException('Only http addresses are supported.');
  }
  final port = parsed.hasPort ? parsed.port : 8080;
  return Uri(scheme: parsed.scheme, host: parsed.host, port: port);
}

class RemoteException implements Exception {
  const RemoteException(this.message);

  final String message;

  @override
  String toString() => message;
}
