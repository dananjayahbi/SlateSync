/// Round-12 issue 09 — tablet-side OCR wire protocol and client.
///
/// The PC is faked here: what matters is that the tablet builds valid
/// envelopes, correlates replies to its own job, and never hangs or mistakes a
/// failure for success.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/ocr/ocr_client.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

class _FakeClient extends VectorSyncClient {
  _FakeClient({this.connected = true});

  bool connected;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool throwOnSend = false;

  final StreamController<SyncEvent> _ctrl =
      StreamController<SyncEvent>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  Stream<SyncEvent> get events => _ctrl.stream;

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    if (throwOnSend) {
      throw StateError('socket closed');
    }
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

  void emit(Map<String, dynamic> message) {
    _ctrl.add(
      SyncEvent(kind: SyncEventKind.rpcReceived, msg: message),
    );
  }

  Future<void> close() async {
    await _ctrl.close();
  }
}

Map<String, dynamic> _progress(String jobId, String stage, int percent) =>
    <String, dynamic>{
      'type': 'OCR_JOB',
      'action': 'OCR_PROGRESS',
      'canvas_id': 'c-1',
      'payload': <String, dynamic>{
        'job_id': jobId,
        'stage': stage,
        'percent': percent,
      },
    };

Map<String, dynamic> _result(
  String jobId, {
  String text = 'hello world',
  String? error,
}) => <String, dynamic>{
  'type': 'OCR_JOB',
  'action': 'OCR_RESULT',
  'canvas_id': 'c-1',
  'payload': <String, dynamic>{
    'job_id': jobId,
    'text': text,
    'error': ?error,
    'provider': 'DmlExecutionProvider',
    'width': 400,
    'height': 200,
    'origin': <double>[10.0, 20.0],
    'elapsed_ms': 42,
    'lines': <Map<String, dynamic>>[
      <String, dynamic>{
        'text': text,
        'score': 0.99,
        'box': <double>[1, 2, 30, 20],
      },
    ],
  },
};

void main() {
  group('buildStartOcr', () {
    test('a region scan carries the polygon', () {
      final Map<String, dynamic> env = buildStartOcr(
        canvasId: 'c-1',
        jobId: 'j-1',
        scope: OcrScope.region,
        path: <WorldPoint>[
          <double>[0, 0],
          <double>[10, 0],
          <double>[10, 10],
        ],
      );
      final Map<String, dynamic> payload =
          env['payload'] as Map<String, dynamic>;
      expect(payload['scope'], 'region');
      expect((payload['path'] as List<dynamic>).length, 3);
    });

    test('a canvas scan sends no path', () {
      final Map<String, dynamic> env = buildStartOcr(
        canvasId: 'c-1',
        jobId: 'j-1',
        scope: OcrScope.canvas,
        path: <WorldPoint>[
          <double>[0, 0],
          <double>[10, 0],
          <double>[10, 10],
        ],
      );
      expect((env['payload'] as Map<String, dynamic>).containsKey('path'),
          isFalse);
    });

    test('the envelope has the frozen shape', () {
      final Map<String, dynamic> env = buildStartOcr(
        canvasId: 'c-1',
        jobId: 'j-1',
        scope: OcrScope.canvas,
      );
      expect(env['type'], 'OCR_JOB');
      expect(env['action'], 'START_OCR');
      expect(env['canvas_id'], 'c-1');
      expect(env['timestamp'], isA<int>());
      expect(env['id'], isA<String>());
    });

    test('padding is only sent when it is a usable number', () {
      final Map<String, dynamic> withPadding = buildStartOcr(
        canvasId: 'c-1',
        jobId: 'j',
        scope: OcrScope.canvas,
        padding: 4,
      );
      expect(withPadding['payload']['padding'], 4);

      final Map<String, dynamic> nan = buildStartOcr(
        canvasId: 'c-1',
        jobId: 'j',
        scope: OcrScope.canvas,
        padding: double.nan,
      );
      expect((nan['payload'] as Map<String, dynamic>).containsKey('padding'),
          isFalse);

      final Map<String, dynamic> negative = buildStartOcr(
        canvasId: 'c-1',
        jobId: 'j',
        scope: OcrScope.canvas,
        padding: -5,
      );
      expect(
          (negative['payload'] as Map<String, dynamic>).containsKey('padding'),
          isFalse);
    });
  });

  group('buildCancelOcr', () {
    test('it carries exactly the job id', () {
      final Map<String, dynamic> env =
          buildCancelOcr(canvasId: 'c-1', jobId: 'j-9');
      expect(env['action'], 'CANCEL_OCR');
      expect(env['payload'], <String, dynamic>{'job_id': 'j-9'});
    });
  });

  group('OcrOutcome.fromWire', () {
    test('it parses a full result', () {
      final OcrOutcome out =
          OcrOutcome.fromWire(_result('j-1')['payload'] as Map<String, dynamic>);
      expect(out.text, 'hello world');
      expect(out.lines.single.text, 'hello world');
      expect(out.provider, 'DmlExecutionProvider');
      expect(out.origin, <double>[10, 20]);
      expect(out.isError, isFalse);
      expect(out.hasText, isTrue);
    });

    test('an error payload is flagged and carries the reason', () {
      final OcrOutcome out = OcrOutcome.fromWire(
        _result('j-1', text: '', error: 'engine missing')['payload']
            as Map<String, dynamic>,
      );
      expect(out.isError, isTrue);
      expect(out.error, 'engine missing');
      expect(out.hasText, isFalse);
    });

    test('malformed lines are dropped rather than crashing', () {
      final OcrOutcome out = OcrOutcome.fromWire(<String, dynamic>{
        'text': 'ok',
        'lines': <dynamic>[
          'not a map',
          <String, dynamic>{'text': 'no box'},
          <String, dynamic>{
            'text': 'short box',
            'box': <double>[1, 2],
          },
          <String, dynamic>{
            'text': 'good',
            'box': <double>[1, 2, 3, 4],
          },
        ],
      });
      expect(out.lines.length, 1);
      expect(out.lines.single.text, 'good');
    });

    test('a missing origin falls back to the world root', () {
      final OcrOutcome out =
          OcrOutcome.fromWire(<String, dynamic>{'text': 'x'});
      expect(out.origin, <double>[0, 0]);
    });

    test('non-finite origin values are ignored', () {
      final OcrOutcome out = OcrOutcome.fromWire(<String, dynamic>{
        'text': 'x',
        'origin': <dynamic>[double.nan, 5],
      });
      expect(out.origin[0], 0);
      expect(out.origin[1], 5);
    });
  });

  group('OcrClient', () {
    test('it refuses to scan when the PC is not connected', () async {
      final _FakeClient fake = _FakeClient(connected: false);
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      await expectLater(
        ocr.scan(scope: OcrScope.canvas),
        throwsA(isA<OcrRequestError>()),
      );
      expect(fake.sent, isEmpty);
      await fake.close();
    });

    test('a region scan with fewer than three points is refused locally',
        () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      await expectLater(
        ocr.scan(
          scope: OcrScope.region,
          path: <WorldPoint>[
            <double>[0, 0],
            <double>[1, 1],
          ],
        ),
        throwsA(isA<OcrRequestError>()),
      );
      expect(fake.sent, isEmpty, reason: 'never ask the PC to do useless work');
      await fake.close();
    });

    test('a successful scan returns the recognised text', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      final Future<OcrOutcome> pending = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      final String jobId =
          (fake.sent.single['payload'] as Map<String, dynamic>)['job_id']
              as String;
      fake.emit(_progress(jobId, 'RECOGNISING', 55));
      fake.emit(_result(jobId));
      final OcrOutcome out = await pending;
      expect(out.text, 'hello world');
      await fake.close();
    });

    test('progress is streamed while the job runs', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      final List<OcrProgress> seen = <OcrProgress>[];
      final StreamSubscription<OcrProgress> sub =
          ocr.progress.listen(seen.add);
      final Future<OcrOutcome> pending = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      final String jobId =
          (fake.sent.single['payload'] as Map<String, dynamic>)['job_id']
              as String;
      fake.emit(_progress(jobId, 'RASTERISING', 20));
      fake.emit(_progress(jobId, 'RECOGNISING', 60));
      fake.emit(_result(jobId));
      await pending;
      await sub.cancel();
      expect(seen.map((OcrProgress p) => p.stage),
          containsAll(<String>['RASTERISING', 'RECOGNISING']));
      await fake.close();
    });

    test('a PC-side failure surfaces as an error, not empty success', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      final Future<OcrOutcome> pending = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      final String jobId =
          (fake.sent.single['payload'] as Map<String, dynamic>)['job_id']
              as String;
      fake.emit(_result(jobId, text: '', error: 'infinite canvas'));
      await expectLater(pending, throwsA(isA<OcrRequestError>()));
      await fake.close();
    });

    test('replies for a different job are ignored', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      final Future<OcrOutcome> pending = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      fake.emit(_result('someone-elses-job'));
      final String jobId =
          (fake.sent.single['payload'] as Map<String, dynamic>)['job_id']
              as String;
      fake.emit(_result(jobId, text: 'mine'));
      expect((await pending).text, 'mine');
      await fake.close();
    });

    test('a timeout rejects instead of hanging forever', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      await expectLater(
        ocr.scan(
          scope: OcrScope.canvas,
          timeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await fake.close();
    });

    test('a second scan while one is running is refused', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      final Future<OcrOutcome> first = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        ocr.scan(scope: OcrScope.canvas),
        throwsA(isA<OcrRequestError>()),
      );
      final String jobId =
          (fake.sent.single['payload'] as Map<String, dynamic>)['job_id']
              as String;
      fake.emit(_result(jobId));
      await first;
      await fake.close();
    });

    test('a send failure is reported and does not leave a job stuck', () async {
      final _FakeClient fake = _FakeClient()..throwOnSend = true;
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      await expectLater(
        ocr.scan(scope: OcrScope.canvas),
        throwsA(isA<OcrRequestError>()),
      );
      expect(ocr.jobId, isNull, reason: 'the client must be reusable after this');
      await fake.close();
    });

    test('cancel sends CANCEL_OCR for the running job', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      unawaited(ocr.scan(scope: OcrScope.canvas));
      await Future<void>.delayed(Duration.zero);
      await ocr.cancel();
      expect(fake.sent.length, 2);
      expect(fake.sent.last['action'], 'CANCEL_OCR');
      await fake.close();
    });

    test('cancel resolves the pending scan instead of leaving it hanging',
        () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      final Future<OcrOutcome> pending = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      await ocr.cancel();
      // Without this the UI sits on "scanning" forever.
      await expectLater(pending, throwsA(isA<OcrRequestError>()));
      await fake.close();
    });

    test('a scan works again after a cancel', () async {
      // The round-13 regression: a COMPLETED Completer can never be reused, so a
      // single long-lived one left every later scan awaiting a finished future.
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      unawaited(ocr.scan(scope: OcrScope.canvas));
      await Future<void>.delayed(Duration.zero);
      await ocr.cancel();

      final Future<OcrOutcome> second = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      final String jobId = (fake.sent.last['payload']
          as Map<String, dynamic>)['job_id'] as String;
      fake.emit(_result(jobId, text: 'second scan'));
      expect((await second).text, 'second scan');
      await fake.close();
    });

    test('a scan works again after a timeout', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      await expectLater(
        ocr.scan(
          scope: OcrScope.canvas,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );

      final Future<OcrOutcome> second = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      final String jobId = (fake.sent.last['payload']
          as Map<String, dynamic>)['job_id'] as String;
      fake.emit(_result(jobId, text: 'recovered'));
      expect((await second).text, 'recovered');
      await fake.close();
    });

    test('cancelling twice is harmless', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      unawaited(ocr.scan(scope: OcrScope.canvas));
      await Future<void>.delayed(Duration.zero);
      await ocr.cancel();
      await ocr.cancel(); // second call has no job to cancel
      await fake.close();
    });

    test('cancel with nothing running is a no-op', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      await ocr.cancel();
      expect(fake.sent, isEmpty);
      await fake.close();
    });

    test('progress still streams on the scan after a cancel', () async {
      // `_finish()` runs between jobs; if it closed the shared progress
      // controller, the second job's progress would be silently dropped.
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      final List<OcrProgress> seen = <OcrProgress>[];
      ocr.progress.listen(seen.add);

      unawaited(ocr.scan(scope: OcrScope.canvas));
      await Future<void>.delayed(Duration.zero);
      await ocr.cancel();

      final Future<OcrOutcome> second = ocr.scan(scope: OcrScope.canvas);
      await Future<void>.delayed(Duration.zero);
      final String jobId = (fake.sent.last['payload']
          as Map<String, dynamic>)['job_id'] as String;
      fake.emit(_progress(jobId, 'RECOGNISING', 60));
      await Future<void>.delayed(Duration.zero);
      fake.emit(_result(jobId, text: 'ok'));
      await second;
      expect(seen.map((OcrProgress p) => p.percent), contains(60.0));
      await ocr.dispose();
      await fake.close();
    });

    test('dispose releases the subscription', () async {
      final _FakeClient fake = _FakeClient();
      final OcrClient ocr = OcrClient(client: fake, canvasId: 'c-1');
      unawaited(ocr.scan(scope: OcrScope.canvas));
      await Future<void>.delayed(Duration.zero);
      await ocr.dispose();
      expect(ocr.jobId, isNull);
      await fake.close();
    });
  });
}
