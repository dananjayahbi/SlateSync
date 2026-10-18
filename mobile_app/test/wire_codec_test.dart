import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Doc 05 §6: 16-byte `<BBHfff` little-endian wire codec — golden byte table,
/// pack→unpack identity, strict length validation.
void main() {
  group('constants', () {
    test('FrameType and ToolId match template §3', () {
      expect(FrameType.livePoint, 0x01);
      expect(FrameType.liveEnd, 0x02);
      expect(FrameType.camera, 0x03);
      expect(FrameType.laser, 0x04);
      expect(ToolId.pen, 0x01);
      expect(ToolId.highlighter, 0x02);
      expect(ToolId.eraser, 0x03);
      expect(ToolId.shapePreview, 0x04);
    });
  });

  group('buildFrame', () {
    test('produces exactly 16 bytes', () {
      final frame = WireCodec.buildFrame(
        frameType: FrameType.livePoint,
        toolId: ToolId.pen,
        seq: 1,
        f1: 0.5,
      );
      expect(frame.lengthInBytes, 16);
      expect(WireCodec.frameSize, 16);
    });

    test('golden byte table for offsets 0..15', () {
      // frameType=0x01, toolId=0x02, seq=0x0304, f1=1.0, f2=-2.0, f3=0.5
      final frame = WireCodec.buildFrame(
        frameType: 0x01,
        toolId: 0x02,
        seq: 0x0304,
        f1: 1.0,
        f2: -2.0,
        f3: 0.5,
      );
      final bytes = frame.buffer.asUint8List();

      expect(bytes, hasLength(16));
      // offset 0: frameType (u8)
      expect(bytes[0], 0x01);
      // offset 1: toolId (u8)
      expect(bytes[1], 0x02);
      // offsets 2..3: seq 0x0304 little-endian => 04 03
      expect(bytes[2], 0x04);
      expect(bytes[3], 0x03);
      // offsets 4..7: f1 = 1.0f LE => 00 00 80 3F
      expect(bytes.sublist(4, 8), <int>[0x00, 0x00, 0x80, 0x3F]);
      // offsets 8..11: f2 = -2.0f LE => 00 00 00 C0
      expect(bytes.sublist(8, 12), <int>[0x00, 0x00, 0x00, 0xC0]);
      // offsets 12..15: f3 = 0.5f LE => 00 00 00 3F
      expect(bytes.sublist(12, 16), <int>[0x00, 0x00, 0x00, 0x3F]);

      // Every offset 0..15 accounted for with exact expected values.
      expect(
        bytes,
        <int>[0x01, 0x02, 0x04, 0x03, 0x00, 0x00, 0x80, 0x3F, 0x00, 0x00,
              0x00, 0xC0, 0x00, 0x00, 0x00, 0x3F],
      );
    });

    test('seq is little-endian u16 (0x0001 => 01 00)', () {
      final bytes = WireCodec.buildFrame(
        frameType: FrameType.camera,
        toolId: ToolId.pen,
        seq: 1,
        f1: 1.0,
      ).buffer.asUint8List();
      expect(bytes[2], 0x01);
      expect(bytes[3], 0x00);
    });

    test('f2 and f3 default to 0.0', () {
      final frame = WireCodec.buildFrame(
        frameType: FrameType.liveEnd,
        toolId: ToolId.pen,
        seq: 7,
        f1: 3.0,
      );
      final decoded = WireCodec.decodeFrame(
        frame.buffer.asUint8List(),
      );
      expect(decoded.f2, 0.0);
      expect(decoded.f3, 0.0);
    });

    test('big-endian encoding would differ (endianness guard)', () {
      final le = WireCodec.buildFrame(
        frameType: FrameType.livePoint,
        toolId: ToolId.pen,
        seq: 0x0201,
        f1: 1.0,
      );
      final be = ByteData(16)
        ..setUint8(0, FrameType.livePoint)
        ..setUint8(1, ToolId.pen)
        ..setUint16(2, 0x0201, Endian.big)
        ..setFloat32(4, 1.0, Endian.big);
      expect(
        le.buffer.asUint8List(0, 8),
        isNot(equals(be.buffer.asUint8List(0, 8))),
      );
      // seq LE 01 02 vs BE 02 01
      expect(le.getUint16(2, Endian.little), 0x0201);
    });
  });

  group('decodeFrame', () {
    test('pack → unpack identity for varied frames', () {
      final cases = <LiveFrame>[
        const LiveFrame(
          frameType: FrameType.livePoint,
          toolId: ToolId.pen,
          seq: 0,
          f1: 0.0,
          f2: 0.0,
          f3: 0.0,
        ),
        const LiveFrame(
          frameType: FrameType.liveEnd,
          toolId: ToolId.eraser,
          seq: 0xFFFF,
          f1: -1234.5,
          f2: -0.001,
          f3: -0.0,
        ),
        const LiveFrame(
          frameType: FrameType.camera,
          toolId: ToolId.highlighter,
          seq: 32768,
          f1: 0.05,
          f2: -1920.25,
          f3: 1080.75,
        ),
        const LiveFrame(
          frameType: FrameType.laser,
          toolId: ToolId.shapePreview,
          seq: 65535,
          f1: 640.5,
          f2: 480.25,
          f3: 0.0,
        ),
      ];

      for (final original in cases) {
        final packed = WireCodec.buildFrame(
          frameType: original.frameType,
          toolId: original.toolId,
          seq: original.seq,
          f1: original.f1,
          f2: original.f2,
          f3: original.f3,
        );
        expect(packed.lengthInBytes, 16);

        final decoded =
            WireCodec.decodeFrame(packed.buffer.asUint8List());
        expect(decoded.frameType, original.frameType);
        expect(decoded.toolId, original.toolId);
        expect(decoded.seq, original.seq);
        // float32 precision: compare against the same float32 rounding.
        expect(
          decoded.f1,
          closeTo(
            packed.getFloat32(4, Endian.little),
            1e-12,
          ),
        );
        expect(decoded.f2, closeTo(original.f2, 1e-6));
        expect(decoded.f3, closeTo(original.f3, 1e-6));
      }
    });

    test('rejects input whose length != 16', () {
      expect(
        () => WireCodec.decodeFrame(Uint8List(15)),
        throwsArgumentError,
      );
      expect(
        () => WireCodec.decodeFrame(Uint8List(17)),
        throwsArgumentError,
      );
      expect(
        () => WireCodec.decodeFrame(Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('decode reads golden bytes back at exact offsets', () {
      final bytes = Uint8List.fromList(<int>[
        0x03, 0x04, 0xFF, 0xFF, // frameType camera, toolId shapePreview, seq 0xFFFF
        0x00, 0x00, 0x80, 0x3F, // f1 = 1.0
        0x00, 0x00, 0x00, 0xC0, // f2 = -2.0
        0x00, 0x00, 0x00, 0x3F, // f3 = 0.5
      ]);
      final frame = WireCodec.decodeFrame(bytes);
      expect(frame.frameType, 0x03);
      expect(frame.toolId, 0x04);
      expect(frame.seq, 0xFFFF);
      expect(frame.f1, 1.0);
      expect(frame.f2, -2.0);
      expect(frame.f3, 0.5);
    });
  });
}
