// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_data_record.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_shim_decoder.dart';
import 'package:test/test.dart';

void main() {
  const decoder = WindowsMidiShimDecoder();
  const input = WindowsMidiPortRecord(
    source: AMW_SOURCE_MIDI1_IN,
    id: 'in',
    name: 'In',
  );
  const output = WindowsMidiPortRecord(
    source: AMW_SOURCE_MIDI1_OUT,
    id: 'out',
    name: 'Out',
  );
  late WindowsMidiFakeShim shim;
  late int signals;

  List<WindowsMidiShimEvent> events() =>
      decoder.decodeEvents(shim.readEvents());

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  setUp(() {
    shim = WindowsMidiFakeShim(ports: const [input, output], clockMicros: 7);
    signals = 0;
    shim.create(onSignal: () => signals++);
  });

  group('WindowsMidiFakeShim', () {
    group('create(onSignal), destroy()', () {
      test('record the calls and the state', () {
        expect(shim.isCreated, isTrue);
        expect(shim.isDestroyed, isFalse);
        shim.destroy();
        expect(shim.isDestroyed, isTrue);
        expect(shim.calls, equals(['create', 'destroy']));
      });

      test('destroy() closes everything and stops the signals', () async {
        shim
          ..watchStart(AMW_SOURCE_MIDI1_IN)
          ..bleScanStart()
          ..openPort(request: 1, id: 'in', kind: AMW_KIND_MIDI1_IN)
          ..destroy();
        await tick();
        expect(signals, 0);
        expect([
          shim.openPorts,
          shim.watchedSources,
          shim.isScanning,
        ], equals([<int, Object>{}, 0, false]));
      });
    });

    group('features, clockNowMicros()', () {
      test('report the configuration', () {
        expect(shim.features, AMW_FEATURE_MIDI1);
        expect(shim.clockNowMicros(), 7);
        shim
          ..features = 3
          ..clockMicros = 9;
        expect([shim.features, shim.clockNowMicros()], equals([3, 9]));
      });

      test('feature constants match the shim', () {
        expect([
          WindowsMidiFakeShim.featureMidi1,
          WindowsMidiFakeShim.featureMidi2Built,
          WindowsMidiFakeShim.featureMidi2,
          WindowsMidiFakeShim.featureMidi2Hybrid,
          WindowsMidiFakeShim.featureBluetooth,
          WindowsMidiFakeShim.featureVirtualDevices,
        ], equals([1, 2, 4, 8, 16, 32]));
      });
    });

    group('failures', () {
      test('make the next call of a method fail once', () {
        shim.failures['watchStart'] = AMW_E_UNEXPECTED;
        expect(
          () => shim.watchStart(1),
          throwsA(
            isA<MidiNativeError>()
                .having((e) => e.api, 'api', 'fake watchStart')
                .having((e) => e.code, 'code', AMW_E_UNEXPECTED),
          ),
        );
        shim.watchStart(1);
        expect(shim.failures, isEmpty);
      });

      test('apply to polling calls without recording them', () {
        shim.failures['readEvents'] = AMW_E_UNEXPECTED;
        expect(shim.readEvents, throwsA(isA<MidiNativeError>()));
        expect(shim.calls, equals(['create']));
      });
    });

    group('rearm(), signals', () {
      test('signal once until rearmed, later in the event loop', () async {
        shim
          ..watchStart(AMW_SOURCE_MIDI1_IN)
          ..completeEnumerationOf(AMW_SOURCE_MIDI1_IN);
        expect(signals, 0);
        await tick();
        expect(signals, 1);
        shim.disconnect(1);
        await tick();
        expect(signals, 1);
        shim
          ..rearm()
          ..disconnect(1);
        await tick();
        expect(signals, 2);
      });
    });

    group('watchStart(sources), watchStop()', () {
      test('report the ports of the sources and complete', () {
        shim.watchStart(AMW_SOURCE_MIDI1_IN | AMW_SOURCE_MIDI2);
        expect(
          events(),
          equals(const [
            WindowsMidiShimPortAdded(input),
            WindowsMidiShimEnumerationCompleted(AMW_SOURCE_MIDI1_IN),
            WindowsMidiShimEnumerationCompleted(AMW_SOURCE_MIDI2),
          ]),
        );
        expect(shim.watchedSources, AMW_SOURCE_MIDI1_IN | AMW_SOURCE_MIDI2);
        shim.watchStop();
        expect(shim.watchedSources, 0);
        expect(shim.calls, equals(['create', 'watchStart(5)', 'watchStop']));
      });

      test('leave the completion to the test when asked', () {
        shim
          ..completeEnumeration = false
          ..watchStart(AMW_SOURCE_MIDI1_OUT);
        expect(events(), equals(const [WindowsMidiShimPortAdded(output)]));
        shim.stopWatcher(source: AMW_SOURCE_MIDI1_OUT, status: 5);
        expect(
          events(),
          equals(const [
            WindowsMidiShimWatcherStopped(
              source: AMW_SOURCE_MIDI1_OUT,
              status: 5,
            ),
          ]),
        );
      });
    });

    group('addPort(port), updatePort(port), removePort(...)', () {
      test('report changes of watched sources only', () {
        const added = WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI1_IN,
          id: 'new',
          name: 'New',
        );
        shim
          ..addPort(added)
          ..updatePort(added)
          ..removePort(source: AMW_SOURCE_MIDI1_IN, id: 'new');
        expect(events(), isEmpty);
        shim
          ..completeEnumeration = false
          ..watchStart(AMW_SOURCE_MIDI1_IN);
        events();
        final renamed = added.copyWith(name: 'Renamed');
        shim
          ..addPort(added)
          ..updatePort(renamed)
          ..removePort(source: AMW_SOURCE_MIDI1_IN, id: 'new');
        expect(
          events(),
          equals([
            const WindowsMidiShimPortAdded(added),
            WindowsMidiShimPortUpdated(renamed),
            const WindowsMidiShimPortRemoved(
              source: AMW_SOURCE_MIDI1_IN,
              id: 'new',
            ),
          ]),
        );
      });

      test('encode endpoints so that the decoder reads them back', () {
        final identity = MidiDeviceIdentity(
          manufacturerId: [0, 0x21, 9],
          familyId: 300,
          modelId: 2,
          softwareRevision: [1, 2, 3, 4],
        );
        final endpoint = WindowsMidiEndpointRecord(
          purpose: 500,
          nativeDataFormat: 2,
          transportCode: 'KS',
          manufacturer: 'M',
          serialNumber: 'S',
          description: 'D',
          vendorId: 1,
          productId: 2,
          flags: AMW_ENDPOINT_SUPPORTS_MIDI2 | AMW_ENDPOINT_HAS_IDENTITY,
          endpointName: 'E',
          productInstanceId: 'P',
          declaredFunctionBlockCount: 1,
          umpVersionMajor: 1,
          umpVersionMinor: 1,
          protocol: 2,
          identity: identity,
          functionBlocks: const [
            MidiFunctionBlockInfo(
              number: 1,
              name: 'B',
              isActive: false,
              direction: MidiFunctionBlockDirection.output,
              uiHint: MidiFunctionBlockUiHint.sender,
              midi1: MidiFunctionBlockMidi1.unrestricted,
              firstGroup: 2,
              groupCount: 3,
              midiCiVersion: 1,
              maxSysEx8Streams: 2,
            ),
          ],
          groupTerminalBlocks: const [
            WindowsMidiGroupTerminalBlock(
              number: 1,
              name: 'T',
              direction: 2,
              protocol: 0x11,
              firstGroup: 0,
              groupCount: 1,
            ),
          ],
        );
        final ump = WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI2,
          id: 'ump',
          name: 'Ump',
          endpoint: endpoint,
        );
        final plain = WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI2,
          id: 'plain',
          name: 'Plain',
          endpoint: WindowsMidiEndpointRecord(flags: AMW_ENDPOINT_HAS_IDENTITY),
        );
        shim
          ..addPort(ump)
          ..addPort(plain)
          ..watchStart(AMW_SOURCE_MIDI2);
        expect(
          events(),
          equals([
            WindowsMidiShimPortAdded(ump),
            WindowsMidiShimPortAdded(
              plain.copyWith(endpoint: WindowsMidiEndpointRecord()),
            ),
            const WindowsMidiShimEnumerationCompleted(AMW_SOURCE_MIDI2),
          ]),
        );
      });
    });

    group('openPort(...), completeOpen(...), closePort(handle)', () {
      test('open ports with new handles on their own', () {
        shim
          ..openPort(request: 5, id: 'in', kind: AMW_KIND_MIDI1_IN)
          ..openPort(request: 6, id: 'out', kind: AMW_KIND_MIDI1_OUT);
        expect(
          events(),
          equals(const [
            WindowsMidiShimOpenCompleted(request: 5, status: 0, handle: 1),
            WindowsMidiShimOpenCompleted(request: 6, status: 0, handle: 2),
          ]),
        );
        expect(
          shim.openPorts,
          equals({
            1: (id: 'in', kind: AMW_KIND_MIDI1_IN),
            2: (id: 'out', kind: AMW_KIND_MIDI1_OUT),
          }),
        );
        shim.closePort(1);
        expect(shim.openPorts.keys, equals([2]));
        expect(
          () => shim.closePort(1),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              AMW_E_UNKNOWN_HANDLE,
            ),
          ),
        );
        expect(
          shim.calls,
          equals([
            'create',
            'openPort(in, 1)',
            'openPort(out, 2)',
            'closePort(1)',
            'closePort(1)',
          ]),
        );
      });

      test('fail with the status of openStatus', () {
        shim
          ..openStatus['in'] = AMW_E_PORT_UNAVAILABLE
          ..openPort(request: 5, id: 'in', kind: AMW_KIND_MIDI1_IN);
        expect(
          events(),
          equals(const [
            WindowsMidiShimOpenCompleted(
              request: 5,
              status: AMW_E_PORT_UNAVAILABLE,
              message: 'fake failure',
            ),
          ]),
        );
        expect(shim.openPorts, isEmpty);
      });

      test('wait for completeOpen when autoComplete is off', () {
        shim
          ..autoComplete = false
          ..openPort(request: 5, id: 'in', kind: AMW_KIND_MIDI2_IN);
        expect(shim.pendingOpens, equals([5]));
        expect(events(), isEmpty);
        shim.completeOpen(5, status: AMW_E_CLOSED);
        expect(shim.pendingOpens, isEmpty);
        expect(
          events().single,
          isA<WindowsMidiShimOpenCompleted>().having(
            (e) => e.status,
            'status',
            AMW_E_CLOSED,
          ),
        );
      });
    });

    group('receive(...), overflow(...), readPort(handle)', () {
      test('hand out the records and losses of an input', () async {
        shim.openPort(request: 1, id: 'in', kind: AMW_KIND_MIDI2_IN);
        shim
          ..receive(1, [0x90, 0x3C, 0x64], timeMicros: 10)
          ..receive(1, [1, 0, 0, 0x20], timeMicros: 11, ump: true)
          ..overflow(1, 2);
        final read = shim.readPort(1);
        expect(
          decoder.decodeRecords(read.records),
          equals([
            WindowsMidiDataRecord(timeMicros: 10, data: [0x90, 0x3C, 0x64]),
            WindowsMidiDataRecord(
              timeMicros: 11,
              flags: AMW_RECORD_UMP,
              data: [1, 0, 0, 0x20],
            ),
          ]),
        );
        expect(read.dropped, 2);
        final again = shim.readPort(1);
        expect([again.records, again.dropped], equals([<int>[], 0]));
        await tick();
        expect(signals, 1);
      });

      test('readPort throws for ports without records', () {
        shim.openPort(request: 1, id: 'out', kind: AMW_KIND_MIDI2_OUT);
        expect(
          () => shim.readPort(1),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              AMW_E_UNKNOWN_HANDLE,
            ),
          ),
        );
      });
    });

    group('send(...)', () {
      test('records what open ports send', () {
        shim.openPort(request: 1, id: 'out', kind: AMW_KIND_MIDI1_OUT);
        final data = Uint8List.fromList([0x90, 0x3C, 0x64]);
        shim.send(handle: 1, data: data, dueMicros: 5);
        data[0] = 0;
        expect(shim.sent.single.handle, 1);
        expect(shim.sent.single.data, equals([0x90, 0x3C, 0x64]));
        expect(shim.sent.single.dueMicros, 5);
        expect(
          () => shim.send(handle: 9, data: data, dueMicros: 0),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              AMW_E_UNKNOWN_HANDLE,
            ),
          ),
        );
      });
    });

    group('Bluetooth LE', () {
      test('scans, advertises and stops', () {
        shim.bleScanStart();
        expect(shim.isScanning, isTrue);
        shim
          ..advertise(address: 1, name: 'A')
          ..advertise(address: 2, rssi: -70, connectable: false)
          ..stopScan(1);
        expect(shim.isScanning, isFalse);
        expect(
          events(),
          equals(const [
            WindowsMidiShimBleAdvertisement(
              address: 1,
              rssi: -60,
              flags: AMW_BLE_CONNECTABLE,
              name: 'A',
            ),
            WindowsMidiShimBleAdvertisement(address: 2, rssi: -70),
            WindowsMidiShimBleScanStopped(1),
          ]),
        );
        shim
          ..bleScanStart()
          ..bleScanStop();
        expect(shim.isScanning, isFalse);
      });

      test('pairs and unpairs with the configured results', () {
        shim
          ..pairStatus = AMW_E_NOT_FOUND
          ..pairResult = 19
          ..blePair(request: 1, address: 2)
          ..unpairResult = 1
          ..bleUnpair(request: 3, address: 2);
        expect(
          events(),
          equals(const [
            WindowsMidiShimBlePairCompleted(
              request: 1,
              status: AMW_E_NOT_FOUND,
              result: 19,
              message: 'fake failure',
            ),
            WindowsMidiShimBleUnpairCompleted(request: 3, status: 0, result: 1),
          ]),
        );
        expect(shim.calls.skip(1), equals(['blePair(2)', 'bleUnpair(2)']));
      });

      test('waits for completePairing when autoComplete is off', () {
        shim
          ..autoComplete = false
          ..blePair(request: 1, address: 2);
        expect(shim.pendingPairings, equals([1]));
        shim.completePairing(1);
        expect(shim.pendingPairings, isEmpty);
        expect(
          events(),
          equals(const [
            WindowsMidiShimBlePairCompleted(request: 1, status: 0, result: 0),
          ]),
        );
      });
    });

    group('virtualCreate(...), completeVirtual(request)', () {
      test('creates virtual devices with new handles', () {
        shim.virtualCreate(request: 4, spec: Uint8List.fromList([1, 2]));
        expect(shim.virtualSpecs.single, equals([1, 2]));
        expect(
          events(),
          equals(const [
            WindowsMidiShimVirtualCreated(
              request: 4,
              status: 0,
              handle: 1,
              endpointId: 'fake-virtual-4',
            ),
          ]),
        );
        expect(
          shim.openPorts,
          equals({1: (id: 'fake-virtual-4', kind: AMW_KIND_VIRTUAL)}),
        );
        shim.receive(1, [1], timeMicros: 0);
      });

      test('fails with virtualStatus and waits when asked', () {
        shim
          ..autoComplete = false
          ..virtualStatus = AMW_E_UNSUPPORTED
          ..virtualCreate(request: 4, spec: Uint8List(0));
        expect(shim.pendingVirtual, equals([4]));
        shim.completeVirtual(4);
        expect(shim.pendingVirtual, isEmpty);
        expect(
          events(),
          equals(const [
            WindowsMidiShimVirtualCreated(
              request: 4,
              status: AMW_E_UNSUPPORTED,
              message: 'fake failure',
            ),
          ]),
        );
      });
    });

    group('corrupt(handle, bytes), signalNow()', () {
      test('append raw bytes to the records of an input', () {
        shim
          ..openPort(request: 1, id: 'in', kind: AMW_KIND_MIDI1_IN)
          ..corrupt(1, [1, 2, 3]);
        expect(shim.readPort(1).records, equals([1, 2, 3]));
      });

      test('signal at once, even after destroy', () {
        shim.signalNow();
        shim.destroy();
        shim.signalNow();
        expect(signals, 2);
        WindowsMidiFakeShim().signalNow();
      });
    });

    group('disconnect(handle), fail(...), dropEvents(count), emit(...)', () {
      test('emit the events', () {
        shim
          ..disconnect(3)
          ..fail(status: AMW_E_UNEXPECTED, source: 1, api: 'a', message: 'm')
          ..fail(status: AMW_E_UNEXPECTED)
          ..dropEvents(2)
          ..emit(99, [7]);
        expect(
          events(),
          equals([
            const WindowsMidiShimPortDisconnected(3),
            const WindowsMidiShimError(
              status: AMW_E_UNEXPECTED,
              source: 1,
              api: 'a',
              message: 'm',
            ),
            const WindowsMidiShimError(status: AMW_E_UNEXPECTED, api: 'fake'),
            const WindowsMidiShimEventsDropped(2),
            WindowsMidiShimUnknownEvent(kind: 99, payload: [7]),
          ]),
        );
      });
    });
  });
}
