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

import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05

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

/// Serialize [doc] into `<base>/<canvasId>.slatesync` — a real ZIP with
/// `document.json` at the root plus `assets/*` entries (template §3).
///
/// Asset bytes come from [assets] (keyed by `geometry.asset_ref`, e.g.
/// `"assets/img.png"`) when given, otherwise from the per-canvas extracted
/// directory populated by [loadDocument]. Refs whose bytes are unavailable
/// are skipped so autosave can never fail on a missing attachment.
/// Returns the absolute file path written.
Future<String> saveDocument(
  CanvasDocumentModel doc, {
  String? baseDir,
  Map<String, List<int>>? assets,
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
