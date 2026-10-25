/// Round-12 issue 09 — OCR wire protocol (tablet side).
///
/// The tablet never recognises anything itself; it *asks*, and the PC does the
/// work. This file is deliberately just the message shapes plus a small client,
/// so the UI stays thin and the envelopes stay unit-testable without a socket.
library;

import 'dart:async';

import 'package:mobile_app/network/vector_sync_client.dart';

/// Which part of the canvas to scan.
enum OcrScope {
  /// A free-drawn outline. The only option on an infinite canvas.
  region,

  /// The whole artboard. Refused by the PC when the canvas is infinite.
  canvas,
}

/// Wire string for [OcrScope] (Doc 02 §11.1).
String ocrScopeWire(OcrScope scope) =>
    scope == OcrScope.canvas ? 'canvas' : 'region';

/// A point in WORLD units, `[x, y]`.
typedef WorldPoint = List<double>;

/// Builds the `OCR_JOB`/`START_OCR` envelope.
///
/// [path] is the free-drawn polygon for [OcrScope.region]; it is ignored for a
/// whole-canvas scan. Fewer than three usable points is a client-side error the
/// caller should catch before sending, but the PC rejects it too.
Map<String, dynamic> buildStartOcr({
  required String canvasId,
  required String jobId,
  required OcrScope scope,
  List<WorldPoint>? path,
  double? padding,
  String? id,
  DateTime? now,
}) {
  final Map<String, dynamic> payload = <String, dynamic>{
    'job_id': jobId,
    'scope': ocrScopeWire(scope),
  };
  if (scope == OcrScope.region && path != null && path.isNotEmpty) {
    payload['path'] = <List<double>>[
      for (final WorldPoint point in path) <double>[point[0], point[1]],
    ];
  }
  if (padding != null && padding.isFinite && padding >= 0) {
    payload['padding'] = padding;
  }  return <String, dynamic>{
    'id': id ?? uuidV4(),
    'type': 'OCR_JOB',
    'action': 'START_OCR',
    canvasIdKey: canvasId,
    'payload': payload,
    'timestamp': _timestamp(now),
  };
}

/// Builds the `OCR_JOB`/`CANCEL_OCR` envelope.
Map<String, dynamic> buildCancelOcr({
  required String canvasId,
  required String jobId,
  String? id,
  DateTime? now,
}) {
  return <String, dynamic>{
    'id': id ?? uuidV4(),
    'type': 'OCR_JOB',
    'action': 'CANCEL_OCR',
    canvasIdKey: canvasId,
    'payload': <String, dynamic>{'job_id': jobId},
    'timestamp': _timestamp(now),
  };
}

/// Envelope key holding the canvas id. Spelled out once so a rename is a
/// single edit rather than a hunt through string literals.
const String canvasIdKey = 'canvas_id';

int _timestamp(DateTime? now) =>
    ((now ?? DateTime.now()).toUtc().millisecondsSinceEpoch) ~/ 1000;

/// One recognised line, positioned in the scan raster's pixel space.
class OcrLine {
  const OcrLine({
    required this.text,
    required this.score,
    required this.box,
  });

  final String text;
  final double score;

  /// `(x0, y0, x1, y1)` within the raster the PC reported.
  final List<double> box;

  static OcrLine? fromWire(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? text = raw['text'];
    if (text is! String || text.trim().isEmpty) {
      return null;
    }
    final Object? box = raw['box'];
    if (box is! List || box.length < 4) {
      return null;
    }
    final List<double> parsed = <double>[];
    for (final Object? value in box.take(4)) {
      if (value is! num || !value.isFinite) {
        return null;
      }
      parsed.add(value.toDouble());
    }
    final Object? score = raw['score'];
    return OcrLine(
      text: text,
      score: score is num && score.isFinite ? score.toDouble() : 1.0,
      box: parsed,
    );
  }
}

/// A completed OCR job: the text plus where it came from.
class OcrOutcome {
  const OcrOutcome({
    required this.text,
    this.lines = const <OcrLine>[],
    this.provider,
    this.width = 0,
    this.height = 0,
    this.origin = const <double>[0, 0],
    this.elapsedMs = 0,
    this.error,
  });

  final String text;
  final List<OcrLine> lines;

  /// ONNX Runtime provider the PC actually used; `DmlExecutionProvider` means
  /// the GPU did the work. Surfaced so a silent CPU fallback is visible.
  final String? provider;

  /// Size of the raster the boxes refer to, in pixels.
  final int width;
  final int height;

  /// World-space top-left of that raster, so boxes can be mapped to the canvas.
  final List<double> origin;

  final int elapsedMs;

  /// Non-null when the scan failed; [text] is then empty.
  final String? error;

  bool get isError => error != null && error!.isNotEmpty;
  bool get hasText => text.trim().isNotEmpty;

  static OcrOutcome fromWire(Map<String, dynamic> payload) {
    final Object? rawLines = payload['lines'];
    final List<OcrLine> lines = <OcrLine>[];
    if (rawLines is List) {
      for (final Object? entry in rawLines) {
        final OcrLine? line = OcrLine.fromWire(entry);
        if (line != null) {
          lines.add(line);
        }
      }
    }
    final Object? origin = payload['origin'];
    final List<double> originOut = <double>[0, 0];
    if (origin is List && origin.length >= 2) {
      for (int i = 0; i < 2; i++) {
        final Object? value = origin[i];
        if (value is num && value.isFinite) {
          originOut[i] = value.toDouble();
        }
      }
    }
    final Object? error = payload['error'];
    return OcrOutcome(
      text: payload['text'] is String ? payload['text'] as String : '',
      lines: lines,
      provider: payload['provider'] is String
          ? payload['provider'] as String
          : null,
      width: (payload['width'] as num?)?.toInt() ?? 0,
      height: (payload['height'] as num?)?.toInt() ?? 0,
      origin: originOut,
      elapsedMs: (payload['elapsed_ms'] as num?)?.toInt() ?? 0,
      error: error is String && error.isNotEmpty ? error : null,
    );
  }
}

/// Thrown when a scan cannot be requested at all.
class OcrRequestError implements Exception {
  const OcrRequestError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Progress for one job, as reported by the PC.
class OcrProgress {
  const OcrProgress({required this.stage, required this.percent});

  final String stage;
  final double percent;
}

/// Sends OCR jobs and correlates the PC's stream of replies back to one job.
///
/// Kept separate from the widget so the whole request/response dance is
/// testable against a fake [VectorSyncClient] with no UI at all.
class OcrClient {
  OcrClient({required this.client, required this.canvasId});

  final VectorSyncClient client;
  final String canvasId;

  /// Total time to wait for a terminal result before giving up. Rasterising a
  /// large canvas at 300 DPI plus model start-up is seconds, not milliseconds;
  /// this is a backstop against a hang, not a normal timeout.
  static const Duration defaultTimeout = Duration(seconds: 120);

  StreamSubscription<SyncEvent>? _sub;
  String? _jobId;

  /// Re-created per job. A [Completer] can only be completed once, so a single
  /// long-lived instance would leave every scan after the first cancel or
  /// timeout waiting on a future that had already been finished.
  Completer<OcrOutcome> _done = Completer<OcrOutcome>();
  final StreamController<OcrProgress> _progress =
      StreamController<OcrProgress>.broadcast();
  Timer? _timer;

  /// Progress updates for the in-flight job.
  Stream<OcrProgress> get progress => _progress.stream;

  String? get jobId => _jobId;

  /// Requests a scan and completes with the recognised text.
  ///
  /// Throws [OcrRequestError] when the request is not sendable (no connection,
  /// empty selection) and [TimeoutException] if the PC never answers.
  Future<OcrOutcome> scan({
    required OcrScope scope,
    List<WorldPoint>? path,
    double? padding,
    Duration timeout = defaultTimeout,
  }) async {
    if (!client.isConnected) {
      throw const OcrRequestError(
        'Connect to your PC first — OCR runs on the PC.',
      );
    }
    if (scope == OcrScope.region && (path == null || path.length < 3)) {
      throw const OcrRequestError(
        'Draw a closed outline around the text you want to scan.',
      );
    }
    if (_jobId != null) {
      throw const OcrRequestError('A scan is already running.');
    }

    final String jobId = uuidV4();
    _jobId = jobId;
    _done = Completer<OcrOutcome>();
    _sub = client.events.listen(_onEvent);
    _timer = Timer(timeout, () {
      if (!_done.isCompleted) {
        _done.future.ignore(); // see cancel(): avoid an unhandled async error
        _done.completeError(
          TimeoutException('The PC did not answer the scan request.', timeout),
        );
        unawaited(_finish());
      }
    });

    try {
      await client.sendRpc(
        buildStartOcr(
          canvasId: canvasId,
          jobId: jobId,
          scope: scope,
          path: path,
          padding: padding,
        ),
      );
    } catch (error) {
      await _finish();
      throw OcrRequestError('Could not send the scan request: $error');
    }
    return _done.future;
  }

  /// Asks the PC to abandon the job and resolves the pending [scan].
  ///
  /// The pending future MUST be resolved here. Cancelling only the local
  /// subscription would leave the caller awaiting a future nothing can ever
  /// complete — the UI would sit on "scanning" forever even though the PC had
  /// stopped, which is exactly how a cancel that "does nothing" feels.
  Future<void> cancel() async {
    final String? jobId = _jobId;
    if (jobId == null) {
      return;
    }
    if (!_done.isCompleted) {
      // Attach a sink BEFORE completing: `completeError` on a future with no
      // listener is an unhandled async error, which crashes tests and would
      // surface as a console error in release builds. The caller still sees the
      // error through its own await.
      _done.future.ignore();
      _done.completeError(const OcrRequestError('Scan cancelled.'));
    }
    try {
      await client.sendRpc(
        buildCancelOcr(canvasId: canvasId, jobId: jobId),
      );
    } catch (_) {
      // A cancel that cannot be delivered is not worth surfacing: the local
      // job is torn down either way.
    }
    await _finish();
  }

  /// Releases the subscription and timer. Call from `dispose`.
  Future<void> dispose() async {
    await _finish();
    // Closed only on real disposal: `_finish()` runs between jobs too, and
    // closing the shared controller there would silently drop the next job's
    // progress events.
    if (!_progress.isClosed) {
      await _progress.close();
    }
  }

  Future<void> _finish() async {
    // Clear every field that `scan()` checks BEFORE the first `await`. Teardown
    // parks on a microtask; if `_jobId` were still set when control returned,
    // an immediate retry (the normal case after a timeout) would be rejected
    // with "A scan is already running."
    _timer?.cancel();
    _timer = null;
    _jobId = null;
    final StreamSubscription<SyncEvent>? sub = _sub;
    _sub = null;
    await sub?.cancel();
  }

  void _onEvent(SyncEvent event) {
    if (event.kind != SyncEventKind.rpcReceived) {
      return;
    }
    final Map<String, dynamic>? msg = event.msg;
    if (msg == null || msg['type'] != 'OCR_JOB') {
      return;
    }
    final Object? rawPayload = msg['payload'];
    if (rawPayload is! Map) {
      return;
    }
    final Map<String, dynamic> payload = Map<String, dynamic>.from(rawPayload);
    // Ignore replies belonging to someone else's job.
    final Object? jobId = payload['job_id'];
    if (jobId is String && _jobId != null && jobId != _jobId) {
      return;
    }

    switch (msg['action']) {
      case 'OCR_PROGRESS':
        final double percent =
            ((payload['percent'] as num?)?.toDouble() ?? 0).clamp(0, 100);
        final String stage =
            payload['stage'] is String ? payload['stage'] as String : '';
        if (!_progress.isClosed) {
          _progress.add(OcrProgress(stage: stage, percent: percent));
        }
      case 'OCR_RESULT':
        if (!_done.isCompleted) {
          final OcrOutcome outcome = OcrOutcome.fromWire(payload);
          if (outcome.isError) {
            _done.completeError(OcrRequestError(outcome.error!));
          } else {
            _done.complete(outcome);
          }
        }
        unawaited(_finish());
    }
  }
}
