/// Doc 27 §6 acceptance suite: `buildStartExport`/`buildCancelExport`
/// envelope shapes (outer + exact payload keys), PDF hides the DPI selector
/// yet still carries `dpi`, connection-aware PC/Both disabling with hint +
/// `stateChanged` re-evaluation, progress bar/stage/percent driven by a fake
/// `SyncEvent` stream (incl. stale-job filtering), Cancel → `CANCEL_EXPORT`
/// with `job_id`, success/failure snackbars (PC path, `ok:false` reason), and
/// out-of-order `FileChunk` reassembly into an injected
/// `Download/SlateSync/` root.
///
/// All widget tests use a fake `VectorSyncClient` — no network, no mDNS, no
/// `pc_agent` imports. Scratch state lives under `test/.export_sheet_tmp/`
/// inside the package (never `/tmp`) and is removed in `tearDown`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/features/export/export_modal_sheet.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake (Doc 27 §6: client is injected — widget tests never touch the network)
// ---------------------------------------------------------------------------

/// Doc 25 surface fake: records `sendRpc` envelopes (with the same field
/// validation Doc 25 §5 performs, so a missing `canvas_id` fails the test)
/// and replays a scripted `events` broadcast stream.
class _FakeSyncClient extends VectorSyncClient {
  _FakeSyncClient({this.connected = false});

  /// Backing store for [isConnected]; flip it, then emit `stateChanged`.
  bool connected;

  /// Envelopes accepted by `sendRpc`, in arrival order.
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  final StreamController<SyncEvent> _ctrl =
      StreamController<SyncEvent>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  Stream<SyncEvent> get events => _ctrl.stream;

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    for (final String field in const <String>[
      'type',
      'action',
      'canvas_id',
      'payload',
    ]) {
      if (!envelope.containsKey(field)) {
        throw FormatException('missing envelope field: $field');
      }
    }
    sent.add(envelope);
  }

  /// Pushes a Doc 25 event to the sheet's listener (call after opening).
  void emit(SyncEvent event) => _ctrl.add(event);

  @override
  Future<void> dispose() async {
    await _ctrl.close();
    await super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _canvasId = 'A4-test-canvas';

/// Hosts a button that opens the sheet, taps it, and settles the animation.
Future<void> _openSheet(
  WidgetTester tester, {
  required _FakeSyncClient client,
  String? baseDir,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => FilledButton(
            key: const ValueKey<String>('open-export'),
            onPressed: () => showExportSheet(
              context,
              client: client,
              canvasId: _canvasId,
              downloadsBaseDir: baseDir,
            ),
            child: const Text('Open export'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open-export')));
  await tester.pumpAndSettle();
}

RadioListTile<ExportTarget> _radioTile(WidgetTester tester, String key) =>
    tester.widget<RadioListTile<ExportTarget>>(
      find.byKey(ValueKey<String>(key)),
    );

Map<String, dynamic> _payloadOf(Map<String, dynamic> envelope) =>
    Map<String, dynamic>.from(envelope['payload']! as Map);

/// Advances past the SnackBar auto-dismiss timer and settles its exit
/// animation so no timers remain pending at test teardown.
Future<void> _clearSnackBars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  final Directory root = Directory('test/.export_sheet_tmp');
  late Directory tmp;

  setUp(() {
    tmp = Directory('${root.path}/${DateTime.now().microsecondsSinceEpoch}');
    tmp.createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  // Envelope shapes (unit — Doc 27 §5.5/§5.7, Doc 02 §4.2)
  // -------------------------------------------------------------------------

  test('buildStartExport: outer keys + payload keys EXACTLY canvas/format/dpi/target', () {
    final Map<String, dynamic> env = buildStartExport(
      canvasId: _canvasId,
      format: ExportFormat.png,
      dpi: 300,
      target: ExportTarget.tablet,
    );

    expect(
      env.keys,
      containsAll(<String>[
        'type',
        'action',
        'canvas_id',
        'payload',
        'timestamp',
        'id',
      ]),
    );
    expect(env['type'], 'EXPORT_JOB');
    expect(env['action'], 'START_EXPORT');
    expect(env['canvas_id'], _canvasId);
    expect(env['timestamp'], isA<int>());

    final Map<String, dynamic> payload = _payloadOf(env);
    expect(
      payload.keys.toSet(),
      <String>{'canvas_id', 'format', 'dpi', 'target'},
    );
    expect(payload['canvas_id'], _canvasId);
    expect(payload['format'], 'PNG');
    expect(payload['dpi'], 300);
    expect(payload['target'], 'TABLET');
  });

  test('buildCancelExport: EXPORT_JOB/CANCEL_EXPORT, payload has exactly job_id', () {
    final Map<String, dynamic> env = buildCancelExport('j1');

    expect(env['type'], 'EXPORT_JOB');
    expect(env['action'], 'CANCEL_EXPORT');
    final Map<String, dynamic> payload = _payloadOf(env);
    expect(payload.keys.toSet(), <String>{'job_id'});
    expect(payload['job_id'], 'j1');
  });

  // -------------------------------------------------------------------------
  // Format / DPI selection
  // -------------------------------------------------------------------------

  testWidgets('PDF hides DPI selector; PNG restores 300/600/1200; PDF still carries dpi', (
    tester,
  ) async {
    final _FakeSyncClient client = _FakeSyncClient();
    addTearDown(client.dispose);
    await _openSheet(tester, client: client);

    // PNG default ⇒ row visible with all three options.
    expect(find.byKey(const ValueKey<String>('dpi-row')), findsOneWidget);
    expect(find.text('300'), findsOneWidget);
    expect(find.text('600'), findsOneWidget);
    expect(find.text('1200'), findsOneWidget);

    // PDF ⇒ hidden entirely (vector per template §3).
    await tester.tap(find.byKey(const ValueKey<String>('format-pdf')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('dpi-row')), findsNothing);
    expect(find.text('300'), findsNothing);

    // PNG ⇒ back.
    await tester.tap(find.byKey(const ValueKey<String>('format-png')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('dpi-row')), findsOneWidget);

    // PDF submit: selector hidden but payload still carries dpi (default 300).
    await tester.tap(find.byKey(const ValueKey<String>('format-pdf')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('export-start')));
    await tester.pump();

    expect(client.sent, hasLength(1));
    final Map<String, dynamic> payload = _payloadOf(client.sent.first);
    expect(payload['format'], 'PDF');
    expect(payload['dpi'], 300);
    await _clearSnackBars(tester);
  });

  testWidgets('Start submits JPG + dpi 1200 verbatim', (tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    addTearDown(client.dispose);
    await _openSheet(tester, client: client);

    await tester.tap(find.byKey(const ValueKey<String>('format-jpg')));
    await tester.pump();
    await tester.tap(find.text('1200'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('export-start')));
    await tester.pump();

    expect(client.sent, hasLength(1));
    final Map<String, dynamic> env = client.sent.first;
    expect(env['action'], 'START_EXPORT');
    expect(env['canvas_id'], _canvasId);
    final Map<String, dynamic> payload = _payloadOf(env);
    expect(
      payload.keys.toSet(),
      <String>{'canvas_id', 'format', 'dpi', 'target'},
    );
    expect(payload['canvas_id'], _canvasId);
    expect(payload['format'], 'JPG');
    expect(payload['dpi'], 1200);
    expect(payload['target'], 'TABLET');
    await _clearSnackBars(tester);
  });

  // -------------------------------------------------------------------------
  // Connection-aware targets
  // -------------------------------------------------------------------------

  testWidgets('Disconnected: PC & Both disabled with hint, Tablet enabled; stateChanged flips all', (
    tester,
  ) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: false);
    addTearDown(client.dispose);
    await _openSheet(tester, client: client);

    expect(_radioTile(tester, 'target-pc').enabled, isFalse);
    expect(_radioTile(tester, 'target-both').enabled, isFalse);
    expect(_radioTile(tester, 'target-tablet').enabled, isTrue);
    expect(find.text('PC offline — connect to pair'), findsOneWidget);

    // Disabled taps must not change the selection.
    await tester.tap(find.byKey(const ValueKey<String>('target-pc')));
    await tester.pump();
    final RadioGroup<ExportTarget> group = tester.widget<
      RadioGroup<ExportTarget>
    >(find.byType(RadioGroup<ExportTarget>));
    expect(group.groupValue, ExportTarget.tablet);

    // Connect ⇒ all enabled, hint gone (re-evaluated on stateChanged).
    client.connected = true;
    client.emit(
      const SyncEvent(kind: SyncEventKind.stateChanged, state: SyncState.online),
    );
    await tester.pumpAndSettle();
    expect(_radioTile(tester, 'target-pc').enabled, isTrue);
    expect(_radioTile(tester, 'target-both').enabled, isTrue);
    expect(_radioTile(tester, 'target-tablet').enabled, isTrue);
    expect(find.text('PC offline — connect to pair'), findsNothing);
    await _clearSnackBars(tester);
  });

  // -------------------------------------------------------------------------
  // Progress + cancel
  // -------------------------------------------------------------------------

  testWidgets('Progress stream drives bar/stage/percent; stale job ignored; Cancel sends job_id', (
    tester,
  ) async {
    final _FakeSyncClient client = _FakeSyncClient();
    addTearDown(client.dispose);
    await _openSheet(tester, client: client);

    await tester.tap(find.byKey(const ValueKey<String>('export-start')));
    await tester.pump();
    expect(client.sent, hasLength(1));

    // Initial progress state: 0 %, stage "exporting", Cancel disabled (no job).
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey<String>('export-progress')),
          )
          .value,
      0.0,
    );
    expect(find.text('0%'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('export-stage')))
          .data,
      'exporting',
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey<String>('export-cancel')),
          )
          .onPressed,
      isNull,
    );

    // First Progress{jobId: j1} captures the job and updates the bar.
    client.emit(const SyncEvent(
      kind: SyncEventKind.progress,
      jobId: 'j1',
      percent: 42.0,
    ));
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey<String>('export-progress')),
          )
          .value,
      closeTo(0.42, 1e-9),
    );
    expect(find.text('42%'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey<String>('export-cancel')),
          )
          .onPressed,
      isNotNull,
    );

    // Stage text via EXPORT_PROGRESS rpcReceived (Doc 27 §5.6 msg["stage"]).
    client.emit(const SyncEvent(
      kind: SyncEventKind.rpcReceived,
      msg: <String, dynamic>{
        'type': 'EXPORT_JOB',
        'action': 'EXPORT_PROGRESS',
        'canvas_id': _canvasId,
        'payload': <String, dynamic>{
          'job_id': 'j1',
          'percent': 60.0,
          'stage': 'tiling',
        },
      },
    ));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('export-stage')))
          .data,
      'tiling',
    );
    expect(find.text('60%'), findsOneWidget);

    // Stale job ⇒ ignored, bar unchanged.
    client.emit(const SyncEvent(
      kind: SyncEventKind.progress,
      jobId: 'other',
      percent: 10.0,
    ));
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey<String>('export-progress')),
          )
          .value,
      closeTo(0.6, 1e-9),
    );
    expect(find.text('60%'), findsOneWidget);

    // Cancel ⇒ CANCEL_EXPORT envelope with payload {job_id: j1}.
    await tester.tap(find.byKey(const ValueKey<String>('export-cancel')));
    await tester.pump();
    expect(client.sent, hasLength(2));
    final Map<String, dynamic> cancel = client.sent[1];
    expect(cancel['type'], 'EXPORT_JOB');
    expect(cancel['action'], 'CANCEL_EXPORT');
    expect(cancel['canvas_id'], _canvasId); // Doc 25 sendRpc requires it
    final Map<String, dynamic> payload = _payloadOf(cancel);
    expect(payload.keys.toSet(), <String>{'job_id'});
    expect(payload['job_id'], 'j1');

    // Sheet resets to the config view after cancel.
    expect(find.byKey(const ValueKey<String>('export-start')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('export-progress')), findsNothing);
    await _clearSnackBars(tester);
  });

  // -------------------------------------------------------------------------
  // Terminal push snackbars (Doc 15 EXPORT_FINISHED via Doc 25 rpcReceived)
  // -------------------------------------------------------------------------

  testWidgets('PC finish (ok:true) selects target PC and shows Saved on PC snackbar', (
    tester,
  ) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    addTearDown(client.dispose);
    await _openSheet(tester, client: client);

    await tester.tap(find.byKey(const ValueKey<String>('target-pc')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('export-start')));
    await tester.pump();
    expect(_payloadOf(client.sent.first)['target'], 'PC');

    client.emit(const SyncEvent(
      kind: SyncEventKind.rpcReceived,
      msg: <String, dynamic>{
        'type': 'EXPORT_JOB',
        'action': 'EXPORT_FINISHED',
        'canvas_id': _canvasId,
        'payload': <String, dynamic>{
          'ok': true,
          'job_id': 'j8',
          'path': 'C:/PC/exports/doc.png',
          'percent': 100.0,
        },
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('Saved on PC: C:/PC/exports/doc.png'), findsOneWidget);
    // PC-only job ends ⇒ config view returns.
    expect(find.byKey(const ValueKey<String>('export-start')), findsOneWidget);
    await _clearSnackBars(tester);
  });

  testWidgets('ok:false shows failure snackbar with reason and resets the sheet', (
    tester,
  ) async {
    final _FakeSyncClient client = _FakeSyncClient();
    addTearDown(client.dispose);
    await _openSheet(tester, client: client);

    await tester.tap(find.byKey(const ValueKey<String>('export-start')));
    await tester.pump();

    client.emit(const SyncEvent(
      kind: SyncEventKind.rpcReceived,
      msg: <String, dynamic>{
        'type': 'EXPORT_JOB',
        'action': 'EXPORT_FINISHED',
        'canvas_id': _canvasId,
        'payload': <String, dynamic>{
          'ok': false,
          'job_id': 'j9',
          'reason': 'disk full',
        },
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('Export failed: disk full'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('export-start')), findsOneWidget);
    await _clearSnackBars(tester);
  });

  // -------------------------------------------------------------------------
  // Receipt → Download/SlateSync (injected root)
  // -------------------------------------------------------------------------

  testWidgets('Out-of-order FileChunks reassemble into injected Download/SlateSync', (
    tester,
  ) async {
    final _FakeSyncClient client = _FakeSyncClient();
    addTearDown(client.dispose);
    await _openSheet(tester, client: client, baseDir: tmp.path);

    await tester.tap(find.byKey(const ValueKey<String>('export-start')));
    await tester.pump();

    // Deliberately out of order: index 1 arrives before index 0.
    client.emit(SyncEvent(
      kind: SyncEventKind.fileChunk,
      transferId: 't1',
      index: 1,
      data: Uint8List.fromList(<int>[4, 5]),
    ));
    client.emit(SyncEvent(
      kind: SyncEventKind.fileChunk,
      transferId: 't1',
      index: 0,
      data: Uint8List.fromList(<int>[1, 2, 3]),
    ));
    client.emit(const SyncEvent(
      kind: SyncEventKind.fileReceived,
      transferId: 't1',
    ));
    await tester.pumpAndSettle();

    final File saved = File('${tmp.path}/Download/SlateSync/slatesync_t1.bin');
    expect(saved.existsSync(), isTrue);
    expect(saved.readAsBytesSync(), <int>[1, 2, 3, 4, 5]);

    expect(find.textContaining('Download/SlateSync/'), findsOneWidget);
    expect(find.textContaining('slatesync_t1.bin'), findsOneWidget);
    // Success ⇒ sheet reset to config.
    expect(find.byKey(const ValueKey<String>('export-start')), findsOneWidget);
    await _clearSnackBars(tester);
  });

  testWidgets('FileReceived with temp path is copied into Download/SlateSync', (
    tester,
  ) async {
    final _FakeSyncClient client = _FakeSyncClient();
    addTearDown(client.dispose);

    final File temp = File('${tmp.path}/temp_export.png')
      ..writeAsBytesSync(<int>[9, 9, 9]);
    await _openSheet(tester, client: client, baseDir: tmp.path);

    await tester.tap(find.byKey(const ValueKey<String>('export-start')));
    await tester.pump();

    client.emit(SyncEvent(
      kind: SyncEventKind.fileReceived,
      transferId: 't2',
      path: temp.path,
    ));
    await tester.pumpAndSettle();

    final File saved = File(
      '${tmp.path}/Download/SlateSync/temp_export.png',
    );
    expect(saved.existsSync(), isTrue);
    expect(saved.readAsBytesSync(), <int>[9, 9, 9]);
    expect(find.textContaining('temp_export.png'), findsOneWidget);
    await _clearSnackBars(tester);
  });
}
