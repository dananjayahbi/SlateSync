/// Issue 03: pairing UX — "No option anywhere to scan the QR code to pair
/// with the PC."
///
/// Widget tests with injected fakes only (no camera, no sockets, no mDNS):
///  * Home app bar "Connect" entry → [PairingScreen]
///  * Studio top bar connection button → [PairingScreen]
///  * Scan QR → `parsePairingUrl` (frozen Doc 25 parser) → `client.connect`
///  * Auto-discover timeout → manual-entry hint
///  * Auto-discover success → pop back (state machine proceeds)
///  * Camera permission denied → manual fallback hint
///  * No-camera device (`unsupported`) → manual fallback hint
///  * Manual IP form → `client.connect` → both routes unwind
///
/// Scratch state lives under `test/.pairing_flow_tmp/` inside the package
/// (never `/tmp`) and is removed in `tearDown`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/features/pairing/pairing_screen.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fakes (Doc 25 surface — widget tests never touch the network)
// ---------------------------------------------------------------------------

class _FakeSyncClient extends VectorSyncClient {
  Object? discoverError;
  int discoverCalls = 0;
  final List<PairingInfo> connects = <PairingInfo>[];

  @override
  Future<void> discover() async {
    discoverCalls += 1;
    final Object? error = discoverError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> connect(PairingInfo info) async {
    connects.add(info);
  }

  @override
  bool get isConnected => false;

  @override
  Stream<SyncEvent> get events => const Stream<SyncEvent>.empty();

  @override
  Future<void> dispose() async {}
}

/// Fake camera: reports [code] post-frame exactly like a real
/// `MobileScanner.errorBuilder` failure would surface.
class _FakeCameraScanner extends StatefulWidget {
  const _FakeCameraScanner({
    required this.onPair,
    required this.onCameraError,
    this.code,
    this.emitDetection,
  });

  final void Function(PairingInfo info) onPair;
  final void Function(MobileScannerErrorCode code) onCameraError;

  /// `null` ⇒ camera starts fine (only [emitDetection] matters).
  final MobileScannerErrorCode? code;

  /// When set, this "scan" button reports a valid pairing payload parsed by
  /// the frozen Doc 25 `parsePairingUrl`.
  final String? emitDetection;

  @override
  State<_FakeCameraScanner> createState() => _FakeCameraScannerState();
}

class _FakeCameraScannerState extends State<_FakeCameraScanner> {
  @override
  void initState() {
    super.initState();
    final MobileScannerErrorCode? code = widget.code;
    if (code == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onCameraError(code);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String? raw = widget.emitDetection;
    if (raw == null) {
      return const SizedBox.expand(
        child: ColoredBox(
          key: Key('fake-camera-live'),
          color: Colors.black,
        ),
      );
    }
    return Center(
      child: ElevatedButton(
        key: const Key('fake-scan-emit'),
        onPressed: () => widget.onPair(parsePairingUrl(raw)),
        child: const Text('Emit scan'),
      ),
    );
  }
}

PairingScannerBuilder _scannerEmitting(MobileScannerErrorCode code) {
  return ({
    required void Function(PairingInfo info) onPair,
    required void Function(MobileScannerErrorCode errorCode) onCameraError,
  }) =>
      _FakeCameraScanner(
        onPair: onPair,
        onCameraError: onCameraError,
        code: code,
      );
}

PairingScannerBuilder _scannerDetecting(String raw) {
  return ({
    required void Function(PairingInfo info) onPair,
    required void Function(MobileScannerErrorCode errorCode) onCameraError,
  }) =>
      _FakeCameraScanner(
        onPair: onPair,
        onCameraError: onCameraError,
        emitDetection: raw,
      );
}

// ---------------------------------------------------------------------------

int counter = 0;

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.pairing_flow_tmp');
  late Directory tmp;
  final List<LocalDb> openDbs = <LocalDb>[];

  setUp(() {
    tmp = Directory(
      '${root.path}/${DateTime.now().microsecondsSinceEpoch}_$counter',
    );
    counter += 1;
    tmp.createSync(recursive: true);
    openDbs.clear();
  });

  tearDown(() async {
    for (final LocalDb db in openDbs) {
      try {
        await db.close();
      } catch (_) {
        // already closed
      }
    }
    openDbs.clear();
    try {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    } catch (_) {
      // best effort
    }
  });

  tearDownAll(() {
    try {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    } catch (_) {
      // best effort
    }
  });

  Future<LocalDb> openDbInTester(WidgetTester tester) async {
    final LocalDb? db = await tester.runAsync(
      () => LocalDb.open(pathOverride: '${tmp.path}/pairing.db'),
    );
    final LocalDb opened = db!;
    openDbs.add(opened);
    return opened;
  }

  /// Real event-loop windows so ffi futures parked from the fake zone run.
  Future<void> flushReal(WidgetTester tester, {int rounds = 4}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Minimal opener route so "pops back" is observable.
  Future<void> pumpOpener(
    WidgetTester tester, {
    required _FakeSyncClient client,
    PairingScannerBuilder? scannerBuilder,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open-pairing'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => PairingScreen(
                      client: client,
                      scannerBuilder: scannerBuilder,
                    ),
                  ),
                ),
                child: const Text('Open pairing'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openPairing(
    WidgetTester tester,
    _FakeSyncClient client, {
    PairingScannerBuilder? scannerBuilder,
  }) async {
    await pumpOpener(tester, client: client, scannerBuilder: scannerBuilder);
    await tester.tap(find.byKey(const Key('open-pairing')));
    await tester.pumpAndSettle();
    expect(find.byType(PairingScreen), findsOneWidget);
  }

  // -----------------------------------------------------------------------
  group('entry points', () {
    testWidgets('Home app bar Connect icon opens PairingScreen', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      final LocalDb db = await openDbInTester(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeCanvasDashboard(
            onOpenDocument: (_) {},
            db: db,
            baseDir: '${tmp.path}/SlateSync',
            client: client,
          ),
        ),
      );
      await flushReal(tester);

      expect(find.byKey(const Key('home-connect')), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-connect')));
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
      expect(find.byKey(const Key('pairing_title')), findsOneWidget);
      // All three modes visible.
      expect(find.byKey(const Key('pairing-discover')), findsOneWidget);
      expect(find.byKey(const Key('pairing-scan')), findsOneWidget);
      expect(find.byKey(const Key('pairing-manual')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('Studio top bar connection button opens PairingScreen', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Studio',
        preset: 'A4',
        background: 'BLANK',
        canvasId: 'pairing-studio',
        now: 1000,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasStudioPage(document: doc, client: client),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey<String>('studio-connect')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('studio-connect')));
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
      expect(find.byKey(const Key('pairing-discover')), findsOneWidget);
      expect(find.byKey(const Key('pairing-scan')), findsOneWidget);
      expect(find.byKey(const Key('pairing-manual')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await client.dispose();
    });
  });

  // -----------------------------------------------------------------------
  group('scan QR', () {
    testWidgets('parsePairingUrl → connect with fake client → pop back', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await openPairing(
        tester,
        client,
        scannerBuilder: _scannerDetecting(
          'slatesync://connect?ip=192.168.1.7&port=50606&token=abc123',
        ),
      );

      await tester.tap(find.byKey(const Key('pairing-scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fake-camera-live')), findsNothing);
      expect(find.byKey(const Key('fake-scan-emit')), findsOneWidget);

      await tester.tap(find.byKey(const Key('fake-scan-emit')));
      await tester.pumpAndSettle();

      expect(client.connects, <PairingInfo>[
        const PairingInfo(ipv4: '192.168.1.7', port: 50606, token: 'abc123'),
      ]);
      // Popped back to the opener — connection proceeds in the background.
      expect(find.byType(PairingScreen), findsNothing);
      expect(find.byKey(const Key('open-pairing')), findsOneWidget);
    });

    testWidgets('permission denied → manual fallback hint', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await openPairing(
        tester,
        client,
        scannerBuilder: _scannerEmitting(MobileScannerErrorCode.permissionDenied),
      );

      await tester.tap(find.byKey(const Key('pairing-scan')));
      await tester.pumpAndSettle(); // scanner frame + post-frame error

      expect(find.byKey(const Key('pairing-camera-fallback')), findsOneWidget);
      expect(
        find.byKey(const Key('pairing-camera-fallback-text')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Camera permission denied'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-manual-fallback')), findsOneWidget);
      expect(find.byType(PairingScreen), findsOneWidget); // still usable
    });

    testWidgets('no camera (unsupported) → manual fallback hint', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await openPairing(
        tester,
        client,
        scannerBuilder: _scannerEmitting(MobileScannerErrorCode.unsupported),
      );

      await tester.tap(find.byKey(const Key('pairing-scan')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pairing-camera-fallback')), findsOneWidget);
      expect(
        find.textContaining('No camera available'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-manual-fallback')), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  group('auto-discover', () {
    testWidgets('timeout → manual-entry hint stays on screen', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient()
        ..discoverError = TimeoutException(
          'SlateSync mDNS service not found',
          const Duration(seconds: 3),
        );
      await openPairing(tester, client);

      await tester.tap(find.byKey(const Key('pairing-discover')));
      await tester.pumpAndSettle();

      expect(client.discoverCalls, 1);
      expect(find.byKey(const Key('pairing-discover-hint')), findsOneWidget);
      expect(find.text(kDiscoverFailedHint), findsOneWidget);
      expect(find.byKey(const Key('pairing-manual')), findsOneWidget);
      expect(find.byType(PairingScreen), findsOneWidget); // no pop on failure
    });

    testWidgets('success → discover called once, screen pops back', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await openPairing(tester, client);

      await tester.tap(find.byKey(const Key('pairing-discover')));
      await tester.pumpAndSettle();

      expect(client.discoverCalls, 1);
      expect(find.byType(PairingScreen), findsNothing);
      expect(find.byKey(const Key('open-pairing')), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  group('manual IP', () {
    testWidgets('valid form → connect + both routes unwind', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await openPairing(tester, client);

      await tester.tap(find.byKey(const Key('pairing-manual')));
      await tester.pumpAndSettle();
      expect(find.byType(ManualPairingScreen), findsOneWidget);

      final Iterable<TextFormField> fields =
          tester.widgetList<TextFormField>(find.byType(TextFormField));
      expect(fields, hasLength(3));
      await tester.enterText(find.byType(TextFormField).at(0), '192.168.1.50');
      await tester.enterText(find.byType(TextFormField).at(2), 'tok-42');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(client.connects, <PairingInfo>[
        const PairingInfo(ipv4: '192.168.1.50', port: 50606, token: 'tok-42'),
      ]);
      expect(find.byType(ManualPairingScreen), findsNothing);
      expect(find.byType(PairingScreen), findsNothing);
      expect(find.byKey(const Key('open-pairing')), findsOneWidget);
    });

    testWidgets('invalid IPv4 is rejected before connect', (
      WidgetTester tester,
    ) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await openPairing(tester, client);

      await tester.tap(find.byKey(const Key('pairing-manual')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).at(0), '999.1.1.1');
      await tester.enterText(find.byType(TextFormField).at(2), 'tok');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Connect'));
      await tester.pumpAndSettle();

      expect(client.connects, isEmpty);
      expect(find.byType(ManualPairingScreen), findsOneWidget);
    });
  });
}
