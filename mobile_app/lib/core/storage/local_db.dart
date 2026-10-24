/// Doc 26 — LocalDb (sqflite) + `.slatesync` tablet cache.
///
/// Owns the `canvases` table backing the home gallery (Doc 26 §5.1–5.2:
/// CRUD + title search ordered `updated_at DESC`) and the ZIP container
/// read/write (`document.json` + `assets/*`, template §3) under
/// path_provider app-documents/SlateSync (Doc 05 `path_provider` +
/// `archive`, consumed never redefined).
///
/// Test seams (Doc 26 §4): [LocalDb.open] takes `pathOverride` for
/// `sqflite_common_ffi`; [saveDocument]/[loadDocument] take an optional
/// `baseDir` so widget tests point at a directory inside the test bundle —
/// never `/tmp`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart'; // Doc 05 pubspec
import 'package:path_provider/path_provider.dart'; // Doc 05 pubspec
import 'package:sqflite/sqflite.dart'; // Doc 05 pubspec

import 'package:mobile_app/canvas_engine/thumbnail_renderer.dart'
    show saveDocThumbnail; // Doc 02 §10.6 FROZEN (read-only import)
import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05

/// Doc 02 §10.6 seam: thumbnail generator signature used by the save path
/// and the gallery backfill. Implementations MUST write the PNG to [outPath]
/// (canonical `<base>/thumbs/<canvas_id>.png`) and return the path written.
/// Tests inject fakes here for determinism; production defaults to the
/// frozen `saveDocThumbnail`.
typedef ThumbGenerator = Future<String> Function(
  CanvasDocumentModel doc,
  String outPath,
);

/// One gallery row of the `canvases` table (Doc 26 §4).
class CanvasRecord {
  const CanvasRecord({
    required this.id,
    required this.title,
    required this.preset,
    required this.background,
    required this.thumbPath,
    required this.filePath,
    required this.updatedAt,
  });

  final String id;
  final String title;

  /// Artboard preset key: `A5 | A4 | LETTER | INFINITE` (template §3).
  final String preset;

  /// Background template: `BLANK | RULED | DOT_GRID | ISO_GRID`.
  final String background;
  final String thumbPath;
  final String filePath;
  final int updatedAt;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'preset': preset,
        'background': background,
        'thumb_path': thumbPath,
        'file_path': filePath,
        'updated_at': updatedAt,
      };

  factory CanvasRecord.fromMap(Map<String, dynamic> map) => CanvasRecord(
        id: map['id'] as String,
        title: map['title'] as String,
        preset: map['preset'] as String,
        background: map['background'] as String,
        thumbPath: (map['thumb_path'] as String?) ?? '',
        filePath: (map['file_path'] as String?) ?? '',
        updatedAt: (map['updated_at'] as num?)?.toInt() ?? 0,
      );
}

/// SQLite access for the home dashboard (Doc 26 §4/§5.1–5.2).
class LocalDb {
  LocalDb._(this._db);

  final Database _db;

  static const String table = 'canvases';

  static const String _createSql = 'CREATE TABLE canvases('
      'id TEXT PRIMARY KEY, title TEXT, preset TEXT, background TEXT, '
      'thumb_path TEXT, file_path TEXT, updated_at INTEGER)';

  /// Open the database. `pathOverride` is a full file path (used by
  /// `sqflite_common_ffi` tests); otherwise the platform databases path
  /// hosts `slatesync.db`.
  static Future<LocalDb> open({String? pathOverride}) async {
    final String path;
    if (pathOverride != null) {
      final File file = File(pathOverride);
      await file.parent.create(recursive: true);
      path = file.path;
    } else {
      final String base = await getDatabasesPath();
      path = '$base${Platform.pathSeparator}slatesync.db';
    }
    final Database db = await openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute(_createSql);
      },
    );
    return LocalDb._(db);
  }

  /// Insert or replace a row (`ConflictAlgorithm.replace`, Doc 26 §5.1).
  Future<void> insertCanvas(CanvasRecord r) => _db.insert(
        table,
        r.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Rows matching `title LIKE %query%` (SQLite case-insensitive default),
  /// always ordered `updated_at DESC`. Empty/blank query returns everything.
  Future<List<CanvasRecord>> list({String? query}) async {
    final String q = query?.trim() ?? '';
    final List<Map<String, Object?>> rows = await _db.query(
      table,
      where: q.isEmpty ? null : 'title LIKE ?',
      whereArgs: q.isEmpty ? null : <Object?>['%$q%'],
      orderBy: 'updated_at DESC',
    );
    return rows.map(CanvasRecord.fromMap).toList(growable: false);
  }

  Future<CanvasRecord?> get(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      table,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : CanvasRecord.fromMap(rows.first);
  }

  Future<void> update(CanvasRecord r) => _db.update(
        table,
        r.toMap(),
        where: 'id = ?',
        whereArgs: <Object?>[r.id],
      );

  Future<void> delete(String id) =>
      _db.delete(table, where: 'id = ?', whereArgs: <Object?>[id]);

  /// Thumbnail path stored on the row (Doc 02 §10.6): `null` when the row is
  /// unknown or `thumb_path` is empty (legacy row awaiting gallery backfill).
  Future<String?> thumbPath(String id) async {
    final CanvasRecord? record = await get(id);
    final String path = record?.thumbPath ?? '';
    return path.isEmpty ? null : path;
  }

  /// Patch ONLY `thumb_path` for one row — used by the gallery backfill so a
  /// slow thumbnail job can never clobber a concurrent title/preset write
  /// (row rewrites from rename/upgrade keep racing the other way).
  Future<void> setThumbPath(String id, String thumbPath) => _db.update(
        table,
        <String, Object?>{'thumb_path': thumbPath},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

  Future<void> close() => _db.close();
}

// ---------------------------------------------------------------------------
// `.slatesync` tablet cache (Doc 26 §5.3, template §3 container contract)
// ---------------------------------------------------------------------------

Future<String> _defaultBaseDir() async {
  final Directory docs = await getApplicationDocumentsDirectory();
  return '${docs.path}/SlateSync';
}

/// Resolve `<base>/<id>.slatesync` without touching disk. `baseDir` defaults
/// to `path_provider` app-documents/SlateSync (test-injectable, Doc 26 §4).
Future<String> slatesyncFilePath(String id, {String? baseDir}) async {
  final String dir = baseDir ?? await _defaultBaseDir();
  return '$dir/$id.slatesync';
}

/// Resolve the canonical thumbnail path `<base>/thumbs/<id>.png`
/// (Doc 02 §10.6) without touching disk. `baseDir` defaults to
/// `path_provider` app-documents/SlateSync (test-injectable).
Future<String> thumbFilePath(String id, {String? baseDir}) async {
  final String dir = baseDir ?? await _defaultBaseDir();
  return '$dir/thumbs/$id.png';
}

/// Generate (or refresh) the Doc 02 §10.6 thumbnail PNG for [doc] at the
/// canonical `<base>/thumbs/<canvas_id>.png` and return the path written.
/// [generator] defaults to the frozen `saveDocThumbnail`; tests inject a
/// fake through this seam for deterministic call counts.
Future<String> ensureThumbnail(
  CanvasDocumentModel doc, {
  String? baseDir,
  ThumbGenerator? generator,
}) async {
  final String dirPath = baseDir ?? await _defaultBaseDir();
  final String outPath = await thumbFilePath(
    doc.canvasId,
    baseDir: dirPath,
  );
  final ThumbGenerator gen = generator ?? saveDocThumbnail;
  return gen(doc, outPath);
}

String _assetFileName(String assetRef) {
  final String name = assetRef.split('/').last;
  if (name.isEmpty || name == '.' || name == '..') {
    throw ArgumentError.value(assetRef, 'assetRef', 'Unsafe asset path');
  }
  return name;
}

/// Directory holding extracted asset bytes for one canvas:
/// `<base>/assets/<canvasId>/` (Doc 10 `assets_dir` mirror, basename-only,
/// zip-slip-safe).
String _assetDir(String baseDir, String canvasId) =>
    '$baseDir/assets/$canvasId';

/// Round-8 issue 05 — absolute path of one extracted `asset_ref` for a canvas.
///
/// `loadDocument` unpacks the archive's `assets/*` entries into
/// [canvasAssetDir], but nothing told the renderer where they were, so a
/// reopened canvas painted its images as blank boxes. Callers use this to read
/// the bytes back into `AssetImageCache`. [baseDir] defaults to
/// `path_provider` app-documents/SlateSync (test-injectable).
Future<String> canvasAssetPath(
  String canvasId,
  String assetRef, {
  String? baseDir,
}) async {
  final String dir = baseDir ?? await _defaultBaseDir();
  return '${_assetDir(dir, canvasId)}/${_assetFileName(assetRef)}';
}

/// Serialize [doc] into `<base>/<canvasId>.slatesync` — a real ZIP with
/// `document.json` at the root plus `assets/*` entries (template §3).
///
/// Asset bytes come from [assets] (keyed by `geometry.asset_ref`, e.g.
/// `"assets/img.png"`) when given, otherwise from the per-canvas extracted
/// directory populated by [loadDocument]. Refs whose bytes are unavailable
/// are skipped so autosave can never fail on a missing attachment.
///
/// Doc 02 §10.6: AFTER the archive lands, the save path (re)generates the
/// thumbnail PNG at `<base>/thumbs/<canvas_id>.png` so every
/// create/open/back-save/upgrade/rename refreshes it — unless [thumbGenerator]
/// overrides the generator (tests). Thumbnail failures are best-effort and
/// never fail the document save itself.
/// Returns the absolute `.slatesync` file path written.
Future<String> saveDocument(
  CanvasDocumentModel doc, {
  String? baseDir,
  Map<String, List<int>>? assets,
  ThumbGenerator? thumbGenerator,
}) async {
  final String dirPath = baseDir ?? await _defaultBaseDir();
  final String filePath = await slatesyncFilePath(
    doc.canvasId,
    baseDir: dirPath,
  );
  await File(filePath).parent.create(recursive: true);

  final Archive archive = Archive();
  final List<int> jsonBytes = utf8.encode(jsonEncode(doc.toJson()));
  archive.add(ArchiveFile('document.json', jsonBytes.length, jsonBytes));

  final Set<String> seen = <String>{};
  for (final CanvasNodeModel element in doc.elements) {
    final String? ref = element.geometry.assetRef;
    if (ref == null || !ref.startsWith('assets/') || !seen.add(ref)) {
      continue;
    }
    List<int>? bytes = assets?[ref];
    bytes ??= await _readExtractedAsset(dirPath, doc.canvasId, ref);
    if (bytes != null) {
      archive.add(ArchiveFile(ref, bytes.length, bytes));
    }
  }

  final Uint8List zipBytes = ZipEncoder().encodeBytes(archive);
  await File(filePath).writeAsBytes(zipBytes, flush: true);

  // Doc 02 §10.6 — save-time thumbnail (best-effort: a rasterization
  // failure must never break document persistence).
  try {
    await ensureThumbnail(
      doc,
      baseDir: dirPath,
      generator: thumbGenerator,
    );
  } catch (_) {
    // Missing engine/headless environment — gallery backfill retries later.
  }
  return filePath;
}

/// Unzip `<base>/<id>.slatesync`, rebuild the document from `document.json`
/// and extract `assets/*` (basename-only) into the per-canvas directory so a
/// later [saveDocument] re-embeds them.
Future<CanvasDocumentModel> loadDocument(String id, {String? baseDir}) async {
  final String dirPath = baseDir ?? await _defaultBaseDir();
  final String filePath = await slatesyncFilePath(id, baseDir: dirPath);
  final List<int> bytes = await File(filePath).readAsBytes();
  final Archive archive = ZipDecoder().decodeBytes(bytes, verify: true);

  ArchiveFile? documentFile;
  for (final ArchiveFile file in archive.files) {
    if (file.name == 'document.json') {
      documentFile = file;
    }
  }
  if (documentFile == null) {
    throw StateError('.slatesync "$id" has no document.json at ZIP root');
  }
  final CanvasDocumentModel doc = CanvasDocumentModel.fromJson(
    jsonDecode(utf8.decode(documentFile.content)) as Map<String, dynamic>,
  );

  for (final ArchiveFile file in archive.files) {
    if (!file.name.startsWith('assets/')) {
      continue;
    }
    final String name = _assetFileName(file.name);
    final File out = File('${_assetDir(dirPath, doc.canvasId)}/$name');
    await out.parent.create(recursive: true);
    await out.writeAsBytes(file.content, flush: true);
  }
  return doc;
}

Future<List<int>?> _readExtractedAsset(
  String baseDir,
  String canvasId,
  String ref,
) async {
  final File file = File(
    '${_assetDir(baseDir, canvasId)}/${_assetFileName(ref)}',
  );
  if (await file.exists()) {
    return file.readAsBytes();
  }
  return null;
}
