// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';
import 'dart:typed_data';

import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_byte_writer.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_data_record.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_shim_decoder.dart';
import 'package:test/test.dart';

void main() {
  const decoder = WindowsMidiShimDecoder();

  // Reads the hex lines of a golden file that
  // test/native/aud_midi_windows_core_test.cpp writes.
  List<Uint8List> golden(String name) => [
    for (final line in File('test/goldens/$name').readAsLinesSync())
      if (line.isNotEmpty && !line.startsWith('#'))
        Uint8List.fromList([
          for (var i = 0; i < line.length; i += 2)
            int.parse(line.substring(i, i + 2), radix: 16),
        ]),
  ];

  Uint8List event(int kind, void Function(WindowsMidiByteWriter) write) {
    final payload = WindowsMidiByteWriter();
    write(payload);
    final bytes = payload.toBytes();
    return (WindowsMidiByteWriter()
          ..u32(kind)
          ..u32(bytes.length)
          ..bytes(bytes))
        .toBytes();
  }

  const midi1Id =
      r'\\?\SWD#MMDEVAPI#MIDII_4A3B2C1D.P_0000#'
      '{504be32c-ccf6-4d2c-b73f-6f8b3747e22b}';

  group('WindowsMidiShimDecoder', () {
    group('decodeEvents(bytes)', () {
      test('decodes the events the native shim writes', () {
        final events = [
          for (final bytes in golden('shim_events.hex'))
            ...decoder.decodeEvents(bytes),
        ];
        expect(
          events,
          equals([
            const WindowsMidiShimPortAdded(
              WindowsMidiPortRecord(
                source: AMW_SOURCE_MIDI1_IN,
                id: midi1Id,
                name: 'Keystation 49',
                deviceInstanceId:
                    r'USB\VID_1C75&PID_0206&MI_01\7&2A9D0B1C&0&0001',
                containerId: '{8e1f6d2a-3b4c-4d5e-8f60-718293a4b5c6}',
              ),
            ),
            const WindowsMidiShimPortAdded(
              WindowsMidiPortRecord(
                source: AMW_SOURCE_MIDI1_OUT,
                id:
                    r'\\?\BTHLEDEVICE#{03b80e5a-ede8-4b33-a751-6ce34ec4c700}'
                    '_Dev_VID&0205e8_PID&2001_REV&0001_c0a1b2c3d4e5'
                    '#8&1a2b3c4d&0&0010#{6dc23320-ab33-4ce4-80d4-bbb3ebbf2814}',
                name: 'Gerät — 🎹',
                flags: 0,
                deviceInstanceId:
                    r'BTHLEDEVICE\{03B80E5A-EDE8-4B33-A751-6CE34EC4C700}'
                    r'_DEV_VID&0205E8_PID&2001_REV&0001_C0A1B2C3D4E5'
                    r'\8&1A2B3C4D&0&0010',
              ),
            ),
            WindowsMidiShimPortUpdated(
              WindowsMidiPortRecord(
                source: AMW_SOURCE_MIDI2,
                id:
                    r'\\?\swd#midisrv#midiu_ks_6799286025327820155_outpin.0_'
                    'inpin.2#{e7cce071-3c03-423f-88d3-f1045d02552b}',
                name: 'MIDI 2.0 Synth',
                deviceInstanceId: r'SWD\MIDISRV\MIDIU_KS_6799286025327820155',
                containerId: '{11111111-2222-3333-4444-555555555555}',
                endpoint: WindowsMidiEndpointRecord(
                  nativeDataFormat: 2,
                  transportCode: 'KS',
                  manufacturer: 'Audanika',
                  serialNumber: 'SN-42',
                  description: 'A test synth',
                  vendorId: 0x1234,
                  productId: 0xABCD,
                  flags:
                      AMW_ENDPOINT_SUPPORTS_MIDI1 |
                      AMW_ENDPOINT_SUPPORTS_MIDI2 |
                      AMW_ENDPOINT_SUPPORTS_RX_JR |
                      AMW_ENDPOINT_STATIC_BLOCKS |
                      AMW_ENDPOINT_HAS_IDENTITY |
                      AMW_ENDPOINT_MULTI_CLIENT |
                      AMW_ENDPOINT_RECEIVES_JR |
                      AMW_ENDPOINT_DISCOVERY_COMPLETE,
                  endpointName: 'Synth Endpoint',
                  productInstanceId: 'PI-7',
                  declaredFunctionBlockCount: 2,
                  umpVersionMajor: 1,
                  umpVersionMinor: 1,
                  protocol: 2,
                  identity: MidiDeviceIdentity(
                    manufacturerId: [0x00, 0x21, 0x09],
                    familyId: 0x01 | 0x02 << 7,
                    modelId: 0x03 | 0x04 << 7,
                    softwareRevision: [5, 6, 7, 8],
                  ),
                  functionBlocks: const [
                    MidiFunctionBlockInfo(
                      number: 0,
                      name: 'Main',
                      direction: MidiFunctionBlockDirection.bidirectional,
                      uiHint: MidiFunctionBlockUiHint.senderReceiver,
                      firstGroup: 0,
                      groupCount: 2,
                      midiCiVersion: 1,
                      maxSysEx8Streams: 4,
                    ),
                    MidiFunctionBlockInfo(
                      number: 1,
                      name: 'DIN In',
                      isActive: false,
                      direction: MidiFunctionBlockDirection.input,
                      uiHint: MidiFunctionBlockUiHint.receiver,
                      midi1: MidiFunctionBlockMidi1.restricted31250,
                      firstGroup: 2,
                      groupCount: 1,
                    ),
                  ],
                  groupTerminalBlocks: const [
                    WindowsMidiGroupTerminalBlock(
                      number: 1,
                      name: 'Terminal',
                      protocol: 0x11,
                      firstGroup: 0,
                      groupCount: 3,
                    ),
                  ],
                ),
              ),
            ),
            const WindowsMidiShimPortRemoved(
              source: AMW_SOURCE_MIDI1_IN,
              id: midi1Id,
            ),
            const WindowsMidiShimEnumerationCompleted(AMW_SOURCE_MIDI1_OUT),
            const WindowsMidiShimWatcherStopped(
              source: AMW_SOURCE_MIDI2,
              status: 5,
            ),
            const WindowsMidiShimOpenCompleted(
              request: 41,
              status: AMW_OK,
              handle: 3,
            ),
            const WindowsMidiShimOpenCompleted(
              request: 42,
              status: AMW_E_PORT_UNAVAILABLE,
              message: 'no port',
            ),
            const WindowsMidiShimPortDisconnected(3),
            const WindowsMidiShimBleAdvertisement(
              address: 0xC0A1B2C3D4E5,
              rssi: -67,
              flags: AMW_BLE_CONNECTABLE,
              name: 'WIDI',
            ),
            const WindowsMidiShimBleScanStopped(1),
            const WindowsMidiShimBlePairCompleted(
              request: 43,
              status: AMW_OK,
              result: 0,
            ),
            const WindowsMidiShimBleUnpairCompleted(
              request: 44,
              status: AMW_E_ACCESS_DENIED,
              result: 3,
              message: 'denied',
            ),
            const WindowsMidiShimVirtualCreated(
              request: 45,
              status: AMW_OK,
              handle: 9,
              endpointId: r'\\?\swd#midisrv#midiu_app_1',
            ),
            const WindowsMidiShimError(
              status: AMW_E_UNSUPPORTED,
              source: AMW_SOURCE_MIDI2,
              api: 'MidiEndpointDeviceWatcher',
              message: 'not built in',
            ),
            const WindowsMidiShimEventsDropped(3),
          ]),
        );
      });

      test('decodes several events of one buffer', () {
        final bytes = [
          ...event(AMW_EVENT_ENUMERATION_COMPLETED, (out) => out.u32(1)),
          ...event(AMW_EVENT_PORT_DISCONNECTED, (out) => out.u32(2)),
        ];
        expect(
          decoder.decodeEvents(Uint8List.fromList(bytes)),
          equals(const [
            WindowsMidiShimEnumerationCompleted(1),
            WindowsMidiShimPortDisconnected(2),
          ]),
        );
      });

      test('keeps events of unknown kinds', () {
        expect(
          decoder.decodeEvents(event(99, (out) => out.bytes([1, 2]))),
          equals([
            WindowsMidiShimUnknownEvent(kind: 99, payload: [1, 2]),
          ]),
        );
      });

      test('ignores bytes appended to a known event', () {
        expect(
          decoder.decodeEvents(
            event(AMW_EVENT_PORT_DISCONNECTED, (out) {
              out.u32(2);
              out.u32(7);
            }),
          ),
          equals(const [WindowsMidiShimPortDisconnected(2)]),
        );
      });

      test('throws for truncated buffers', () {
        expect(
          () => decoder.decodeEvents(Uint8List.fromList([1, 0, 0, 0, 9])),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => decoder.decodeEvents(
            event(AMW_EVENT_PORT_DISCONNECTED, (out) => out.u8(1)),
          ),
          throwsA(isA<FormatException>()),
        );
      });

      test('caps group counts and keeps groups in range', () {
        final bytes = event(AMW_EVENT_PORT_ADDED, (out) {
          out
            ..u32(AMW_SOURCE_MIDI2)
            ..string('id')
            ..string('n')
            ..u32(1)
            ..string('')
            ..string('')
            ..u8(1)
            ..u32(0)
            ..u32(2)
            ..string('')
            ..string('')
            ..string('')
            ..string('')
            ..u16(0)
            ..u16(0)
            ..u32(0)
            ..string('')
            ..string('')
            ..bytes([0, 0, 0, 0])
            ..bytes(List.filled(11, 0))
            ..u32(1)
            ..bytes([0, 1, 3, 0, 0, 0x13, 20, 0, 0])
            ..string('')
            ..u32(1)
            ..bytes([0, 0, 0, 0x12, 17])
            ..string('');
        });
        final record =
            (decoder.decodeEvents(bytes).single as WindowsMidiShimPortAdded)
                .port;
        expect([
          record.endpoint!.functionBlocks.single.firstGroup,
          record.endpoint!.functionBlocks.single.groupCount,
          record.endpoint!.groupTerminalBlocks.single.firstGroup,
          record.endpoint!.groupTerminalBlocks.single.groupCount,
          record.endpoint!.identity,
        ], equals([3, 16, 2, 16, null]));
      });
    });

    group('decodeRecords(bytes)', () {
      test('decodes the records the native shim writes', () {
        expect(
          decoder.decodeRecords(golden('shim_records.hex').single),
          equals([
            WindowsMidiDataRecord(timeMicros: 1000, data: [0x90, 0x3C, 0x64]),
            WindowsMidiDataRecord(
              timeMicros: -5,
              data: [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7],
            ),
            WindowsMidiDataRecord(
              timeMicros: 0x123456789A,
              flags: AMW_RECORD_UMP,
              data: [0x64, 0x00, 0x90, 0x40, 0x00, 0x00, 0x00, 0xC8],
            ),
            WindowsMidiDataRecord(
              timeMicros: 7,
              flags: AMW_RECORD_UMP,
              data: [],
            ),
          ]),
        );
      });

      test('returns nothing for an empty buffer', () {
        expect(decoder.decodeRecords(Uint8List(0)), isEmpty);
      });

      test('throws for a truncated record', () {
        expect(
          () => decoder.decodeRecords(Uint8List(10)),
          throwsA(isA<FormatException>()),
        );
      });
    });
  });
}
