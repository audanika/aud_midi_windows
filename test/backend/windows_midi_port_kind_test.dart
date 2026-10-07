// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/src/backend/windows_midi_port_kind.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsMidiPortKind', () {
    group('values', () {
      test('carry prefix, shim kind and direction', () {
        expect(
          [
            for (final kind in WindowsMidiPortKind.values)
              (kind.prefix, kind.shimKind, kind.direction),
          ],
          equals([
            ('in', 1, MidiDirection.input),
            ('out', 2, MidiDirection.output),
            ('umpin', 3, MidiDirection.input),
            ('umpout', 4, MidiDirection.output),
            ('vin', 5, MidiDirection.input),
            ('vout', 5, MidiDirection.output),
          ]),
        );
      });

      test('isUmp and isVirtual tell the port types apart', () {
        expect(
          [
            for (final kind in WindowsMidiPortKind.values)
              (kind.isUmp, kind.isVirtual),
          ],
          equals([
            (false, false),
            (false, false),
            (true, false),
            (true, false),
            (true, true),
            (true, true),
          ]),
        );
      });
    });

    group('nativeId(windowsId), portId(windowsId)', () {
      test('prefix the Windows id', () {
        expect(
          WindowsMidiPortKind.umpInput.nativeId(r'\\?\a:b'),
          r'umpin:\\?\a:b',
        );
        expect(
          WindowsMidiPortKind.midi1Output.portId('x'),
          const MidiPortId('winrt:out:x'),
        );
      });
    });

    group('parse(port)', () {
      test('returns kind and Windows id', () {
        for (final kind in WindowsMidiPortKind.values) {
          final parsed = WindowsMidiPortKind.parse(kind.portId('a:b'));
          expect(parsed?.kind, kind);
          expect(parsed?.windowsId, 'a:b');
        }
      });

      test('returns null for ports of other backends or prefixes', () {
        for (final port in const [
          MidiPortId('coremidi:in:x'),
          MidiPortId('winrt:x'),
          MidiPortId('winrt:other:x'),
        ]) {
          expect(WindowsMidiPortKind.parse(port), isNull, reason: '$port');
        }
      });
    });
  });
}
