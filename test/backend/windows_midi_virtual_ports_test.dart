// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';
import 'dart:math';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/backend/windows_midi_requests.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_byte_reader.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_shim_decoder.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_status.dart';
import 'package:test/test.dart';

void main() {
  late WindowsMidiFakeShim shim;
  late WindowsMidiRequests requests;
  late WindowsMidiVirtualPorts virtualPorts;
  late Map<MidiPortId, int> own;
  late List<(MidiPortInfo, int, String)> created;
  late List<MidiPortId> removed;

  void drain() {
    shim.rearm();
    const decoder = WindowsMidiShimDecoder();
    for (final event in decoder.decodeEvents(shim.readEvents())) {
      if (event is WindowsMidiShimCompletion) requests.complete(event);
    }
  }

  WindowsMidiVirtualPorts make({
    Duration timeout = const Duration(seconds: 5),
  }) => WindowsMidiVirtualPorts(
    shim: shim,
    requests: requests,
    onCreated: (port, handle, instance) {
      own[port.id] = handle;
      created.add((port, handle, instance));
    },
    handleOf: (port) => own[port],
    onRemoved: (port) {
      own.remove(port);
      removed.add(port);
    },
    timeout: timeout,
    random: Random(1),
  );

  setUp(() {
    shim = WindowsMidiFakeShim(
      features: AMW_FEATURE_MIDI2 | AMW_FEATURE_VIRTUAL_DEVICES,
    );
    requests = WindowsMidiRequests();
    own = {};
    created = [];
    removed = [];
    virtualPorts = make();
    shim.create(onSignal: drain);
  });

  final spec = MidiVirtualPortSpec(
    name: 'aud_midi Out',
    direction: MidiDirection.output,
    protocol: MidiProtocol.midi2,
    uniqueId: 42,
    groups: const [0],
    manufacturer: 'Audanika',
  );

  group('WindowsMidiVirtualPorts', () {
    group('encode(spec, productInstanceId)', () {
      test('matches the specification the native shim parses', () {
        final golden = File(
          'test/goldens/virtual_device_spec.hex',
        ).readAsLinesSync().where((line) => !line.startsWith('#')).single;
        final encoded = WindowsMidiVirtualPorts.encode(
          spec,
          productInstanceId: 'aud_midi-42',
        );
        expect(
          [
            for (final byte in encoded) byte.toRadixString(16).padLeft(2, '0'),
          ].join(),
          golden,
        );
      });

      test('fills in defaults and spans the groups of the spec', () {
        final reader = WindowsMidiByteReader(
          WindowsMidiVirtualPorts.encode(
            MidiVirtualPortSpec(
              name: 'In',
              direction: MidiDirection.input,
              groups: const [5, 3],
            ),
            productInstanceId: 'p',
          ),
        );
        expect(
          [
            reader.string(),
            reader.string(),
            reader.string(),
            reader.string(),
            reader.u32(),
            reader.u8(),
            reader.u8(),
            reader.u8(),
          ],
          equals([
            'In',
            'A virtual port of aud_midi',
            'aud_midi',
            'p',
            AMW_VIRTUAL_RECEIVE,
            3,
            3,
            1,
          ]),
        );
        final custom = WindowsMidiByteReader(
          WindowsMidiVirtualPorts.encode(
            MidiVirtualPortSpec(
              name: 'Out',
              direction: MidiDirection.output,
              model: 'Model',
            ),
            productInstanceId: 'p',
          ),
        );
        custom.string();
        expect(custom.string(), 'Model');
        custom
          ..string()
          ..string();
        expect([custom.u32(), custom.u8(), custom.u8()], equals([0, 0, 1]));
      });
    });

    group('create(spec)', () {
      test('creates an own UMP port on a new virtual device', () async {
        final port = await virtualPorts.create(spec);
        expect(
          port,
          MidiPortInfo(
            id: const MidiPortId('winrt:vout:fake-virtual-1'),
            deviceId: const MidiDeviceId('winrt:ump:fake-virtual-1'),
            name: 'aud_midi Out',
            manufacturer: 'Audanika',
            direction: MidiDirection.output,
            transport: MidiTransport.virtual,
            protocol: MidiProtocol.midi2,
            isVirtual: true,
            isOwn: true,
            groups: const [MidiGroupInfo(group: 0, name: 'aud_midi Out')],
            capabilities: const MidiPortCapabilities(
              scheduledSend: true,
              ump: true,
            ),
          ),
        );
        expect(
          port.native,
          equals({
            'deviceName': 'aud_midi Out',
            'product': 'aud_midi Out',
            'driver': 'midi2',
            'windowsId': 'fake-virtual-1',
            'productInstanceId': 'aud_midi-42',
          }),
        );
        expect(created.single.$2, 1);
        expect(created.single.$3, 'aud_midi-42');
      });

      test('creates an input with a random product instance id', () async {
        final port = await virtualPorts.create(
          MidiVirtualPortSpec(
            name: 'In',
            direction: MidiDirection.input,
            model: 'Model',
          ),
        );
        expect(port.id, const MidiPortId('winrt:vin:fake-virtual-1'));
        expect(port.native['product'], 'Model');
        expect(
          port.capabilities,
          const MidiPortCapabilities(timestampsIn: true, ump: true),
        );
        expect(created.single.$3, matches(RegExp(r'^aud_midi-[0-9a-f]+$')));
      });

      test('maps failures to exceptions', () async {
        shim.virtualStatus = AMW_E_UNSUPPORTED;
        await expectLater(
          virtualPorts.create(spec),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'virtual ports',
            ),
          ),
        );
        shim.virtualStatus = AMW_E_PORT_UNAVAILABLE;
        await expectLater(
          virtualPorts.create(spec),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              AMW_E_PORT_UNAVAILABLE,
            ),
          ),
        );
        expect(created, isEmpty);
      });

      test('fails after the timeout and closes a late device', () async {
        shim.autoComplete = false;
        virtualPorts = make(timeout: const Duration(milliseconds: 10));
        await expectLater(
          virtualPorts.create(spec),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              WindowsMidiStatus.timeout,
            ),
          ),
        );
        shim.completeVirtual(shim.pendingVirtual.single);
        await Future<void>.delayed(Duration.zero);
        expect(shim.calls, contains('closePort(1)'));
        expect(shim.openPorts, isEmpty);
      });

      test('ignores late failures and failing closes', () async {
        shim.autoComplete = false;
        virtualPorts = make(timeout: const Duration(milliseconds: 10));
        for (final status in [AMW_E_UNSUPPORTED, AMW_OK]) {
          await expectLater(
            virtualPorts.create(spec),
            throwsA(isA<MidiNativeError>()),
          );
          shim
            ..virtualStatus = status
            ..failures['closePort'] = AMW_E_UNKNOWN_HANDLE
            ..completeVirtual(shim.pendingVirtual.single);
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          shim.calls.where((call) => call == 'closePort(1)'),
          hasLength(1),
        );
      });
    });

    group('remove(port)', () {
      test('removes an own port', () async {
        final port = await virtualPorts.create(spec);
        await virtualPorts.remove(port.id);
        expect(removed, equals([port.id]));
        expect(shim.openPorts, isEmpty);
      });

      test('throws for other ports', () async {
        await expectLater(
          virtualPorts.remove(const MidiPortId('winrt:vout:x')),
          throwsA(isA<MidiPortGone>()),
        );
      });
    });

    group('timeout', () {
      test('defaults to ten seconds', () {
        expect(
          WindowsMidiVirtualPorts(
            shim: shim,
            requests: requests,
            onCreated: (_, _, _) {},
            handleOf: (_) => null,
            onRemoved: (_) {},
          ).timeout,
          const Duration(seconds: 10),
        );
      });
    });
  });
}
