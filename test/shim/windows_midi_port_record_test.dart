// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:test/test.dart';

void main() {
  final endpoint = WindowsMidiEndpointRecord(transportCode: 'KS');
  final record = WindowsMidiPortRecord(
    source: WindowsMidiPortRecord.sourceMidi2,
    id: 'id',
    name: 'Synth',
    deviceInstanceId: 'USB\\VID',
    containerId: '{c}',
    endpoint: endpoint,
  );

  group('WindowsMidiPortRecord', () {
    group('WindowsMidiPortRecord(...)', () {
      test('defaults to an enabled port without endpoint', () {
        const plain = WindowsMidiPortRecord(
          source: WindowsMidiPortRecord.sourceMidi1In,
          id: 'id',
          name: 'In',
        );
        expect([
          plain.isEnabled,
          plain.deviceInstanceId,
          plain.containerId,
        ], equals([true, '', '']));
        expect(plain.endpoint, isNull);
      });
    });

    group('copyWith(...)', () {
      test('replaces the given fields', () {
        final other = WindowsMidiEndpointRecord(transportCode: 'BLE10');
        final copy = record.copyWith(name: 'New', flags: 0, endpoint: other);
        expect(copy.name, 'New');
        expect(copy.isEnabled, isFalse);
        expect(copy.endpoint, other);
        expect([
          copy.source,
          copy.id,
          copy.deviceInstanceId,
          copy.containerId,
        ], equals([record.source, 'id', 'USB\\VID', '{c}']));
        expect(record.copyWith(), record);
      });
    });

    group('source constants', () {
      test('match the AMW_SOURCE_* values', () {
        expect([
          WindowsMidiPortRecord.sourceMidi1In,
          WindowsMidiPortRecord.sourceMidi1Out,
          WindowsMidiPortRecord.sourceMidi2,
        ], equals([1, 2, 4]));
      });
    });

    group('==, hashCode', () {
      test('compare every field', () {
        final same = WindowsMidiPortRecord(
          source: WindowsMidiPortRecord.sourceMidi2,
          id: 'id',
          name: 'Synth',
          deviceInstanceId: 'USB\\VID',
          containerId: '{c}',
          endpoint: WindowsMidiEndpointRecord(transportCode: 'KS'),
        );
        expect(record, same);
        expect(record.hashCode, same.hashCode);
        expect(record == record, isTrue);
        for (final other in [
          WindowsMidiPortRecord(
            source: 1,
            id: 'id',
            name: 'Synth',
            deviceInstanceId: 'USB\\VID',
            containerId: '{c}',
            endpoint: endpoint,
          ),
          WindowsMidiPortRecord(
            source: 4,
            id: 'x',
            name: 'Synth',
            deviceInstanceId: 'USB\\VID',
            containerId: '{c}',
            endpoint: endpoint,
          ),
          record.copyWith(name: 'x'),
          record.copyWith(flags: 0),
          WindowsMidiPortRecord(
            source: 4,
            id: 'id',
            name: 'Synth',
            containerId: '{c}',
            endpoint: endpoint,
          ),
          WindowsMidiPortRecord(
            source: 4,
            id: 'id',
            name: 'Synth',
            deviceInstanceId: 'USB\\VID',
            endpoint: endpoint,
          ),
          const WindowsMidiPortRecord(
            source: 4,
            id: 'id',
            name: 'Synth',
            deviceInstanceId: 'USB\\VID',
            containerId: '{c}',
          ),
        ]) {
          expect(record == other, isFalse, reason: '$other');
        }
      });
    });

    group('toString()', () {
      test('lists the fields', () {
        expect(
          const WindowsMidiPortRecord(
            source: 1,
            id: 'id',
            name: 'In',
          ).toString(),
          "WindowsMidiPortRecord(source: 1, id: 'id', name: 'In', flags: 1, "
          "deviceInstanceId: '', containerId: '', endpoint: null)",
        );
      });
    });
  });
}
