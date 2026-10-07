// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/backend/windows_midi_requests.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_shim_decoder.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_status.dart';
import 'package:test/test.dart';

void main() {
  const address = 0xC0A1B2C3D4E5;
  const peripheral = 'c0:a1:b2:c3:d4:e5';
  late WindowsMidiFakeShim shim;
  late WindowsMidiRequests requests;
  late WindowsMidiBluetooth bluetooth;
  late List<MidiPortInfo> ports;
  late StreamController<void> portsChanged;

  MidiPortInfo blePort(MidiDirection direction, {int at = address}) =>
      MidiPortInfo(
        id: MidiPortId('winrt:${direction.name}:$at'),
        name: 'WIDI',
        direction: direction,
        transport: MidiTransport.bluetoothLe,
        native: {
          'windowsId':
              r'\\?\BTHLEDEVICE#{03b80e5a}_Dev_VID&_REV&0001_'
              '${at.toRadixString(16).padLeft(12, '0')}#x',
          'deviceInstanceId': '',
        },
      );

  // Routes the events of the fake like the backend does.
  void drain() {
    shim.rearm();
    const decoder = WindowsMidiShimDecoder();
    for (final event in decoder.decodeEvents(shim.readEvents())) {
      switch (event) {
        case WindowsMidiShimCompletion():
          requests.complete(event);
        case WindowsMidiShimBleAdvertisement():
          bluetooth.onAdvertisement(event);
        case WindowsMidiShimBleScanStopped():
          bluetooth.onScanStopped();
        default:
          break;
      }
    }
  }

  void setPorts(List<MidiPortInfo> value) {
    ports = value;
    portsChanged.add(null);
  }

  setUp(() {
    shim = WindowsMidiFakeShim(features: AMW_FEATURE_MIDI1);
    requests = WindowsMidiRequests();
    ports = [];
    portsChanged = StreamController.broadcast(sync: true);
    bluetooth = WindowsMidiBluetooth(
      shim: shim,
      requests: requests,
      ports: () => ports,
      portsChanged: portsChanged.stream,
      settle: const Duration(milliseconds: 20),
      unpairTimeout: const Duration(milliseconds: 50),
    );
    shim.create(onSignal: drain);
  });

  tearDown(() => portsChanged.close());

  group('WindowsMidiBluetooth', () {
    group('scan(timeout), stopScan()', () {
      test('report the advertisements until stopped', () async {
        final found = <MidiBlePeripheralInfo>[];
        final done = bluetooth.scan().listen(found.add).asFuture<void>();
        expect([shim.isScanning, bluetooth.isScanning], equals([true, true]));
        shim
          ..advertise(address: address, name: 'WIDI', rssi: -50)
          ..advertise(address: 1, connectable: false);
        await Future<void>.delayed(Duration.zero);
        await bluetooth.stopScan();
        await done;
        expect(
          found,
          equals([
            MidiBlePeripheralInfo(id: peripheral, name: 'WIDI', rssi: -50),
            MidiBlePeripheralInfo(
              id: '00:00:00:00:00:01',
              rssi: -60,
              isConnectable: false,
            ),
          ]),
        );
        expect([shim.isScanning, bluetooth.isScanning], equals([false, false]));
        await bluetooth.stopScan();
        expect(shim.calls.where((c) => c == 'bleScanStop'), hasLength(1));
      });

      test('end after the timeout', () async {
        await bluetooth
            .scan(timeout: const Duration(milliseconds: 10))
            .toList();
        expect(shim.calls, contains('bleScanStop'));
      });

      test('end when Windows stops the scan', () async {
        final done = bluetooth.scan().toList();
        shim.stopScan(1);
        expect(await done, isEmpty);
        expect(bluetooth.isScanning, isFalse);
      });

      test('end when the listener cancels', () async {
        final subscription = bluetooth.scan().listen((_) {});
        await subscription.cancel();
        expect(shim.calls, contains('bleScanStop'));
        expect(bluetooth.isScanning, isFalse);
      });

      test('a new scan replaces the running one', () async {
        final first = bluetooth.scan().listen((_) {});
        final firstDone = first.asFuture<void>();
        final found = <MidiBlePeripheralInfo>[];
        bluetooth.scan().listen(found.add);
        await firstDone;
        await first.cancel();
        expect(bluetooth.isScanning, isTrue);
        shim.advertise(address: 2);
        await Future<void>.delayed(Duration.zero);
        expect(found.single.id, '00:00:00:00:00:02');
        await bluetooth.stopScan();
      });

      test('stopScan ignores a failing native stop', () async {
        final done = bluetooth.scan().toList();
        shim.failures['bleScanStop'] = AMW_E_UNEXPECTED;
        await bluetooth.stopScan();
        expect(await done, isEmpty);
      });

      test('advertisements without a scan are dropped', () async {
        shim.advertise(address: 1);
        await Future<void>.delayed(Duration.zero);
        expect(bluetooth.isScanning, isFalse);
      });
    });

    group('close()', () {
      test('ends the scan without stopping it natively', () async {
        final done = bluetooth.scan().toList();
        bluetooth.close();
        expect(await done, isEmpty);
        expect(shim.calls, isNot(contains('bleScanStop')));
        bluetooth.close();
      });
    });

    group('connect(peripheralId, timeout)', () {
      test('pairs and returns both ports of the peripheral', () async {
        final connect = bluetooth.connect(peripheral);
        await Future<void>.delayed(Duration.zero);
        expect(shim.calls, contains('blePair($address)'));
        final input = blePort(MidiDirection.input);
        final output = blePort(MidiDirection.output);
        setPorts([blePort(MidiDirection.input, at: 7)]);
        setPorts([input, output]);
        expect(await connect, equals([input, output]));
      });

      test('returns ports that exist already', () async {
        final input = blePort(MidiDirection.input);
        final output = blePort(MidiDirection.output);
        ports = [input, output];
        expect(await bluetooth.connect(peripheral), equals([input, output]));
      });

      test('returns one port after the settle time', () async {
        final input = blePort(MidiDirection.input);
        final connect = bluetooth.connect(peripheral);
        await Future<void>.delayed(Duration.zero);
        setPorts([input]);
        setPorts([input]);
        expect(await connect, equals([input]));
      });

      test('fails when no port appears in time', () async {
        await expectLater(
          bluetooth.connect(
            peripheral,
            timeout: const Duration(milliseconds: 30),
          ),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              WindowsMidiStatus.timeout,
            ),
          ),
        );
      });

      test('fails when pairing does not complete in time', () async {
        shim.autoComplete = false;
        await expectLater(
          bluetooth.connect(peripheral, timeout: Duration.zero),
          throwsA(
            isA<MidiNativeError>()
                .having(
                  (e) => e.api,
                  'api',
                  'DeviceInformationCustomPairing.PairAsync',
                )
                .having((e) => e.code, 'code', WindowsMidiStatus.timeout),
          ),
        );
      });

      test('maps failed pairings to exceptions', () async {
        final cases = <(int, int), Matcher>{
          (AMW_E_NOT_FOUND, 19): isA<MidiNativeError>().having(
            (e) => e.code,
            'code',
            AMW_E_NOT_FOUND,
          ),
          (AMW_E_ACCESS_DENIED, 19): isA<MidiPermissionDenied>().having(
            (e) => e.permission,
            'permission',
            MidiPermission.bluetooth,
          ),
          (AMW_E_UNSUPPORTED, 19): isA<MidiUnsupported>().having(
            (e) => e.feature,
            'feature',
            'Bluetooth LE MIDI',
          ),
          (AMW_OK, WindowsMidiShimBlePairCompleted.accessDenied):
              isA<MidiPermissionDenied>(),
          (AMW_OK, 19): isA<MidiNativeError>().having(
            (e) => e.code,
            'code',
            19,
          ),
        };
        for (final MapEntry(key: (status, result), value: matcher)
            in cases.entries) {
          shim
            ..pairStatus = status
            ..pairResult = result;
          await expectLater(
            bluetooth.connect(peripheral),
            throwsA(matcher),
            reason: '$status $result',
          );
        }
      });

      test('rejects malformed peripheral ids', () {
        expect(() => bluetooth.connect('nope'), throwsA(isA<ArgumentError>()));
      });
    });

    group('disconnect(peripheralId)', () {
      test('unpairs the peripheral', () async {
        for (final result in [
          WindowsMidiShimBleUnpairCompleted.unpaired,
          WindowsMidiShimBleUnpairCompleted.alreadyUnpaired,
        ]) {
          shim.unpairResult = result;
          await bluetooth.disconnect(peripheral);
        }
        expect(
          shim.calls.where((call) => call.startsWith('bleUnpair')),
          equals(['bleUnpair($address)', 'bleUnpair($address)']),
        );
      });

      test('maps failed unpairings to exceptions', () async {
        shim.unpairResult = WindowsMidiShimBleUnpairCompleted.accessDenied;
        await expectLater(
          bluetooth.disconnect(peripheral),
          throwsA(isA<MidiPermissionDenied>()),
        );
        shim.unpairResult = 4;
        await expectLater(
          bluetooth.disconnect(peripheral),
          throwsA(
            isA<MidiNativeError>()
                .having(
                  (e) => e.api,
                  'api',
                  'DeviceInformationPairing.UnpairAsync',
                )
                .having((e) => e.code, 'code', 4),
          ),
        );
      });

      test('fails when unpairing does not complete in time', () async {
        shim.autoComplete = false;
        await expectLater(
          bluetooth.disconnect(peripheral),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              WindowsMidiStatus.timeout,
            ),
          ),
        );
      });
    });

    group('addressText(address), parseAddress(peripheralId)', () {
      test('convert between addresses and peripheral ids', () {
        expect(WindowsMidiBluetooth.addressText(address), peripheral);
        expect(WindowsMidiBluetooth.addressText(1), '00:00:00:00:00:01');
        for (final id in [peripheral, 'C0-A1-B2-C3-D4-E5', 'c0a1b2c3d4e5']) {
          expect(WindowsMidiBluetooth.parseAddress(id), address, reason: id);
        }
      });

      test('parseAddress rejects other text', () {
        for (final id in ['', 'c0:a1', 'zz:a1:b2:c3:d4:e5']) {
          expect(
            () => WindowsMidiBluetooth.parseAddress(id),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                'Not a Bluetooth address',
              ),
            ),
            reason: id,
          );
        }
      });
    });

    group('isPortOf(port, address)', () {
      test('matches BLE ports whose ids carry the address', () {
        expect(
          WindowsMidiBluetooth.isPortOf(blePort(MidiDirection.input), address),
          isTrue,
        );
        expect(
          WindowsMidiBluetooth.isPortOf(blePort(MidiDirection.input), 7),
          isFalse,
        );
        expect(
          WindowsMidiBluetooth.isPortOf(
            blePort(MidiDirection.input).copyWith(transport: MidiTransport.usb),
            address,
          ),
          isFalse,
        );
        expect(
          WindowsMidiBluetooth.isPortOf(
            MidiPortInfo(
              id: const MidiPortId('winrt:in:x'),
              name: 'x',
              direction: MidiDirection.input,
              transport: MidiTransport.bluetoothLe,
              native: const {'deviceInstanceId': 'C0A1B2C3D4E5'},
            ),
            address,
          ),
          isTrue,
        );
      });
    });

    group('settle, unpairTimeout', () {
      test('default to half a second and ten seconds', () {
        final defaults = WindowsMidiBluetooth(
          shim: shim,
          requests: requests,
          ports: () => const [],
          portsChanged: const Stream.empty(),
        );
        expect(
          [defaults.settle, defaults.unpairTimeout],
          equals([
            const Duration(milliseconds: 500),
            const Duration(seconds: 10),
          ]),
        );
      });
    });
  });
}
