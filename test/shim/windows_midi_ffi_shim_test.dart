// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Integration tests against the real shim; they need Windows, where
// hook/build.dart builds it. Run them with `dart test` on Windows 10 1607+.
@TestOn('windows')
library;

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_ffi_shim.dart';
import 'package:test/test.dart';

// #############################################################################
/// Records what the backend reports.
final class _Host implements MidiBackendHost {
  @override
  final MidiClock clock = const MidiSystemClock();

  final StreamController<(MidiPortId, MidiPacket)> packets =
      StreamController.broadcast();
  final List<MidiDiagnostic> diagnostics = [];

  @override
  void portsChanged(List<MidiPortEvent> events) {}

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port, packet));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);
}

void main() {
  group('WindowsMidiFfiShim', () {
    test('creates a context with WinRT MIDI 1.0 and a running clock', () {
      final shim = WindowsMidiFfiShim();
      shim.create(onSignal: () {});
      try {
        expect(amw_version(), AMW_VERSION);
        expect(shim.features & AMW_FEATURE_MIDI1, AMW_FEATURE_MIDI1);
        final first = shim.clockNowMicros();
        expect(shim.clockNowMicros(), greaterThanOrEqualTo(first));
        expect(shim.readEvents(), isEmpty);
      } finally {
        shim.destroy();
      }
      shim.destroy();
    });

    test('rejects unknown handles', () {
      final shim = WindowsMidiFfiShim()..create(onSignal: () {});
      try {
        expect(
          () => shim.closePort(12345),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              AMW_E_UNKNOWN_HANDLE,
            ),
          ),
        );
      } finally {
        shim.destroy();
      }
    });
  });

  group('WindowsMidiBackend on Windows', () {
    late WindowsMidiBackend backend;
    late _Host host;

    setUp(() async {
      backend = WindowsMidiBackend(includeDiagnosticLoopback: true);
      host = _Host();
      await backend.start(host);
    });

    tearDown(() async {
      await backend.stop();
      await host.packets.close();
    });

    // Sends [packet] from [output] and waits for it on [input].
    Future<MidiPacket> loop(
      MidiPortInfo output,
      MidiPortInfo input,
      MidiPacket packet,
    ) async {
      await backend.openPort(input.id);
      await backend.openPort(output.id);
      final received = host.packets.stream
          .firstWhere((entry) => entry.$1 == input.id)
          .timeout(const Duration(seconds: 2));
      await backend.send(output.id, packet);
      return (await received).$2;
    }

    test('opens and closes every port', () async {
      final failures = <String>[];
      for (final port in backend.ports) {
        try {
          await backend.openPort(port.id);
          await backend.closePort(port.id);
        } on MidiNativeError catch (error) {
          // Another app may hold a port that Windows opens exclusively.
          if (error.code != AMW_E_PORT_UNAVAILABLE) {
            failures.add('${port.name}: $error');
          }
        }
      }
      expect(failures, isEmpty);
      expect(
        host.diagnostics.where(
          (d) => d.kind != MidiDiagnosticKind.queueOverflow,
        ),
        isEmpty,
      );
    });

    test('loops UMP through the diagnostic loopback endpoints', () async {
      final loopbacks = [
        for (final port in backend.ports)
          if (port.native['purpose'] == 500) port,
      ];
      if (loopbacks.length < 4) {
        markTestSkipped('Windows MIDI Services loopback is not available');
        return;
      }
      // Messages sent to loopback A arrive at loopback B.
      final a = loopbacks.firstWhere(
        (port) => port.isOutput && port.name.endsWith('A'),
      );
      final b = loopbacks.firstWhere(
        (port) => port.isInput && port.name.endsWith('B'),
      );
      final sent = MidiUmpPacket(words: [0x20903C64], time: host.clock.now());
      final received = await loop(a, b, sent);
      expect(received, isA<MidiUmpPacket>());
      expect((received as MidiUmpPacket).words, equals([0x20903C64]));
    });

    test('loops bytes through a loopback driver', () async {
      MidiPortInfo? find(MidiDirection direction) {
        for (final port in backend.ports) {
          final name = port.name.toLowerCase();
          if (port.direction == direction &&
              !port.capabilities.ump &&
              (name.contains('loopmidi') || name.contains('loopback'))) {
            return port;
          }
        }
        return null;
      }

      final output = find(MidiDirection.output);
      final input = find(MidiDirection.input);
      if (output == null || input == null) {
        markTestSkipped('No loopMIDI-style loopback port pair found');
        return;
      }
      final start = host.clock.now();
      final received = await loop(
        output,
        input,
        MidiBytesPacket(bytes: MidiBytes([0x90, 0x3C, 0x64]), time: start),
      );
      expect(
        (received as MidiBytesPacket).bytes,
        MidiBytes([0x90, 0x3C, 0x64]),
      );
      expect(received.time.isBefore(start), isFalse);
    });

    test('plays a note on the Microsoft GS Wavetable Synth', () async {
      final synth = backend.ports.where(
        (port) =>
            port.isOutput && port.name.toLowerCase().contains('gs wavetable'),
      );
      if (synth.isEmpty) {
        markTestSkipped('The Microsoft GS Wavetable Synth is not available');
        return;
      }
      final port = synth.first;
      await backend.openPort(port.id);
      final now = host.clock.now();
      final ump = port.capabilities.ump;
      await backend.send(
        port.id,
        ump
            ? MidiUmpPacket(words: [0x20903C64], time: now)
            : MidiBytesPacket(bytes: MidiBytes([0x90, 0x3C, 0x64]), time: now),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await backend.send(
        port.id,
        ump
            ? MidiUmpPacket(words: [0x20803C00], time: host.clock.now())
            : MidiBytesPacket(
                bytes: MidiBytes([0x80, 0x3C, 0x00]),
                time: host.clock.now(),
              ),
      );
      await backend.closePort(port.id);
    });
  });
}
