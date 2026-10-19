/// Doc 02 §8.5 round-4 direction contract for the Doc 25 client:
///
///  * SEND side — the three new actions (`CANVAS_LIST_REQUEST`,
///    `CANVAS_LIST`, `CANVAS_OPEN_REQUEST`) plus the re-dialected
///    `OPEN_CANVAS {canvas}` pass `sendRpc` validation and hit the wire
///    unchanged. The client validates envelope FIELD PRESENCE only
///    (`type/action/canvas_id/payload`) — it has no outgoing action
///    allow-list, so nothing had to be added for round 4.
///  * RECEIVE side — messages are surfaced on `events` for ANY action,
///    including the three round-4 actions and unknown future ones;
///    nothing incoming is ever rejected (§8.5 tolerance).
///
/// All I/O runs through an injected fake [SyncChannel] — no real sockets.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _Channel implements SyncChannel {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<Object?> sent = <Object?>[];
  final Completer<void> readyCompleter = Completer<void>();

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  void add(Object? data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_controller.isClosed) await _controller.close();
  }

  void serverText(String text) {
    if (!_controller.isClosed) _controller.add(text);
  }
}

const PairingInfo _pairing = PairingInfo(
  ipv4: '192.168.1.42',
  port: 50606,
  token: 'round4',
);

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String description = 'condition',
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      throw StateError('timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Connected client over the fake channel (connector completes `ready` on
/// the next microtask, mirroring the handshake).
Future<(VectorSyncClient, _Channel)> connectClient() async {
  final _Channel channel = _Channel();
  final VectorSyncClient client = VectorSyncClient(
    connector: (Uri url) {
      scheduleMicrotask(() {
        if (!channel.readyCompleter.isCompleted) channel.readyCompleter.complete();
      });
      return channel;
    },
  );
  await client.connect(_pairing);
  await waitFor(() => client.isConnected, description: 'client online');
  return (client, channel);
}

void main() {
  group('send direction — round-4 actions pass sendRpc validation', () {
    test('CANVAS_LIST_REQUEST / CANVAS_LIST / CANVAS_OPEN_REQUEST / '
        'OPEN_CANVAS {canvas} reach the wire', () async {
      final (VectorSyncClient client, _Channel channel) = await connectClient();
      addTearDown(client.dispose);

      final List<Map<String, dynamic>> envelopes = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'CANVAS_LIST_REQUEST',
          'canvas_id': '',
          'payload': <String, dynamic>{},
        },
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'CANVAS_LIST',
          'canvas_id': '',
          'payload': <String, dynamic>{
            'canvases': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'c-1',
                'title': 'Control Systems 04',
                'preset': 'A4',
                'background': 'RULED',
                'updated_at': 1760763600,
              },
            ],
          },
        },
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'CANVAS_OPEN_REQUEST',
          'canvas_id': '',
          'payload': <String, dynamic>{'canvas_id': 'c-1'},
        },
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'OPEN_CANVAS',
          'canvas_id': 'c-1',
          'payload': <String, dynamic>{
            'canvas': <String, dynamic>{'canvas_id': 'c-1'},
          },
        },
      ];

      for (final Map<String, dynamic> envelope in envelopes) {
        // A stale outgoing allow-list would throw FormatException here.
        await client.sendRpc(envelope);
      }

      expect(channel.sent, hasLength(envelopes.length));
      final List<Object?> decoded = channel.sent
          .map((Object? frame) => jsonDecode(frame! as String))
          .toList(growable: false);
      expect(
        decoded.map((Object? e) => (e as Map)['action']),
        envelopes.map((Map<String, dynamic> e) => e['action']),
      );
      // Field-presence validation still intact (no action-scoped checks).
      for (final Map<String, dynamic> envelope in envelopes) {
        final Map<String, dynamic> wire =
            decoded[envelopes.indexOf(envelope)] as Map<String, dynamic>;
        expect(wire['type'], envelope['type']);
        expect(wire['canvas_id'], envelope['canvas_id']);
        expect(wire['payload'], envelope['payload']);
        expect(wire.keys, containsAll(<String>['id', 'timestamp']));
      }
    });

    test('field-presence validation still rejects malformed envelopes',
        () async {
      final (VectorSyncClient client, _Channel channel) = await connectClient();
      addTearDown(client.dispose);

      await expectLater(
        client.sendRpc(<String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'canvas_id': '',
          'payload': <String, dynamic>{},
        }), // no action
        throwsA(isA<FormatException>()),
      );
      expect(channel.sent, isEmpty);
    });
  });

  group('receive direction — unknown actions are never rejected', () {
    test('round-4 + unknown actions surface verbatim on rpcReceived',
        () async {
      final (VectorSyncClient client, _Channel channel) = await connectClient();
      addTearDown(client.dispose);

      final List<String?> received = <String?>[];
      final StreamSubscription<SyncEvent> sub = client.events.listen(
        (SyncEvent e) {
          if (e.kind == SyncEventKind.rpcReceived) {
            received.add(e.msg?['action'] as String?);
          }
        },
      );
      addTearDown(sub.cancel);

      const List<String> actions = <String>[
        'CANVAS_LIST_REQUEST',
        'CANVAS_LIST',
        'CANVAS_OPEN_REQUEST',
        'OPEN_CANVAS',
        'TOTALLY_FUTURE_ACTION', // not in the 17-action set — still passes
      ];
      for (final String action in actions) {
        channel.serverText(
          jsonEncode(<String, dynamic>{
            'id': 'in-${actions.indexOf(action)}',
            'type': 'CANVAS_LIFECYCLE',
            'action': action,
            'canvas_id': '',
            'payload': <String, dynamic>{'x': 1},
            'timestamp': 1760763601,
          }),
        );
      }

      await waitFor(
        () => received.length == actions.length,
        description: 'all incoming actions surfaced',
      );
      expect(received, actions);
      expect(client.state, SyncState.online); // nothing kicked the socket
    });
  });
}
