/// Persistent pairing credentials + silent auto-reconnect suite.
///
///  * [PairingCredentials] json roundtrip, tolerance of the legacy `ipv4`
///    key, rejection of malformed bodies, [PairingCredentials.toPairingInfo]
///  * [PairingCredentialsStore] save/load/clear against an injected path
///    (never path_provider), missing/corrupt/unwritable file handling
///  * [PairingSessionController] auto-connect success / timeout / auth
///    failure (4001 ⇒ credentials forgotten) and save-on-online
///  * [PairingScreen] shows the fallback notice passed by the shell
///
/// Scratch state lives under `test/.pairing_credentials_tmp/` inside the
/// package (never `/tmp`) and is removed in `tearDown`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/features/pairing/pairing_screen.dart';
import 'package:mobile_app/features/pairing/pairing_session_controller.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/network/pairing_credentials_store.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake client (no sockets — state transitions are scripted by each test)
// ---------------------------------------------------------------------------

class _FakeClient extends VectorSyncClient {
  final StreamController<SyncEvent> _controller =
      StreamController<SyncEvent>.broadcast();
  final List<PairingInfo> connects = <PairingInfo>[];

  SyncState _state = SyncState.idle;
  PairingInfo? _info;

  /// State the scripted handshake settles on; `null` ⇒ never settles (the
  /// controller's attempt timeout must fire).
  SyncState? handshake;

  bool throwOnConnect = false;

  @override
  Stream<SyncEvent> get events => _controller.stream;

  @override
  SyncState get state => _state;

  @override
  PairingInfo? get pairing => _info;

  @override
  bool get isConnected => _state == SyncState.online;

  @override
  Future<void> connect(PairingInfo info) async {
    connects.add(info);
    _info = info;
    if (throwOnConnect) {
      throw StateError('dial refused');
    }
    final SyncState? next = handshake;
    if (next != null) {
      _state = next;
      _controller.add(SyncEvent(kind: SyncEventKind.stateChanged, state: next));
    }
  }

  /// Simulates a post-connection transition (save-on-online path).
  void emitState(SyncState state) {
    _state = state;
    _controller.add(SyncEvent(kind: SyncEventKind.stateChanged, state: state));
  }

  void setPairing(PairingInfo info) => _info = info;

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const MethodChannel pathChannel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  final Directory root = Directory('test/.pairing_credentials_tmp');
  late Directory tmp;
  late Directory platformRoot;
  late String filePath;

  setUpAll(() async {
    platformRoot = Directory(
      '${root.path}/platform/${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    // The shell group below opens the real `LocalDb` and resolves document
    // directories through path_provider; isolate both inside the package
    // (never `/tmp`) so parallel test files cannot race.
    await databaseFactory.setDatabasesPath('${platformRoot.path}/databases');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (MethodCall call) async {
          switch (call.method) {
            case 'getApplicationDocumentsDirectory':
            case 'getApplicationSupportDirectory':
            case 'getTemporaryDirectory':
              return platformRoot.path;
          }
          return null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    try {
      if (platformRoot.existsSync()) platformRoot.deleteSync(recursive: true);
    } catch (_) {
      // best effort
    }
    // Remove the scratch root too: leaving it behind litters the package and
    // makes every later `flutter test` run show up as untracked churn. The
    // sqflite handles may still hold the databases dir for a few ms, so retry.
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        if (!root.existsSync()) return;
        root.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  setUp(() {
    tmp = Directory('${root.path}/${DateTime.now().microsecondsSinceEpoch}');
    tmp.createSync(recursive: true);
    filePath = '${tmp.path}/${PairingCredentialsStore.fileName}';
  });

  tearDown(() async {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // best effort — never fail a test on cleanup
    }
  });

  const PairingCredentials sample = PairingCredentials(
    host: '192.168.1.42',
    port: 50606,
    token: 'tok_abc-123',
    deviceName: 'Slate Tablet',
  );

  group('PairingCredentials', () {
    test('toJson/fromJson roundtrip preserves every field', () {
      final Map<String, dynamic> json = sample.toJson();
      expect(json['host'], '192.168.1.42');
      expect(json['port'], 50606);
      expect(json['token'], 'tok_abc-123');
      expect(json['device_name'], 'Slate Tablet');

      final PairingCredentials restored = PairingCredentials.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(restored, sample);
      expect(restored.hashCode, sample.hashCode);
    });

    test('fromJson accepts the legacy "ipv4" key', () {
      final PairingCredentials restored = PairingCredentials.fromJson(
        <String, dynamic>{'ipv4': '10.0.0.7', 'port': 50606, 'token': 't'},
      );
      expect(restored.host, '10.0.0.7');
      expect(restored.deviceName, isNull);
    });

    test('fromJson rejects missing/invalid fields', () {
      expect(
        () => PairingCredentials.fromJson(<String, dynamic>{
          'port': 50606,
          'token': 't',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PairingCredentials.fromJson(<String, dynamic>{
          'host': '1.2.3.4',
          'port': 0,
          'token': 't',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PairingCredentials.fromJson(<String, dynamic>{
          'host': '1.2.3.4',
          'port': 50606,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromPairingInfo maps the Doc 25 pairing onto credentials', () {
      final PairingCredentials credentials = PairingCredentials.fromPairingInfo(
        const PairingInfo(ipv4: '10.1.1.9', port: 50606, token: 'secret'),
        deviceName: 'Tab',
      );
      expect(credentials.host, '10.1.1.9');
      expect(credentials.port, 50606);
      expect(credentials.token, 'secret');
      expect(credentials.deviceName, 'Tab');

      final PairingInfo info = credentials.toPairingInfo();
      expect(info.ipv4, '10.1.1.9');
      expect(info.port, 50606);
      expect(info.token, 'secret');
    });

    test('toString masks the token', () {
      expect(sample.toString(), isNot(contains('tok_abc-123')));
    });
  });

  group('PairingCredentialsStore', () {
    test('load returns null when nothing was ever saved', () async {
      final PairingCredentialsStore store = PairingCredentialsStore(
        filePath: filePath,
      );
      expect(await store.load(), isNull);
    });

    test('save then load returns the same credentials', () async {
      final PairingCredentialsStore store = PairingCredentialsStore(
        filePath: filePath,
      );
      await store.save(sample);
      expect(File(filePath).existsSync(), isTrue);
      expect(await store.load(), sample);

      // Overwrite (re-pair with a new PC).
      const PairingCredentials other = PairingCredentials(
        host: '10.9.9.9',
        port: 50606,
        token: 'tok_new',
      );
      await store.save(other);
      expect(await store.load(), other);
    });

    test('clear forgets the saved pairing and is idempotent', () async {
      final PairingCredentialsStore store = PairingCredentialsStore(
        filePath: filePath,
      );
      await store.save(sample);
      await store.clear();
      expect(await store.load(), isNull);
      await store.clear(); // no-op, never throws
      expect(await store.load(), isNull);
    });

    test('corrupt json is treated as "no saved pairing"', () async {
      final PairingCredentialsStore store = PairingCredentialsStore(
        filePath: filePath,
      );
      await File(filePath).writeAsString('{not json', flush: true);
      expect(await store.load(), isNull);

      await File(filePath).writeAsString('{"host": "1.2.3.4"}', flush: true);
      expect(await store.load(), isNull);
    });

    test('unwritable path never throws', () async {
      final Directory blocker = Directory('${tmp.path}/blocked')
        ..createSync(recursive: true);
      final PairingCredentialsStore store = PairingCredentialsStore(
        filePath: '${blocker.path}/${PairingCredentialsStore.fileName}',
      );
      // A directory where the file must go ⇒ write fails but is swallowed.
      Directory('${blocker.path}/${PairingCredentialsStore.fileName}')
          .createSync();
      await expectLater(store.save(sample), completes);
      expect(await store.load(), isNull);
    });
  });

  group('PairingSessionController', () {
    test('autoConnect returns false when nothing is saved', () async {
      final _FakeClient client = _FakeClient();
      addTearDown(client.dispose);
      final PairingSessionController controller = PairingSessionController(
        client: client,
        store: PairingCredentialsStore(filePath: filePath),
      );
      addTearDown(controller.dispose);

      expect(await controller.autoConnect(), isFalse);
      expect(controller.hadSavedCredentials, isFalse);
      expect(client.connects, isEmpty);
      expect(controller.lastError, isNull);
    });

    test(
      'autoConnect dials the saved credentials and reports success',
      () async {
        final _FakeClient client = _FakeClient()..handshake = SyncState.online;
        addTearDown(client.dispose);
        final PairingSessionController controller = PairingSessionController(
          client: client,
          store: PairingCredentialsStore(filePath: filePath),
        );
        addTearDown(controller.dispose);
        await controller.saveFromPairing(
          const PairingInfo(ipv4: '192.168.1.42', port: 50606, token: 'tok'),
        );

        expect(await controller.autoConnect(), isTrue);
        expect(client.connects.single.ipv4, '192.168.1.42');
        expect(client.connects.single.port, 50606);
        expect(client.connects.single.token, 'tok');
        expect(controller.lastError, isNull);
      },
    );

    test('autoConnect times out and keeps the credentials', () async {
      final _FakeClient client = _FakeClient(); // handshake never settles
      addTearDown(client.dispose);
      final PairingSessionController controller = PairingSessionController(
        client: client,
        store: PairingCredentialsStore(filePath: filePath),
        attemptTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(controller.dispose);
      await controller.saveFromPairing(
        const PairingInfo(ipv4: '10.0.0.2', port: 50606, token: 'tok'),
      );

      expect(await controller.autoConnect(), isFalse);
      expect(controller.lastError, kPairingAutoConnectFailedNotice);
      // Transient failure ⇒ the pairing survives for the next launch.
      expect(
        await PairingCredentialsStore(filePath: filePath).load(),
        isNotNull,
      );
    });

    test('autoConnect reports a throwing connect without crashing', () async {
      final _FakeClient client = _FakeClient()..throwOnConnect = true;
      addTearDown(client.dispose);
      final PairingCredentialsStore store = PairingCredentialsStore(
        filePath: filePath,
      );
      await store.save(sample);
      final PairingSessionController controller = PairingSessionController(
        client: client,
        store: store,
      );
      addTearDown(controller.dispose);

      expect(await controller.autoConnect(), isFalse);
      expect(controller.lastError, kPairingAutoConnectFailedNotice);
    });

    test('auth failure (4001) forgets the dead pairing', () async {
      final _FakeClient client = _FakeClient()
        ..handshake = SyncState.authFailed;
      addTearDown(client.dispose);
      final PairingSessionController controller = PairingSessionController(
        client: client,
        store: PairingCredentialsStore(filePath: filePath),
      );
      addTearDown(controller.dispose);
      await controller.saveFromPairing(
        const PairingInfo(ipv4: '10.0.0.3', port: 50606, token: 'stale'),
      );

      expect(await controller.autoConnect(), isFalse);
      expect(controller.lastError, kPairingAuthFailedNotice);
      expect(File(filePath).existsSync(), isFalse);
    });

    test('save-on-online persists the pairing that reached online', () async {
      final _FakeClient client = _FakeClient();
      addTearDown(client.dispose);
      final PairingSessionController controller = PairingSessionController(
        client: client,
        store: PairingCredentialsStore(filePath: filePath),
        deviceName: 'Studio Tablet',
      );
      addTearDown(controller.dispose);

      // A QR/manual/discovery pairing lands online through the state machine.
      client.setPairing(
        const PairingInfo(ipv4: '172.16.0.5', port: 50606, token: 'qr-token'),
      );
      client.emitState(SyncState.online);

      PairingCredentials? saved;
      for (var i = 0; i < 50 && saved == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        saved = await PairingCredentialsStore(filePath: filePath).load();
      }
      expect(saved, isNotNull);
      expect(saved!.host, '172.16.0.5');
      expect(saved.port, 50606);
      expect(saved.token, 'qr-token');
      expect(saved.deviceName, 'Studio Tablet');
    });

    test('transitions that are not online never write credentials', () async {
      final _FakeClient client = _FakeClient();
      addTearDown(client.dispose);
      final PairingSessionController controller = PairingSessionController(
        client: client,
        store: PairingCredentialsStore(filePath: filePath),
      );
      addTearDown(controller.dispose);

      client.setPairing(
        const PairingInfo(ipv4: '172.16.0.6', port: 50606, token: 't'),
      );
      for (final SyncState state in <SyncState>[
        SyncState.connecting,
        SyncState.backoff,
      ]) {
        client.emitState(state);
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(File(filePath).existsSync(), isFalse);
    });

    test('forget clears a saved pairing', () async {
      final _FakeClient client = _FakeClient();
      addTearDown(client.dispose);
      final PairingSessionController controller = PairingSessionController(
        client: client,
        store: PairingCredentialsStore(filePath: filePath),
      );
      addTearDown(controller.dispose);

      await controller.saveFromPairing(
        const PairingInfo(ipv4: '10.0.0.4', port: 50606, token: 't'),
      );
      expect(File(filePath).existsSync(), isTrue);
      await controller.forget();
      expect(File(filePath).existsSync(), isFalse);
      expect(controller.hadSavedCredentials, isFalse);
    });
  });

  group('PairingScreen fallback notice', () {
    testWidgets('renders the auto-connect notice above the pairing modes', (
      WidgetTester tester,
    ) async {
      final _FakeClient client = _FakeClient();
      addTearDown(client.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PairingScreen(
            client: client,
            notice: kPairingAutoConnectFailedNotice,
          ),
        ),
      );

      expect(
        find.byKey(const Key('pairing-auto-connect-notice')),
        findsOneWidget,
      );
      expect(find.text(kPairingAutoConnectFailedNotice), findsOneWidget);
      expect(find.byKey(const Key('pairing-discover')), findsOneWidget);
    });

    testWidgets('omits the notice when the shell has nothing to report', (
      WidgetTester tester,
    ) async {
      final _FakeClient client = _FakeClient();
      addTearDown(client.dispose);

      await tester.pumpWidget(MaterialApp(home: PairingScreen(client: client)));

      expect(
        find.byKey(const Key('pairing-auto-connect-notice')),
        findsNothing,
      );
    });
  });

  group('Shell auto-connect', () {
    /// Real-event-loop windows interleaved with frame pumps: sqflite/file
    /// futures parked from the fake zone only progress inside `runAsync`.
    Future<void> flushReal(WidgetTester tester, {int rounds = 6}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets(
      'saved pairing reconnects silently instead of asking to scan',
      (WidgetTester tester) async {
        final _FakeClient client = _FakeClient()..handshake = SyncState.online;
        addTearDown(client.dispose);
        final String shellPath = '${tmp.path}/shell_ok.json';
        final PairingCredentialsStore store = PairingCredentialsStore(
          filePath: shellPath,
        );
        await tester.runAsync(() => store.save(sample));

        await tester.pumpWidget(
          SlateSyncApp(client: client, credentialsStore: store),
        );
        await flushReal(tester);

        expect(client.connects, hasLength(1));
        expect(client.connects.single.ipv4, '192.168.1.42');
        expect(client.connects.single.port, 50606);
        expect(client.connects.single.token, 'tok_abc-123');
        // No pairing screen: the shell went straight to the gallery.
        expect(find.byKey(const Key('pairing_screen')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await flushReal(tester, rounds: 3);
      },
    );

    testWidgets(
      'stale pairing falls back to the pairing screen with a notice',
      (WidgetTester tester) async {
        final _FakeClient client = _FakeClient()
          ..handshake = SyncState.authFailed;
        addTearDown(client.dispose);
        final String shellPath = '${tmp.path}/shell_stale.json';
        final PairingCredentialsStore store = PairingCredentialsStore(
          filePath: shellPath,
        );
        await tester.runAsync(() => store.save(sample));

        await tester.pumpWidget(
          SlateSyncApp(client: client, credentialsStore: store),
        );
        await flushReal(tester);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('pairing_screen')), findsOneWidget);
        expect(
          find.text(kPairingAuthFailedNotice),
          findsOneWidget,
          reason: 'the user must be told why the silent reconnect failed',
        );
        // The dead pairing is forgotten so the next launch goes straight here.
        expect(File(shellPath).existsSync(), isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        await flushReal(tester, rounds: 3);
      },
    );

    testWidgets(
      'no saved pairing keeps the gallery and never dials',
      (WidgetTester tester) async {
        final _FakeClient client = _FakeClient()..handshake = SyncState.online;
        addTearDown(client.dispose);
        final String shellPath = '${tmp.path}/shell_empty.json';

        await tester.pumpWidget(
          SlateSyncApp(
            client: client,
            credentialsStore: PairingCredentialsStore(filePath: shellPath),
          ),
        );
        await flushReal(tester);

        expect(client.connects, isEmpty);
        expect(find.byKey(const Key('pairing_screen')), findsNothing);
        expect(find.byKey(const Key('home-connect')), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await flushReal(tester, rounds: 3);
      },
    );
  });
}
