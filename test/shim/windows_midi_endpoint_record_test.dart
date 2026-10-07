// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:test/test.dart';

void main() {
  final identity = MidiDeviceIdentity(
    manufacturerId: [0, 0x21, 9],
    familyId: 257,
    modelId: 515,
    softwareRevision: [5, 6, 7, 8],
  );
  const block = MidiFunctionBlockInfo(
    number: 0,
    name: 'Main',
    direction: MidiFunctionBlockDirection.bidirectional,
    firstGroup: 0,
    groupCount: 2,
  );
  const terminal = WindowsMidiGroupTerminalBlock(
    number: 1,
    firstGroup: 0,
    groupCount: 1,
  );

  WindowsMidiEndpointRecord full() => WindowsMidiEndpointRecord(
    purpose: 500,
    nativeDataFormat: 2,
    transportCode: 'KS',
    manufacturer: 'Audanika',
    serialNumber: 'SN',
    description: 'Synth',
    vendorId: 1,
    productId: 2,
    flags: 3,
    endpointName: 'Endpoint',
    productInstanceId: 'PI',
    declaredFunctionBlockCount: 1,
    umpVersionMajor: 1,
    umpVersionMinor: 1,
    protocol: 2,
    identity: identity,
    functionBlocks: [block],
    groupTerminalBlocks: [terminal],
  );

  group('WindowsMidiEndpointRecord', () {
    group('WindowsMidiEndpointRecord(...)', () {
      test('defaults to an empty record', () {
        final record = WindowsMidiEndpointRecord();
        expect(record.toString(), startsWith('WindowsMidiEndpointRecord('));
        expect([
          record.purpose,
          record.transportCode,
          record.identity,
          record.functionBlocks,
          record.groupTerminalBlocks,
        ], equals([0, '', null, <Object>[], <Object>[]]));
      });

      test('copies the block lists and keeps them unmodifiable', () {
        final blocks = [block];
        final record = WindowsMidiEndpointRecord(functionBlocks: blocks);
        blocks.clear();
        expect(record.functionBlocks, equals([block]));
        expect(() => record.functionBlocks.clear(), throwsUnsupportedError);
        expect(
          () => record.groupTerminalBlocks.clear(),
          throwsUnsupportedError,
        );
      });
    });

    group('flag getters', () {
      test('read the AMW_ENDPOINT_* bits', () {
        final getters = <String, bool Function(WindowsMidiEndpointRecord)>{
          'supportsMidi1': (r) => r.supportsMidi1,
          'supportsMidi2': (r) => r.supportsMidi2,
          'supportsRxJr': (r) => r.supportsRxJr,
          'supportsTxJr': (r) => r.supportsTxJr,
          'staticFunctionBlocks': (r) => r.staticFunctionBlocks,
          'isMultiClient': (r) => r.isMultiClient,
          'receivesJr': (r) => r.receivesJr,
          'transmitsJr': (r) => r.transmitsJr,
          'isDiscoveryComplete': (r) => r.isDiscoveryComplete,
        };
        const flags = [
          AMW_ENDPOINT_SUPPORTS_MIDI1,
          AMW_ENDPOINT_SUPPORTS_MIDI2,
          AMW_ENDPOINT_SUPPORTS_RX_JR,
          AMW_ENDPOINT_SUPPORTS_TX_JR,
          AMW_ENDPOINT_STATIC_BLOCKS,
          AMW_ENDPOINT_MULTI_CLIENT,
          AMW_ENDPOINT_RECEIVES_JR,
          AMW_ENDPOINT_TRANSMITS_JR,
          AMW_ENDPOINT_DISCOVERY_COMPLETE,
        ];
        final names = getters.keys.toList();
        for (var i = 0; i < flags.length; i++) {
          final set = WindowsMidiEndpointRecord(flags: flags[i]);
          expect(
            [for (final name in names) getters[name]!(set)],
            equals([for (var j = 0; j < flags.length; j++) j == i]),
            reason: names[i],
          );
        }
      });

      test('isUmpNative is true for the UMP data format only', () {
        expect([
          for (final format in [0, 1, 2])
            WindowsMidiEndpointRecord(nativeDataFormat: format).isUmpNative,
        ], equals([false, false, true]));
      });
    });

    group('constants', () {
      test('match the Windows MIDI Services enums', () {
        expect([
          WindowsMidiEndpointRecord.nativeDataFormatMidi1,
          WindowsMidiEndpointRecord.nativeDataFormatUmp,
          WindowsMidiEndpointRecord.purposeNormal,
          WindowsMidiEndpointRecord.purposeVirtualDeviceResponder,
          WindowsMidiEndpointRecord.purposeGeneralMidiSynth,
          WindowsMidiEndpointRecord.purposeDiagnosticLoopback,
          WindowsMidiEndpointRecord.purposeDiagnosticPing,
        ], equals([1, 2, 0, 100, 400, 500, 510]));
      });
    });

    group('==, hashCode', () {
      test('compare every field', () {
        final base = full();
        expect(base, full());
        expect(base.hashCode, full().hashCode);
        expect(base == base, isTrue);
        final variants = <WindowsMidiEndpointRecord>[
          WindowsMidiEndpointRecord(),
        ];
        WindowsMidiEndpointRecord change({
          int purpose = 500,
          int nativeDataFormat = 2,
          String transportCode = 'KS',
          String manufacturer = 'Audanika',
          String serialNumber = 'SN',
          String description = 'Synth',
          int vendorId = 1,
          int productId = 2,
          int flags = 3,
          String endpointName = 'Endpoint',
          String productInstanceId = 'PI',
          int declaredFunctionBlockCount = 1,
          int umpVersionMajor = 1,
          int umpVersionMinor = 1,
          int protocol = 2,
          MidiDeviceIdentity? identityValue,
          bool noIdentity = false,
          List<MidiFunctionBlockInfo>? blocks,
          List<WindowsMidiGroupTerminalBlock>? terminals,
        }) => WindowsMidiEndpointRecord(
          purpose: purpose,
          nativeDataFormat: nativeDataFormat,
          transportCode: transportCode,
          manufacturer: manufacturer,
          serialNumber: serialNumber,
          description: description,
          vendorId: vendorId,
          productId: productId,
          flags: flags,
          endpointName: endpointName,
          productInstanceId: productInstanceId,
          declaredFunctionBlockCount: declaredFunctionBlockCount,
          umpVersionMajor: umpVersionMajor,
          umpVersionMinor: umpVersionMinor,
          protocol: protocol,
          identity: noIdentity ? null : identityValue ?? identity,
          functionBlocks: blocks ?? [block],
          groupTerminalBlocks: terminals ?? [terminal],
        );
        expect(change(), base);
        variants.addAll([
          change(purpose: 0),
          change(nativeDataFormat: 1),
          change(transportCode: 'BLE10'),
          change(manufacturer: 'X'),
          change(serialNumber: 'X'),
          change(description: 'X'),
          change(vendorId: 9),
          change(productId: 9),
          change(flags: 0),
          change(endpointName: 'X'),
          change(productInstanceId: 'X'),
          change(declaredFunctionBlockCount: 2),
          change(umpVersionMajor: 2),
          change(umpVersionMinor: 2),
          change(protocol: 1),
          change(noIdentity: true),
          change(blocks: []),
          change(terminals: []),
        ]);
        for (final variant in variants) {
          expect(base == variant, isFalse, reason: '$variant');
        }
      });
    });

    group('toString()', () {
      test('lists the fields', () {
        expect(
          WindowsMidiEndpointRecord(transportCode: 'KS').toString(),
          'WindowsMidiEndpointRecord(purpose: 0, nativeDataFormat: 0, '
          "transportCode: 'KS', manufacturer: '', serialNumber: '', "
          "description: '', vendorId: 0, productId: 0, flags: 0, "
          "endpointName: '', productInstanceId: '', "
          'declaredFunctionBlockCount: 0, umpVersion: 0.0, protocol: 0, '
          'identity: null, functionBlocks: [], groupTerminalBlocks: [])',
        );
      });
    });
  });
}
