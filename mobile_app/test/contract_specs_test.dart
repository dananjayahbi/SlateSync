/// Round-6 cross-artifact contract test (TEST 1) — machine-verifies that the
/// Dart wire mirrors agree with the JSON ground truth in `shared_specs/`:
///
///  * `FrameType` / `ToolId` Dart byte consts == the enums in
///    `binary_stream_frame.json` (both directions, 0x01–0x04 ×2).
///  * `WireCodec.buildFrame` byte layout == the JSON offsets table (every
///    field row's offset/size/c_type asserted against the packed bytes).
///  * `type`/`action` strings emitted by the `hub_sync` envelope builders and
///    by every known sender literal in `lib/` ⊆ the `ws_rpc_schema.json`
///    enums; the action enum size is checked dynamically (no hardcoded JSON
///    count) against the normative 24-name list.
///  * `type_actions` self-consistency from the Dart side: every action listed
///    under a type is in the master enum (and every master action is grouped).
///
/// Pure Dart — no widgets, no platform channels. The repo root is found by
/// walking upward from `Directory.current` until `shared_specs/` appears.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/sync/hub_sync.dart';

/// Normative action list (Doc 02 §4.2 + §8.1 + §9.1 + §10.1 + §11.1 — 24
/// actions).
const List<String> _normativeActions = <String>[
  'OPEN_CANVAS',
  'ADD_STROKE',
  'ADD_GRAPH',
  'ADD_SHAPE',
  'ADD_IMAGE',
  'DELETE_NODE',
  'UPGRADE_SIZE',
  'START_EXPORT',
  'CANCEL_EXPORT',
  'EXPORT_PROGRESS',
  'EXPORT_FINISHED',
  'ASSET_START',
  'ASSET_CHUNK',
  'ASSET_DONE',
  'CANVAS_LIST_REQUEST',
  'CANVAS_LIST',
  'CANVAS_OPEN_REQUEST',
  'CANVAS_PUT',
  'CANVAS_PULL',
  'CLEAR_CANVAS',
  'START_OCR',
  'CANCEL_OCR',
  'OCR_PROGRESS',
  'OCR_RESULT',
];

/// Known Dart sender literals (hub_sync builders, bridge, studio page, export
/// sheet) — every one must live in the schema's action enum.
const List<String> _knownSenderActions = <String>[
  'CANVAS_LIST',
  'CANVAS_PUT',
  'CANVAS_PULL',
  'OPEN_CANVAS',
  'CLEAR_CANVAS',
  'ADD_STROKE',
  'ADD_GRAPH',
  'ADD_SHAPE',
  'ADD_IMAGE',
  'DELETE_NODE',
  'EXPORT_PROGRESS',
  'EXPORT_FINISHED',
  'ASSET_START',
  'ASSET_CHUNK',
  'ASSET_DONE',
  'UPGRADE_SIZE',
  'START_EXPORT',
  'CANCEL_EXPORT',
];

/// Robust upward search: `Directory.current` (mobile_app during
/// `flutter test`) → parents until a `shared_specs/` directory exists.
Directory _findRepoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 12; i++) {
    final String sep = Platform.pathSeparator;
    if (Directory('${dir.path}$sep$sharedSpecsDirName').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'shared_specs/ not found above ${Directory.current.path} — '
    'cannot locate the spec ground truth',
  );
}

const String sharedSpecsDirName = 'shared_specs';

final Directory _root = _findRepoRoot();

Map<String, dynamic> _loadSpec(String fileName) {
  final File file = File(
    '${_root.path}${Platform.pathSeparator}'
    '$sharedSpecsDirName${Platform.pathSeparator}$fileName',
  );
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

int _hexByte(String key) => int.parse(key.replaceFirst('0x', ''), radix: 16);

void main() {
  final Map<String, dynamic> frameSpec = _loadSpec('binary_stream_frame.json');
  final Map<String, dynamic> rpcSpec = _loadSpec('ws_rpc_schema.json');
  final List<String> typeEnum =
      (rpcSpec['envelope']['type']['enum'] as List).cast<String>();
  final List<String> actionEnum =
      (rpcSpec['envelope']['action']['enum'] as List).cast<String>();
  final Map<String, dynamic> typeActions =
      Map<String, dynamic>.from(rpcSpec['type_actions'] as Map);

  group('TEST 1.1 binary_stream_frame.json ⇄ FrameType/ToolId', () {
    test('FrameType consts equal the JSON frame_type byte values', () {
      final Map<String, dynamic> raw =
          Map<String, dynamic>.from(frameSpec['frame_type'] as Map);
      final Map<String, int> byName = <String, int>{
        for (final MapEntry<String, dynamic> e in raw.entries)
          (e.value as Map)['name'] as String: _hexByte(e.key),
      };
      expect(byName.keys.toSet(),
          equals(<String>{'LIVE_POINT', 'LIVE_END', 'CAMERA', 'LASER'}));
      expect(byName['LIVE_POINT'], FrameType.livePoint);
      expect(byName['LIVE_END'], FrameType.liveEnd);
      expect(byName['CAMERA'], FrameType.camera);
      expect(byName['LASER'], FrameType.laser);
      // Both directions: the Dart const values cover exactly the JSON values.
      expect(
        byName.values.toSet(),
        equals(<int>{
          FrameType.livePoint,
          FrameType.liveEnd,
          FrameType.camera,
          FrameType.laser,
        }),
      );
    });

    test('ToolId consts equal the JSON tool_id byte values', () {
      final Map<String, dynamic> raw =
          Map<String, dynamic>.from(frameSpec['tool_id'] as Map);
      final Map<int, String> specByByte = <int, String>{
        for (final MapEntry<String, dynamic> e in raw.entries)
          _hexByte(e.key): e.value as String,
      };
      expect(
        specByByte,
        equals(<int, String>{
          ToolId.pen: 'Pen',
          ToolId.highlighter: 'Highlighter',
          ToolId.eraser: 'Eraser',
          ToolId.shapePreview: 'Line/Shape Preview',
        }),
      );
      expect(
        specByByte.keys.toSet(),
        equals(<int>{
          ToolId.pen,
          ToolId.highlighter,
          ToolId.eraser,
          ToolId.shapePreview,
        }),
      );
    });
  });

  group('TEST 1.2 binary_stream_frame.json offsets table ⇄ WireCodec', () {
    test('buildFrame packs every spec row at its declared offset/size', () {
      const int frameType = 0x01;
      const int toolId = 0x03;
      const int seq = 0xBEEF;
      const double f1 = 1.5;
      const double f2 = -2.25;
      const double f3 = 3.75;
      final ByteData packed = WireCodec.buildFrame(
        frameType: frameType,
        toolId: toolId,
        seq: seq,
        f1: f1,
        f2: f2,
        f3: f3,
      );

      final int byteLength = frameSpec['byte_length'] as int;
      expect(frameSpec['byte_order'], 'little_endian');
      expect(packed.lengthInBytes, byteLength);
      expect(WireCodec.frameSize, byteLength);

      final Map<String, num> expected = <String, num>{
        'frame_type': frameType,
        'tool_id': toolId,
        'seq': seq,
        'f1': f1,
        'f2': f2,
        'f3': f3,
      };
      final List<dynamic> rows = frameSpec['fields'] as List<dynamic>;
      expect(rows, isNotEmpty);
      int cursor = 0;
      for (final dynamic rowRaw in rows) {
        final Map<String, dynamic> row =
            Map<String, dynamic>.from(rowRaw as Map);
        final String name = row['name'] as String;
        final int offset = row['offset'] as int;
        final int size = row['size'] as int;
        final String cType = row['c_type'] as String;

        // The table must tile the frame exactly: contiguous, no gaps/overlaps.
        expect(offset, cursor,
            reason: 'field "$name" offset must follow the previous row');
        expect(offset + size, lessThanOrEqualTo(byteLength));
        cursor = offset + size;

        num actual;
        switch (cType) {
          case 'uint8':
            expect(size, 1, reason: 'uint8 "$name" size');
            actual = packed.getUint8(offset);
          case 'uint16':
            expect(size, 2, reason: 'uint16 "$name" size');
            actual = packed.getUint16(offset, Endian.little);
          case 'float32':
            expect(size, 4, reason: 'float32 "$name" size');
            actual = packed.getFloat32(offset, Endian.little);
          default:
            fail('spec declares unknown c_type "$cType" for "$name"');
        }
        expect(actual, expected[name],
            reason:
                'field "$name" @offset $offset size $size ($cType) bytes');
      }
      expect(cursor, byteLength,
          reason: 'spec rows must cover the whole frame');
    });

    test('struct_format in the spec matches the row offsets/sizes', () {
      final String fmt = frameSpec['struct_format'] as String;
      expect(fmt, '<BBHfff');
      expect(fmt.startsWith('<'), isTrue,
          reason: 'spec declares little_endian');
      const Map<String, int> cSize = <String, int>{'B': 1, 'H': 2, 'f': 4};
      const Map<String, String> cTypeToStruct = <String, String>{
        'uint8': 'B',
        'uint16': 'H',
        'float32': 'f',
      };
      final List<dynamic> rows = frameSpec['fields'] as List<dynamic>;
      expect(fmt.length - 1, rows.length,
          reason: 'one struct char per field row');
      int cursor = 0;
      for (int i = 1; i < fmt.length; i++) {
        final Map<String, dynamic> row =
            Map<String, dynamic>.from(rows[i - 1] as Map);
        final int size = cSize[fmt[i]]!;
        expect(row['offset'], cursor);
        expect(row['size'], size);
        expect(cTypeToStruct[row['c_type']], fmt[i],
            reason: 'c_type "${row['c_type']}" must match struct char '
                '"${fmt[i]}"');
        cursor += size;
      }
      expect(cursor, frameSpec['byte_length']);
    });
  });

  group('TEST 1.3 ws_rpc_schema.json ⇄ hub_sync envelope builders', () {
    final CanvasDocumentModel doc = CanvasDocumentModel(
      canvasId: 'cv-contract',
      title: 'Contract',
      createdAt: 1760760000,
      updatedAt: 1760763600,
      artboard: Artboard.infinite(),
      contentBounds: <String, double>{
        'min_x': 0.0,
        'min_y': 0.0,
        'max_x': 0.0,
        'max_y': 0.0,
      },
      elements: <CanvasNodeModel>[],
    );

    void checkEnvelope(Map<String, dynamic> envelope, String label) {
      final String type = envelope['type'] as String;
      final String action = envelope['action'] as String;
      expect(typeEnum, contains(type), reason: '$label type not in enum');
      expect(actionEnum, contains(action),
          reason: '$label action not in enum');
      final List<String> allowed =
          (typeActions[type] as List).cast<String>();
      expect(allowed, contains(action),
          reason: '$label action "$action" not paired with type "$type" '
              'in type_actions');
    }

    test('canvasListEnvelope/Put/Pull emit schema-valid type+action', () {
      checkEnvelope(
        canvasListEnvelope(
          deviceId: 'dev-1',
          deviceName: 'Tablet',
          origin: 'device',
          canvases: <Map<String, dynamic>>[],
        ),
        'canvasListEnvelope',
      );
      checkEnvelope(canvasPutEnvelope(doc, source: 'device'), 'PutEnvelope');
      checkEnvelope(canvasPullEnvelope(doc.canvasId, doc.updatedAt),
          'PullEnvelope');
    });
  });

  group('TEST 1.4 known sender literals ⇄ ws_rpc_schema enums', () {
    test('every known sender action literal is in the action enum', () {
      expect(actionEnum.toSet(), containsAll(_knownSenderActions));
      expect(actionEnum.toSet(), containsAll(_normativeActions));
    });

    test('literal scan of lib/ finds only schema-valid type/action strings',
        () {
      final Directory lib = Directory(
        '${_root.path}${Platform.pathSeparator}mobile_app'
        '${Platform.pathSeparator}lib',
      );
      expect(lib.existsSync(), isTrue);

      // 'action': 'X' at envelope construction sites.
      final RegExp actionEntry =
          RegExp(r"""['"]action['"]\s*:\s*['"]([A-Z][A-Z0-9_]*)['"]""");
      // _commitEnvelope('X', …) / _commitElement(…, 'X') wrappers.
      final RegExp commitLiteral =
          RegExp(r"""_commit(?:Envelope|Element)?\(\s*['"]([A-Z][A-Z0-9_]*)['"]""");
      // 'type': 'X' at envelope construction sites.
      final RegExp typeEntry =
          RegExp(r"""['"]type['"]\s*:\s*['"]([A-Z][A-Z0-9_]*)['"]""");
      // Any wire-keyword literal (actions AND types) in sender code paths —
      // catches e.g. the 'ADD_SHAPE'/'ADD_GRAPH'/'ADD_IMAGE' literals passed
      // as _commitElement arguments.
      final RegExp wireKeyword = RegExp(
        r"""['"]((?:OPEN|ADD|DELETE|UPGRADE|START|CANCEL|EXPORT|ASSET|"""
        r"""CANVAS|CLEAR)_[A-Z0-9_]+)['"]""",
      );

      final Set<String> actionLiterals = <String>{};
      final Set<String> typeLiterals = <String>{};
      final Set<String> wireKeywords = <String>{};
      int scanned = 0;
      for (final FileSystemEntity entity
          in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        scanned++;
        final String source = entity.readAsStringSync();
        actionLiterals
          ..addAll(actionEntry.allMatches(source).map((m) => m.group(1)!))
          ..addAll(commitLiteral.allMatches(source).map((m) => m.group(1)!));
        typeLiterals.addAll(typeEntry.allMatches(source).map((m) => m.group(1)!));
        wireKeywords.addAll(wireKeyword.allMatches(source).map((m) => m.group(1)!));
      }

      expect(scanned, greaterThan(0), reason: 'lib/*.dart scan found files');
      expect(actionLiterals, isNotEmpty,
          reason: 'expected sender action literals in lib/');
      expect(typeLiterals, isNotEmpty,
          reason: 'expected sender type literals in lib/');
      expect(actionLiterals.difference(actionEnum.toSet()), isEmpty,
          reason: 'action literals outside the schema enum');
      expect(typeLiterals.difference(typeEnum.toSet()), isEmpty,
          reason: 'type literals outside the schema enum');
      final Set<String> wireUniverse =
          actionEnum.toSet()..addAll(typeEnum);
      expect(wireKeywords.difference(wireUniverse), isEmpty,
          reason: 'wire-keyword literals outside both schema enums');
    });
  });

  group('TEST 1.5 ws_rpc_schema.json self-consistency (Dart side)', () {
    test('action enum size == normative list, loaded dynamically', () {
      // No hardcoded JSON count: equality with the named normative list
      // proves both "exact size" and "includes all 24".
      expect(actionEnum.toSet(), equals(_normativeActions.toSet()));
      expect(actionEnum.toSet().length, _normativeActions.length);
      expect(actionEnum.length, actionEnum.toSet().length,
          reason: 'enum must not contain duplicates');
      // Dynamic cross-check: the union of type_actions groups has exactly
      // the enum's size (every grouped action is a master action, too).
      final Set<String> grouped = <String>{
        for (final dynamic group in typeActions.values)
          ...(group as List).cast<String>(),
      };
      expect(grouped.length, actionEnum.length);
      expect(grouped.difference(actionEnum.toSet()), isEmpty);
      expect(actionEnum.toSet().difference(grouped), isEmpty);
    });

    test('type enum and type_actions keys agree', () {
      expect(typeEnum.toSet(), equals(<String>{
        'CANVAS_LIFECYCLE',
        'ELEMENT_COMMIT',
        'ARTBOARD_RESIZE',
        'ASSET_UPLOAD',
        'EXPORT_JOB',
        'OCR_JOB',
      }));
      expect(typeActions.keys.toSet(), containsAll(typeEnum),
          reason: 'every schema type must have a type_actions group');
    });

    test('every action listed under a type is in the master action enum', () {
      final Set<String> master = actionEnum.toSet();
      for (final MapEntry<String, dynamic> e in typeActions.entries) {
        final Set<String> actions = (e.value as List).cast<String>().toSet();
        expect(actions, isNotEmpty, reason: 'group "${e.key}" is empty');
        expect(actions.difference(master), isEmpty,
            reason: 'group "${e.key}" lists actions missing from '
                'envelope.action.enum');
      }
    });
  });
}
