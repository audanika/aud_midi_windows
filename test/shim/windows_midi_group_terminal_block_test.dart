// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:test/test.dart';

void main() {
  const block = WindowsMidiGroupTerminalBlock(
    number: 1,
    name: 'Terminal',
    direction: WindowsMidiGroupTerminalBlock.directionInput,
    protocol: 0x11,
    firstGroup: 2,
    groupCount: 3,
  );

  group('WindowsMidiGroupTerminalBlock', () {
    group('WindowsMidiGroupTerminalBlock(...)', () {
      test('defaults to a bidirectional block without name', () {
        const plain = WindowsMidiGroupTerminalBlock(
          number: 0,
          firstGroup: 0,
          groupCount: 1,
        );
        expect(
          [plain.name, plain.direction, plain.protocol],
          equals(['', WindowsMidiGroupTerminalBlock.directionBidirectional, 0]),
        );
      });
    });

    group('==, hashCode', () {
      test('compare every field', () {
        const same = WindowsMidiGroupTerminalBlock(
          number: 1,
          name: 'Terminal',
          direction: WindowsMidiGroupTerminalBlock.directionInput,
          protocol: 0x11,
          firstGroup: 2,
          groupCount: 3,
        );
        expect(block, same);
        expect(block.hashCode, same.hashCode);
        expect(block == block, isTrue);
        for (final other in const [
          WindowsMidiGroupTerminalBlock(
            number: 2,
            name: 'Terminal',
            direction: 1,
            protocol: 0x11,
            firstGroup: 2,
            groupCount: 3,
          ),
          WindowsMidiGroupTerminalBlock(
            number: 1,
            direction: 1,
            protocol: 0x11,
            firstGroup: 2,
            groupCount: 3,
          ),
          WindowsMidiGroupTerminalBlock(
            number: 1,
            name: 'Terminal',
            direction: 2,
            protocol: 0x11,
            firstGroup: 2,
            groupCount: 3,
          ),
          WindowsMidiGroupTerminalBlock(
            number: 1,
            name: 'Terminal',
            direction: 1,
            firstGroup: 2,
            groupCount: 3,
          ),
          WindowsMidiGroupTerminalBlock(
            number: 1,
            name: 'Terminal',
            direction: 1,
            protocol: 0x11,
            firstGroup: 3,
            groupCount: 3,
          ),
          WindowsMidiGroupTerminalBlock(
            number: 1,
            name: 'Terminal',
            direction: 1,
            protocol: 0x11,
            firstGroup: 2,
            groupCount: 4,
          ),
        ]) {
          expect(block == other, isFalse, reason: '$other');
        }
      });
    });

    group('toString()', () {
      test('lists the fields', () {
        expect(
          block.toString(),
          "WindowsMidiGroupTerminalBlock(number: 1, name: 'Terminal', "
          'direction: 1, protocol: 17, firstGroup: 2, groupCount: 3)',
        );
      });
    });
  });
}
