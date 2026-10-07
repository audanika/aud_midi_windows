// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/backend/windows_midi_port_mapper.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:test/test.dart';

void main() {
  const mapper = WindowsMidiPortMapper();

  MidiFunctionBlockInfo block(
    int number,
    MidiFunctionBlockDirection direction, {
    int first = 0,
    int count = 1,
    bool active = true,
    String name = '',
  }) => MidiFunctionBlockInfo(
    number: number,
    name: name,
    isActive: active,
    direction: direction,
    firstGroup: first,
    groupCount: count,
  );

  WindowsMidiPortRecord ump(WindowsMidiEndpointRecord endpoint) =>
      WindowsMidiPortRecord(
        source: AMW_SOURCE_MIDI2,
        id: 'ep',
        name: 'Endpoint',
        deviceInstanceId: 'SWD',
        containerId: '{c}',
        endpoint: endpoint,
      );

  group('WindowsMidiPortMapper', () {
    group('map(record)', () {
      test('maps a WinRT MIDI 1.0 input to a byte input', () {
        const record = WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI1_IN,
          id: r'\\?\USB#VID_1',
          name: 'Keys',
          deviceInstanceId: r'USB\VID_1',
          containerId: '{c}',
        );
        expect(
          mapper.map(record),
          equals([
            MidiPortInfo(
              id: const MidiPortId(r'winrt:in:\\?\USB#VID_1'),
              deviceId: const MidiDeviceId(r'winrt:in:\\?\USB#VID_1'),
              name: 'Keys',
              direction: MidiDirection.input,
              transport: MidiTransport.usb,
              capabilities: const MidiPortCapabilities(timestampsIn: true),
            ),
          ]),
        );
        expect(
          mapper.map(record).single.native,
          equals({
            'deviceName': 'Keys',
            'product': 'Keys',
            'driver': 'winrt',
            'windowsId': r'\\?\USB#VID_1',
            'deviceInstanceId': r'USB\VID_1',
            'containerId': '{c}',
          }),
        );
      });

      test('maps a disabled WinRT MIDI 1.0 output to an offline port', () {
        const record = WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI1_OUT,
          id: 'MIDIU_APP_1',
          name: 'Out',
          flags: 0,
        );
        expect(
          mapper.map(record),
          equals([
            MidiPortInfo(
              id: const MidiPortId('winrt:out:MIDIU_APP_1'),
              deviceId: const MidiDeviceId('winrt:out:MIDIU_APP_1'),
              name: 'Out',
              direction: MidiDirection.output,
              transport: MidiTransport.virtual,
              state: MidiPortState.offline,
              isVirtual: true,
            ),
          ]),
        );
      });

      test('maps a UMP endpoint to an input and an output', () {
        final endpoint = WindowsMidiEndpointRecord(
          nativeDataFormat: 2,
          transportCode: 'KS',
          manufacturer: 'Audanika',
          serialNumber: 'SN',
          vendorId: 1,
          productId: 2,
          flags: AMW_ENDPOINT_SUPPORTS_MIDI1 | AMW_ENDPOINT_SUPPORTS_MIDI2,
          endpointName: 'Synth',
          productInstanceId: 'PI',
          declaredFunctionBlockCount: 1,
          umpVersionMajor: 1,
          umpVersionMinor: 1,
          protocol: 2,
          functionBlocks: [
            block(
              0,
              MidiFunctionBlockDirection.bidirectional,
              count: 2,
              name: 'Main',
            ),
          ],
        );
        final ports = mapper.map(ump(endpoint));
        const groups = [
          MidiGroupInfo(group: 0, name: 'Main'),
          MidiGroupInfo(group: 1, name: 'Main'),
        ];
        const info = MidiEndpointInfo(
          name: 'Synth',
          productInstanceId: 'PI',
          supportsMidi1: true,
          supportsMidi2: true,
          functionBlockCount: 1,
          protocol: MidiProtocol.midi2,
        );
        expect(
          ports,
          equals([
            MidiPortInfo(
              id: const MidiPortId('winrt:umpin:ep'),
              deviceId: const MidiDeviceId('winrt:ump:ep'),
              name: 'Endpoint',
              manufacturer: 'Audanika',
              direction: MidiDirection.input,
              transport: MidiTransport.usb,
              protocol: MidiProtocol.midi2,
              groups: groups,
              functionBlocks: endpoint.functionBlocks,
              endpoint: info,
              capabilities: const MidiPortCapabilities(
                timestampsIn: true,
                ump: true,
                sysEx8: true,
              ),
              serialNumber: 'SN',
            ),
            MidiPortInfo(
              id: const MidiPortId('winrt:umpout:ep'),
              deviceId: const MidiDeviceId('winrt:ump:ep'),
              name: 'Endpoint',
              manufacturer: 'Audanika',
              direction: MidiDirection.output,
              transport: MidiTransport.usb,
              protocol: MidiProtocol.midi2,
              groups: groups,
              functionBlocks: endpoint.functionBlocks,
              endpoint: info,
              capabilities: const MidiPortCapabilities(
                scheduledSend: true,
                ump: true,
                sysEx8: true,
              ),
              serialNumber: 'SN',
            ),
          ]),
        );
        expect(
          ports.first.native,
          equals({
            'deviceName': 'Endpoint',
            'product': 'Endpoint',
            'driver': 'midi2',
            'windowsId': 'ep',
            'deviceInstanceId': 'SWD',
            'containerId': '{c}',
            'transportCode': 'KS',
            'purpose': 0,
            'nativeDataFormat': 2,
            'vendorId': 1,
            'productId': 2,
            'productInstanceId': 'PI',
          }),
        );
      });

      test('takes the product from the endpoint description', () {
        final port = mapper.map(
          ump(WindowsMidiEndpointRecord(description: 'Synth 3000')),
        );
        expect(port.first.native['product'], 'Synth 3000');
        expect(
          WindowsMidiPortMapper.driverMidi1,
          isNot(WindowsMidiPortMapper.driverMidi2),
        );
      });

      test('maps a UMP record without endpoint to both directions', () {
        const record = WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI2,
          id: 'ep',
          name: 'E',
        );
        expect([
          for (final port in mapper.map(record)) port.id.value,
        ], equals(['winrt:umpin:ep', 'winrt:umpout:ep']));
      });
    });

    group('directionsOf(endpoint)', () {
      test('follows the active function blocks', () {
        final cases = <List<MidiFunctionBlockInfo>, Set<MidiDirection>>{
          [block(0, MidiFunctionBlockDirection.input)]: {MidiDirection.output},
          [block(0, MidiFunctionBlockDirection.output)]: {MidiDirection.input},
          [block(0, MidiFunctionBlockDirection.reserved)]: {
            MidiDirection.input,
            MidiDirection.output,
          },
          [
            block(0, MidiFunctionBlockDirection.input),
            block(1, MidiFunctionBlockDirection.output, active: false),
          ]: {
            MidiDirection.output,
          },
          [
            block(0, MidiFunctionBlockDirection.input, active: false),
            block(1, MidiFunctionBlockDirection.output, active: false),
          ]: {
            MidiDirection.input,
            MidiDirection.output,
          },
        };
        for (final MapEntry(key: blocks, value: directions) in cases.entries) {
          expect(
            mapper.directionsOf(
              WindowsMidiEndpointRecord(functionBlocks: blocks),
            ),
            equals(directions),
            reason: '$blocks',
          );
        }
      });

      test('follows the group terminal blocks without function blocks', () {
        WindowsMidiEndpointRecord terminals(List<int> directions) =>
            WindowsMidiEndpointRecord(
              groupTerminalBlocks: [
                for (final direction in directions)
                  WindowsMidiGroupTerminalBlock(
                    number: 0,
                    direction: direction,
                    firstGroup: 0,
                    groupCount: 1,
                  ),
              ],
            );
        expect(
          [
            mapper.directionsOf(terminals([1])),
            mapper.directionsOf(terminals([2])),
            mapper.directionsOf(terminals([0])),
            mapper.directionsOf(WindowsMidiEndpointRecord()),
          ],
          equals([
            {MidiDirection.output},
            {MidiDirection.input},
            {MidiDirection.input, MidiDirection.output},
            {MidiDirection.input, MidiDirection.output},
          ]),
        );
      });
    });

    group('groupsOf(endpoint, direction)', () {
      test('names the groups after the first block by number', () {
        final endpoint = WindowsMidiEndpointRecord(
          functionBlocks: [
            block(
              1,
              MidiFunctionBlockDirection.bidirectional,
              first: 1,
              count: 2,
              name: 'Second',
            ),
            block(
              0,
              MidiFunctionBlockDirection.output,
              count: 2,
              name: 'First',
              active: false,
            ),
            block(
              2,
              MidiFunctionBlockDirection.input,
              first: 14,
              count: 4,
              name: 'Edge',
            ),
          ],
        );
        expect(
          mapper.groupsOf(endpoint, MidiDirection.input),
          equals(const [
            MidiGroupInfo(group: 0, name: 'First', isActive: false),
            MidiGroupInfo(group: 1, name: 'First', isActive: false),
            MidiGroupInfo(group: 2, name: 'Second'),
          ]),
        );
        expect(
          mapper.groupsOf(endpoint, MidiDirection.output),
          equals(const [
            MidiGroupInfo(group: 1, name: 'Second'),
            MidiGroupInfo(group: 2, name: 'Second'),
            MidiGroupInfo(group: 14, name: 'Edge'),
            MidiGroupInfo(group: 15, name: 'Edge'),
          ]),
        );
      });

      test('uses the group terminal blocks without function blocks', () {
        final endpoint = WindowsMidiEndpointRecord(
          groupTerminalBlocks: const [
            WindowsMidiGroupTerminalBlock(
              number: 0,
              name: 'In',
              direction: 1,
              firstGroup: 0,
              groupCount: 1,
            ),
            WindowsMidiGroupTerminalBlock(
              number: 1,
              name: 'Out',
              direction: 2,
              firstGroup: 1,
              groupCount: 1,
            ),
          ],
        );
        expect(
          mapper.groupsOf(endpoint, MidiDirection.output),
          equals(const [MidiGroupInfo(group: 0, name: 'In')]),
        );
        expect(
          mapper.groupsOf(endpoint, MidiDirection.input),
          equals(const [MidiGroupInfo(group: 1, name: 'Out')]),
        );
      });
    });

    group('protocolOf(endpoint)', () {
      test('prefers the stream configuration', () {
        expect(
          [
            mapper.protocolOf(WindowsMidiEndpointRecord(protocol: 2)),
            mapper.protocolOf(
              WindowsMidiEndpointRecord(
                protocol: 1,
                nativeDataFormat: 2,
                flags: AMW_ENDPOINT_SUPPORTS_MIDI2,
              ),
            ),
            mapper.protocolOf(
              WindowsMidiEndpointRecord(
                nativeDataFormat: 2,
                flags: AMW_ENDPOINT_SUPPORTS_MIDI2,
              ),
            ),
            mapper.protocolOf(
              WindowsMidiEndpointRecord(flags: AMW_ENDPOINT_SUPPORTS_MIDI2),
            ),
            mapper.protocolOf(WindowsMidiEndpointRecord(nativeDataFormat: 2)),
          ],
          equals([
            MidiProtocol.midi2,
            MidiProtocol.midi1,
            MidiProtocol.midi2,
            MidiProtocol.midi1,
            MidiProtocol.midi1,
          ]),
        );
      });
    });

    group('endpointInfoOf(endpoint)', () {
      test('is null when the endpoint declares nothing', () {
        expect(mapper.endpointInfoOf(WindowsMidiEndpointRecord()), isNull);
      });

      test('maps every declared field', () {
        final identity = MidiDeviceIdentity(
          manufacturerId: [0, 0, 1],
          familyId: 1,
          modelId: 2,
          softwareRevision: [0, 0, 0, 1],
        );
        expect(
          mapper.endpointInfoOf(
            WindowsMidiEndpointRecord(
              flags:
                  AMW_ENDPOINT_SUPPORTS_MIDI1 |
                  AMW_ENDPOINT_SUPPORTS_RX_JR |
                  AMW_ENDPOINT_SUPPORTS_TX_JR |
                  AMW_ENDPOINT_STATIC_BLOCKS |
                  AMW_ENDPOINT_RECEIVES_JR |
                  AMW_ENDPOINT_TRANSMITS_JR,
              endpointName: 'E',
              productInstanceId: 'P',
              declaredFunctionBlockCount: 3,
              umpVersionMajor: 1,
              umpVersionMinor: 2,
              protocol: 1,
              identity: identity,
            ),
          ),
          MidiEndpointInfo(
            name: 'E',
            productInstanceId: 'P',
            identity: identity,
            umpVersionMinor: 2,
            supportsMidi1: true,
            supportsMidi2: false,
            supportsRxJr: true,
            supportsTxJr: true,
            staticFunctionBlocks: true,
            functionBlockCount: 3,
            protocol: MidiProtocol.midi1,
            receiveJr: true,
            transmitJr: true,
          ),
        );
      });

      test('defaults the UMP version to 1.1 when none is declared', () {
        final info = mapper.endpointInfoOf(
          WindowsMidiEndpointRecord(endpointName: 'E', umpVersionMinor: 5),
        )!;
        expect([info.umpVersionMajor, info.umpVersionMinor], equals([1, 1]));
      });
    });

    group('transportOf(record)', () {
      test('classifies by purpose, transport code and ids', () {
        WindowsMidiPortRecord midi2({
          int purpose = 0,
          String code = '',
          String id = 'x',
        }) => WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI2,
          id: id,
          name: 'n',
          endpoint: WindowsMidiEndpointRecord(
            purpose: purpose,
            transportCode: code,
          ),
        );
        WindowsMidiPortRecord midi1(String id, [String instance = '']) =>
            WindowsMidiPortRecord(
              source: AMW_SOURCE_MIDI1_IN,
              id: id,
              name: 'n',
              deviceInstanceId: instance,
            );
        final cases = <WindowsMidiPortRecord, MidiTransport>{
          midi2(purpose: 100): MidiTransport.virtual,
          midi2(purpose: 400): MidiTransport.software,
          midi2(purpose: 500): MidiTransport.software,
          midi2(purpose: 510): MidiTransport.software,
          midi2(code: 'KSA'): MidiTransport.usb,
          midi2(code: 'ble10'): MidiTransport.bluetoothLe,
          midi2(code: 'BT'): MidiTransport.bluetoothLe,
          midi2(code: 'NET2UDP'): MidiTransport.network,
          midi2(code: 'RTP'): MidiTransport.network,
          midi2(code: 'XUDP'): MidiTransport.network,
          midi2(code: 'APP'): MidiTransport.virtual,
          midi2(code: 'VIRT'): MidiTransport.virtual,
          midi2(code: 'BLOOP'): MidiTransport.software,
          midi2(code: 'DIAG'): MidiTransport.software,
          midi2(code: 'GMSYNTH'): MidiTransport.software,
          midi2(code: 'ODD', id: 'midiu_ks_1'): MidiTransport.usb,
          midi2(id: 'MIDIU_BLE10_1'): MidiTransport.bluetoothLe,
          midi1(r'\\?\BTHLEDEVICE#x'): MidiTransport.bluetoothLe,
          midi1('MIDIU_VIRT_1'): MidiTransport.virtual,
          midi1('MIDIU_NET_1'): MidiTransport.network,
          midi1('MIDIU_RTP_1'): MidiTransport.network,
          midi1('MIDIU_DIAG_1'): MidiTransport.software,
          midi1('MIDIU_LOOP_1'): MidiTransport.software,
          midi1('MicrosoftGSWavetableSynth'): MidiTransport.software,
          midi1('x', r'USB\VID_1'): MidiTransport.usb,
          midi1(r'\\?\USB#VID_1'): MidiTransport.usb,
          midi1(r'\\?\SWD#MMDEVAPI#MIDII_1'): MidiTransport.unknown,
        };
        for (final MapEntry(key: record, value: transport) in cases.entries) {
          expect(mapper.transportOf(record), transport, reason: '$record');
        }
      });
    });
  });
}
