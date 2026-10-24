/// Tablet-side memory of the last SUCCESSFUL pairing.
///
/// The PC keeps a static pairing token (`%APPDATA%\SlateSync\pairing.json`),
/// so one scan is permanent: the tablet persists `{host, port, token,
/// device_name}` here and dials it again on the next launch instead of
/// asking for a new QR scan.
///
/// Storage reuses the exact mechanism [DeviceIdentity] (see
/// `features/sync/hub_sync.dart`) uses for `slatesync_device.json` —
/// path_provider's application-support directory, no extra dependency. The
/// full json path is injectable so tests never touch path_provider.
///
/// Pure Dart + file I/O: no network, no widgets.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mobile_app/network/vector_sync_client.dart' show PairingInfo;

/// Last successful pairing, as persisted on the tablet.
@immutable
class PairingCredentials {
  const PairingCredentials({
    required this.host,
    required this.port,
    required this.token,
    this.deviceName,
  });

  /// Rebuilds credentials from [PairingInfo] (the Doc 25 pairing result).
  factory PairingCredentials.fromPairingInfo(
    PairingInfo info, {
    String? deviceName,
  }) => PairingCredentials(
    host: info.ipv4,
    port: info.port,
    token: info.token,
    deviceName: deviceName,
  );

  /// Parses the persisted json body; throws [FormatException] when required
  /// fields are missing or malformed (the store treats that as "no saved
  /// pairing", a stale/corrupt file never blocks startup).
  factory PairingCredentials.fromJson(Map<String, dynamic> json) {
    final Object? host = json['host'] ?? json['ipv4'];
    final Object? port = json['port'];
    final Object? token = json['token'];
    if (host is! String || host.isEmpty) {
      throw const FormatException('pairing credentials: missing host');
    }
    if (port is! int || port <= 0 || port > 65535) {
      throw const FormatException('pairing credentials: bad port');
    }
    if (token is! String || token.isEmpty) {
      throw const FormatException('pairing credentials: missing token');
    }
    final Object? name = json['device_name'];
    return PairingCredentials(
      host: host,
      port: port,
      token: token,
      deviceName: name is String && name.isNotEmpty ? name : null,
    );
  }

  /// PC agent IPv4 (or resolvable host name).
  final String host;

  /// WebSocket port ([kSyncWsPort] by default).
  final int port;

  /// Static pairing token from the PC's `pairing.json`.
  final String token;

  /// Optional tablet display name; null when never supplied.
  final String? deviceName;

  /// Doc 25 connection input for `VectorSyncClient.connect`.
  PairingInfo toPairingInfo() =>
      PairingInfo(ipv4: host, port: port, token: token);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'host': host,
    'port': port,
    'token': token,
    'device_name': deviceName,
  };

  @override
  bool operator ==(Object other) =>
      other is PairingCredentials &&
      other.host == host &&
      other.port == port &&
      other.token == token &&
      other.deviceName == deviceName;

  @override
  int get hashCode => Object.hash(host, port, token, deviceName);

  /// Token is masked so session secrets never reach logs.
  @override
  String toString() =>
      'PairingCredentials(host: $host, port: $port, token: ***, '
      'deviceName: $deviceName)';
}

/// Persists [PairingCredentials] as `slatesync_pairing.json`.
///
/// Mirrors `DeviceIdentity`: application-support directory by default, full
/// file path injectable for tests. Reads and writes never throw — a
/// missing/unreadable/unwritable file simply means "no saved pairing".
class PairingCredentialsStore {
  PairingCredentialsStore({this.filePath});

  /// File name under the application-support directory.
  static const String fileName = 'slatesync_pairing.json';

  /// Full json path override (tests); `null` ⇒ path_provider app-support.
  final String? filePath;

  /// Returns the saved credentials, or `null` when there are none (first
  /// launch, cleared, corrupt or unreachable storage).
  Future<PairingCredentials?> load() async {
    try {
      final File file = File(await _resolvePath());
      if (!file.existsSync()) {
        return null;
      }
      final Object? raw = jsonDecode(await file.readAsString());
      if (raw is! Map) {
        return null;
      }
      return PairingCredentials.fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      debugPrint('slatesync: no usable pairing credentials ($e)');
      return null;
    }
  }

  /// Writes [credentials], replacing any previous pairing.
  Future<void> save(PairingCredentials credentials) async {
    try {
      final File file = File(await _resolvePath());
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(credentials.toJson()), flush: true);
    } catch (e) {
      debugPrint('slatesync: could not persist pairing credentials ($e)');
    }
  }

  /// Forgets the saved pairing; a no-op when nothing is stored.
  Future<void> clear() async {
    try {
      final File file = File(await _resolvePath());
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('slatesync: could not clear pairing credentials ($e)');
    }
  }

  Future<String> _resolvePath() async {
    final String? override = filePath;
    if (override != null) {
      return override;
    }
    final Directory dir = await getApplicationSupportDirectory();
    return '${dir.path}/$fileName';
  }
}
