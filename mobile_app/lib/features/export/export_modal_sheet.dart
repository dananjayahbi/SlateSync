// Doc 27: Flutter high-res export bottom sheet (Wave 2.A).
//
// Format (PNG/JPG/PDF), DPI (300/600/1200, hidden while PDF), target
// (PC/Tablet/Both with connection-aware disabling), job submission through
// the injected Doc 25 `VectorSyncClient.sendRpc`, live progress from
// `SyncEvent.Progress`, cancellation, and finished-file handling
// (`FileChunk`/`FileReceived` → `Download/SlateSync/`, or PC-path snackbar).
//
// Pure presentation + client calls: no `pc_agent` imports, no socket code
// beyond `sendRpc`/`events` on the injected client (faked in tests).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mobile_app/core/theme/studio_theme.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

/// Export raster/vector format; wire values `"PNG" | "JPG" | "PDF"`
/// (Doc 27 §4 — PDF is vector, so the DPI selector hides for it).
enum ExportFormat { png, jpg, pdf }

/// Export destination; wire values `"PC" | "TABLET" | "BOTH"`
/// (Doc 27 §4 — PC/Both need a live connection).
enum ExportTarget { pc, tablet, both }

/// Wire string for [ExportFormat] (Doc 27 §4 table).
String exportFormatWire(ExportFormat format) => switch (format) {
  ExportFormat.png => 'PNG',
  ExportFormat.jpg => 'JPG',
  ExportFormat.pdf => 'PDF',
};

/// Wire string for [ExportTarget] (Doc 27 §4 table).
String exportTargetWire(ExportTarget target) => switch (target) {
  ExportTarget.pc => 'PC',
  ExportTarget.tablet => 'TABLET',
  ExportTarget.both => 'BOTH',
};

/// Builds the Doc 02 §4.2 `EXPORT_JOB`/`START_EXPORT` envelope.
///
/// Outer keys: `id` (uuid-v4), `type`, `action`, `canvas_id`, `payload`,
/// `timestamp` (unix seconds). `payload` carries **exactly**
/// `canvas_id, format, dpi, target` (Doc 27 §5.5) — for PDF the hidden DPI
/// selector still contributes the last/default value; Doc 14's vector
/// exporter ignores it.
Map<String, dynamic> buildStartExport({
  required String canvasId,
  required ExportFormat format,
  required int dpi,
  required ExportTarget target,
}) {
  return <String, dynamic>{
    'id': uuidV4(),
    'type': 'EXPORT_JOB',
    'action': 'START_EXPORT',
    'canvas_id': canvasId,
    'payload': <String, dynamic>{
      'canvas_id': canvasId,
      'format': exportFormatWire(format),
      'dpi': dpi,
      'target': exportTargetWire(target),
    },
    'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
  };
}

/// Builds the `EXPORT_JOB`/`CANCEL_EXPORT` envelope: `payload` has exactly
/// one key, `job_id` (Doc 27 §5.7 / Doc 02 §4.2). `id`/`timestamp` are
/// filled here; the sheet merges `canvas_id` (also required by Doc 25
/// `sendRpc` validation) before sending.
Map<String, dynamic> buildCancelExport(String jobId) {
  return <String, dynamic>{
    'id': uuidV4(),
    'type': 'EXPORT_JOB',
    'action': 'CANCEL_EXPORT',
    'payload': <String, dynamic>{'job_id': jobId},
    'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
  };
}

/// Last path segment, tolerant of both separators.
String _basename(String path) {
  final int i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? path : path.substring(i + 1);
}

/// [Object?] → [String] cast helper (payload values arrive as `dynamic`).
String? _stringOf(Object? value) => value is String ? value : null;

/// Resolves the storage root: injected [baseDir] (tests) or the Doc 05
/// `path_provider` external-storage directory.
Future<String> _resolveBaseDir(String? baseDir) async {
  if (baseDir != null) return baseDir;
  // Doc 27 §5.8 scoped-storage note: the app-specific external dir needs no
  // permission on API 29+. Writing the *public* `Download/` tree directly can
  // throw `FileSystemException` there; the production fallback is
  // MediaStore.Downloads / SAF `ACTION_CREATE_DOCUMENT` (outside this pure
  // sheet's scope) — surfaced to the user via the error snackbar.
  final Directory? external = await getExternalStorageDirectory();
  if (external != null) return external.path;
  final Directory docs = await getApplicationDocumentsDirectory();
  return docs.path;
}

/// Copies [srcPath] into `<root>/Download/SlateSync/<basename>` and returns
/// the destination path (Doc 27 §4). [baseDir] injects the storage root in
/// tests; production resolves it via `path_provider`.
Future<String> saveToDownloads(String srcPath, {String? baseDir}) async {
  final File src = File(srcPath);
  if (!src.existsSync()) {
    throw FileSystemException('missing export temp file', srcPath);
  }
  final String root = await _resolveBaseDir(baseDir);
  final String dirPath = '$root/Download/SlateSync';
  Directory(dirPath).createSync(recursive: true);
  final String dest = '$dirPath/${_basename(srcPath)}';
  src.copySync(dest);
  return dest;
}

/// Writes reassembled chunk bytes into `<root>/Download/SlateSync/<filename>`
/// (chunk-merge path of Doc 27 §5.8 when Doc 25's temp file is unavailable).
Future<String> _saveBytes(
  Uint8List bytes,
  String filename,
  String? baseDir,
) async {
  final String root = await _resolveBaseDir(baseDir);
  final String dirPath = '$root/Download/SlateSync';
  Directory(dirPath).createSync(recursive: true);
  final String dest = '$dirPath/$filename';
  File(dest).writeAsBytesSync(bytes, flush: true);
  return dest;
}

/// Presents the Doc 27 export bottom sheet.
///
/// [client] is injected (faked in tests); [canvasId] seeds the `START_EXPORT`
/// envelope; [downloadsBaseDir] overrides the `Download/SlateSync/` root in
/// widget tests (production uses `path_provider`).
Future<void> showExportSheet(
  BuildContext context, {
  required VectorSyncClient client,
  required String canvasId,
  String? downloadsBaseDir,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: StudioTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(StudioTheme.radiusLarge),
      ),
    ),
    builder: (BuildContext sheetContext) => _ExportSheet(
      client: client,
      canvasId: canvasId,
      downloadsBaseDir: downloadsBaseDir,
    ),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({
    required this.client,
    required this.canvasId,
    this.downloadsBaseDir,
  });

  final VectorSyncClient client;
  final String canvasId;
  final String? downloadsBaseDir;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  StreamSubscription<SyncEvent>? _sub;

  // Selection state (config phase).
  ExportFormat _format = ExportFormat.png;
  int _dpi = 300;
  ExportTarget _target = ExportTarget.tablet;
  bool _connected = false;

  // Progress state.
  bool _running = false;
  String? _jobId;
  double _percent = 0;
  String? _stage;

  // FileChunk accumulation: transferId → index → bytes (Doc 27 §5.8).
  final Map<String, Map<int, Uint8List>> _chunks =
      <String, Map<int, Uint8List>>{};

  @override
  void initState() {
    super.initState();
    _connected = widget.client.isConnected;
    _sub = widget.client.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // -- Doc 25 event stream -------------------------------------------------

  void _onEvent(SyncEvent event) {
    if (!mounted) return;
    switch (event.kind) {
      case SyncEventKind.stateChanged:
        setState(() {
          _connected = widget.client.isConnected;
        });
      case SyncEventKind.rpcReceived:
        _onRpcReceived(event.msg);
      case SyncEventKind.progress:
        _applyProgress(
          jobId: event.jobId,
          percent: event.percent,
          stage: _stringOf(event.msg?['stage']),
        );
      case SyncEventKind.fileChunk:
        _accumulateChunk(event);
      case SyncEventKind.fileReceived:
        unawaited(_onFileReceived(event));
    }
  }

  void _onRpcReceived(Map<String, dynamic>? msg) {
    if (msg == null) return;
    final Object? raw = msg['payload'];
    if (raw is! Map) return;
    final Map<String, dynamic> payload = Map<String, dynamic>.from(raw);
    if (msg['action'] == 'EXPORT_PROGRESS') {
      _applyProgress(
        jobId: _stringOf(payload['job_id']),
        percent: (payload['percent'] as num?)?.toDouble(),
        stage: _stringOf(payload['stage']),
      );
      return;
    }
    // Terminal push (Doc 15 EXPORT_FINISHED): sheet keys off `payload.ok`
    // / `payload.path` regardless of action name (Doc 27 §7 note).
    if (payload.containsKey('ok')) _onFinished(payload);
  }

  void _applyProgress({String? jobId, double? percent, String? stage}) {
    if (!_running) return;
    // Stale jobs from a previous run are ignored (Doc 27 §5.10).
    if (jobId != null && _jobId != null && jobId != _jobId) return;
    setState(() {
      _jobId ??= jobId;
      if (percent != null) _percent = percent.clamp(0, 100).toDouble();
      if (stage != null && stage.isNotEmpty) _stage = stage;
    });
  }

  void _onFinished(Map<String, dynamic> payload) {
    final String? jobId = _stringOf(payload['job_id']);
    if (jobId != null && _jobId != null && jobId != _jobId) return;
    if (payload['ok'] != true) {
      final Object? reason =
          payload['reason'] ?? payload['reasonCode'] ?? 'unknown error';
      _snack('Export failed: $reason', error: true);
      if (mounted) setState(_stop);
      return;
    }
    final Object? path = payload['path'];
    if ((_target == ExportTarget.pc || _target == ExportTarget.both) &&
        path is String &&
        path.isNotEmpty) {
      _snack('Saved on PC: $path');
    }
    // PC-only jobs are done; tablet/both keep running until FileReceived
    // delivers the chunked file (Doc 15 pushes ASSET_* after the finish).
    if (_target == ExportTarget.pc && mounted) setState(_stop);
  }

  void _accumulateChunk(SyncEvent event) {
    final String? transferId = event.transferId;
    final int? index = event.index;
    final Uint8List? data = event.data;
    if (transferId == null || index == null || data == null) return;
    _chunks.putIfAbsent(
      transferId,
      () => <int, Uint8List>{},
    )[index] = data; // out-of-order arrival is fine
  }

  Future<void> _onFileReceived(SyncEvent event) async {
    final String? transferId = event.transferId;
    final Map<int, Uint8List>? parts =
        transferId == null ? null : _chunks.remove(transferId);
    final String? src = event.path;
    try {
      final String saved;
      if (src != null && File(src).existsSync()) {
        // Doc 25 reassembled temp file (Doc 27 §5.8) — move into Downloads.
        saved = await saveToDownloads(src, baseDir: widget.downloadsBaseDir);
      } else if (parts != null && parts.isNotEmpty) {
        // Temp file unavailable — reassemble accumulated chunks ourselves.
        final List<int> indices = parts.keys.toList()..sort();
        final List<int> merged = <int>[];
        for (final int i in indices) {
          merged.addAll(parts[i]!);
        }
        final String name =
            src != null ? _basename(src) : 'slatesync_$transferId.bin';
        saved = await _saveBytes(
          Uint8List.fromList(merged),
          name,
          widget.downloadsBaseDir,
        );
      } else {
        _snack('Export failed: no file received', error: true);
        if (mounted) setState(_stop);
        return;
      }
      if (!mounted) return;
      setState(_stop);
      _snack('Saved to $saved');
    } catch (error) {
      if (!mounted) return;
      _snack('Could not save export: $error', error: true);
    }
  }

  // -- user actions --------------------------------------------------------

  Future<void> _start() async {
    final Map<String, dynamic> envelope = buildStartExport(
      canvasId: widget.canvasId,
      format: _format,
      dpi: _dpi,
      target: _target,
    );
    setState(() {
      _running = true;
      _jobId = null;
      _percent = 0;
      _stage = 'exporting';
      _chunks.clear();
    });
    try {
      await widget.client.sendRpc(envelope);
    } catch (error) {
      if (!mounted) return;
      setState(_stop);
      _snack('Could not start export: $error', error: true);
    }
  }

  Future<void> _cancel() async {
    final String? jobId = _jobId;
    if (jobId == null) return; // Cancel needs the captured job id (§5.7)
    final Map<String, dynamic> envelope = <String, dynamic>{
      ...buildCancelExport(jobId),
      'canvas_id': widget.canvasId, // required by Doc 25 sendRpc validation
    };
    setState(_stop);
    try {
      await widget.client.sendRpc(envelope);
    } catch (error) {
      if (!mounted) return;
      _snack('Could not cancel export: $error', error: true);
    }
  }

  void _stop() {
    _running = false;
    _jobId = null;
    _percent = 0;
    _stage = null;
    _chunks.clear();
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            color: error ? StudioTheme.bg : StudioTheme.text,
            fontSize: StudioTheme.bodySize,
          ),
        ),
        backgroundColor: error ? StudioTheme.danger : StudioTheme.accent,
      ),
    );
  }

  // -- builders ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: SingleChildScrollView(
          child: _running ? _buildProgressView() : _buildConfigView(),
        ),
      ),
    );
  }

  Widget _buildConfigView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text(
          'Export',
          style: TextStyle(
            color: StudioTheme.text,
            fontSize: StudioTheme.titleSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        _buildFormatChips(),
        const SizedBox(height: 12),
        // DPI applies to raster formats only; PDF is vector (template §3).
        if (_format != ExportFormat.pdf) ...<Widget>[
          _buildDpiRow(),
          const SizedBox(height: 12),
        ],
        _buildTargetSection(),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey<String>('export-start'),
            onPressed: _start,
            child: const Text('Start export'),
          ),
        ),
      ],
    );
  }

  Widget _buildFormatChips() {
    return Wrap(
      spacing: 8,
      children: <Widget>[
        _formatChip(ExportFormat.png, 'PNG'),
        _formatChip(ExportFormat.jpg, 'JPG'),
        _formatChip(ExportFormat.pdf, 'PDF'),
      ],
    );
  }

  Widget _formatChip(ExportFormat format, String label) {
    final bool selected = _format == format;
    return ChoiceChip(
      key: ValueKey<String>('format-${label.toLowerCase()}'),
      label: Text(label),
      selected: selected,
      selectedColor: StudioTheme.accent,
      labelStyle: TextStyle(
        color: selected ? StudioTheme.bg : StudioTheme.text,
        fontWeight: FontWeight.w600,
      ),
      onSelected: (_) => setState(() => _format = format),
    );
  }

  Widget _buildDpiRow() {
    return Wrap(
      key: const ValueKey<String>('dpi-row'),
      spacing: 8,
      children: <Widget>[_dpiChip(300), _dpiChip(600), _dpiChip(1200)],
    );
  }

  Widget _dpiChip(int dpi) {
    final bool selected = _dpi == dpi;
    return ChoiceChip(
      label: Text('$dpi'),
      selected: selected,
      selectedColor: StudioTheme.accent,
      labelStyle: TextStyle(
        color: selected ? StudioTheme.bg : StudioTheme.text,
        fontWeight: FontWeight.w600,
      ),
      onSelected: (_) => setState(() => _dpi = dpi),
    );
  }

  Widget _buildTargetSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text(
          'Target',
          style: TextStyle(
            color: StudioTheme.text,
            fontSize: StudioTheme.captionSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        RadioGroup<ExportTarget>(
          groupValue: _target,
          onChanged: (ExportTarget? value) {
            if (value != null) setState(() => _target = value);
          },
          child: Column(
            children: <Widget>[
              RadioListTile<ExportTarget>(
                key: const ValueKey<String>('target-pc'),
                value: ExportTarget.pc,
                enabled: _connected,
                title: const Text('PC'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<ExportTarget>(
                key: const ValueKey<String>('target-tablet'),
                value: ExportTarget.tablet,
                enabled: true,
                title: const Text('Tablet'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<ExportTarget>(
                key: const ValueKey<String>('target-both'),
                value: ExportTarget.both,
                enabled: _connected,
                title: const Text('Both'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
        if (!_connected)
          const Padding(
            padding: EdgeInsets.only(left: 12),
            child: Text(
              'PC offline — connect to pair',
              style: TextStyle(
                color: StudioTheme.danger,
                fontSize: StudioTheme.captionSize,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildProgressView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Text(
          'Exporting…',
          style: TextStyle(
            color: StudioTheme.text,
            fontSize: StudioTheme.titleSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          key: const ValueKey<String>('export-progress'),
          value: _percent.clamp(0, 100).toDouble() / 100,
          color: StudioTheme.accent,
          backgroundColor: StudioTheme.strokeCanvas,
          minHeight: 8,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              _stage ?? 'exporting',
              key: const ValueKey<String>('export-stage'),
              style: const TextStyle(
                color: StudioTheme.text,
                fontSize: StudioTheme.captionSize,
              ),
            ),
            Text(
              '${_percent.round()}%',
              key: const ValueKey<String>('export-percent'),
              style: const TextStyle(
                color: StudioTheme.accent,
                fontSize: StudioTheme.captionSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            key: const ValueKey<String>('export-cancel'),
            onPressed: _jobId == null ? null : _cancel,
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }
}
