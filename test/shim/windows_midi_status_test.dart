// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_status.dart';
import 'package:test/test.dart';

void main() {
  const port = MidiPortId('winrt:in:id');

  group('WindowsMidiStatus', () {
    group('exception(...)', () {
      test('maps a missing feature to MidiUnsupported', () {
        expect(
          WindowsMidiStatus.exception(api: 'a', status: AMW_E_UNSUPPORTED),
          isA<MidiUnsupported>().having((e) => e.feature, 'feature', 'a'),
        );
        expect(
          WindowsMidiStatus.exception(
            api: 'a',
            status: AMW_E_UNSUPPORTED,
            feature: 'f',
          ),
          isA<MidiUnsupported>().having((e) => e.feature, 'feature', 'f'),
        );
      });

      test('maps a denied access to MidiPermissionDenied', () {
        expect(
          WindowsMidiStatus.exception(api: 'a', status: AMW_E_ACCESS_DENIED),
          isA<MidiPermissionDenied>().having(
            (e) => e.permission,
            'permission',
            MidiPermission.midi,
          ),
        );
        expect(
          WindowsMidiStatus.exception(
            api: 'a',
            status: AMW_E_ACCESS_DENIED,
            permission: MidiPermission.bluetooth,
          ),
          isA<MidiPermissionDenied>().having(
            (e) => e.permission,
            'permission',
            MidiPermission.bluetooth,
          ),
        );
      });

      test('maps a closed or unknown port to MidiPortGone', () {
        for (final status in [AMW_E_CLOSED, AMW_E_UNKNOWN_HANDLE]) {
          expect(
            WindowsMidiStatus.exception(api: 'a', status: status, port: port),
            isA<MidiPortGone>().having((e) => e.port, 'port', port),
          );
          expect(
            WindowsMidiStatus.exception(api: 'a', status: status),
            isA<MidiNativeError>().having((e) => e.code, 'code', status),
          );
        }
      });

      test('maps everything else to MidiNativeError', () {
        expect(
          WindowsMidiStatus.exception(api: 'a', status: AMW_E_SEND_FAILED),
          isA<MidiNativeError>()
              .having((e) => e.api, 'api', 'a')
              .having((e) => e.code, 'code', AMW_E_SEND_FAILED),
        );
      });
    });

    group('check(...)', () {
      test('passes success statuses', () {
        WindowsMidiStatus.check(api: 'a', status: 0);
        WindowsMidiStatus.check(api: 'a', status: 1);
      });

      test('throws the exception of a failure', () {
        expect(
          () => WindowsMidiStatus.check(
            api: 'a',
            status: AMW_E_CLOSED,
            port: port,
            permission: MidiPermission.bluetooth,
            feature: 'f',
          ),
          throwsA(isA<MidiPortGone>()),
        );
      });
    });

    group('hex(status)', () {
      test('prints eight hex digits', () {
        expect([
          WindowsMidiStatus.hex(AMW_E_ACCESS_DENIED),
          WindowsMidiStatus.hex(0),
          WindowsMidiStatus.hex(WindowsMidiStatus.timeout),
        ], equals(['0x80070005', '0x00000000', '0x800705b4']));
      });
    });
  });
}
