// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/src/shim/windows_midi_data_record.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsMidiDataRecord', () {
    group('WindowsMidiDataRecord(...)', () {
      test('copies the data and keeps it unmodifiable', () {
        final data = [0x90, 0x3C, 0x64];
        final record = WindowsMidiDataRecord(timeMicros: 5, data: data);
        data[0] = 0;
        expect(record.data, equals([0x90, 0x3C, 0x64]));
        expect(() => record.data[0] = 1, throwsUnsupportedError);
        expect(record.flags, 0);
        expect(record.isUmp, isFalse);
      });
    });

    group('isUmp, words', () {
      test('read the payload as little-endian words', () {
        final record = WindowsMidiDataRecord(
          timeMicros: 0,
          flags: 1,
          data: [0x64, 0x00, 0x90, 0x40, 0x00, 0x00, 0x00, 0xC8, 0x01],
        );
        expect(record.isUmp, isTrue);
        expect(record.words, equals([0x40900064, 0xC8000000]));
      });
    });

    group('==, hashCode', () {
      test('compare time, flags and data', () {
        WindowsMidiDataRecord record({
          int time = 1,
          int flags = 0,
          List<int> data = const [1],
        }) => WindowsMidiDataRecord(timeMicros: time, flags: flags, data: data);
        final base = record();
        expect(base, record());
        expect(base.hashCode, record().hashCode);
        expect(base == base, isTrue);
        expect(base == record(time: 2), isFalse);
        expect(base == record(flags: 1), isFalse);
        expect(base == record(data: [2]), isFalse);
      });
    });

    group('toString()', () {
      test('lists the fields', () {
        expect(
          WindowsMidiDataRecord(timeMicros: 7, data: [1, 2]).toString(),
          'WindowsMidiDataRecord(timeMicros: 7, flags: 0, data: [1, 2])',
        );
      });
    });
  });
}
