// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'aud_midi_windows_bindings.g.dart';

// #############################################################################
/// Maps the status codes of the shim (`AMW_*` and Windows HRESULTs) to the
/// exceptions of the aud_midi family.
abstract final class WindowsMidiStatus {
  // ...........................................................................
  /// Returns the exception for the failed [status] of the call [api].
  ///
  /// - [port] the port the call concerned; a closed or unknown port becomes
  ///   [MidiPortGone].
  /// - [permission] the permission an access denial concerns.
  /// - [feature] the name of a missing feature; defaults to [api].
  static MidiException exception({
    required String api,
    required int status,
    MidiPortId? port,
    MidiPermission permission = MidiPermission.midi,
    String? feature,
  }) => switch (status) {
    AMW_E_UNSUPPORTED => MidiUnsupported(feature ?? api),
    AMW_E_ACCESS_DENIED => MidiPermissionDenied(permission),
    AMW_E_CLOSED ||
    AMW_E_UNKNOWN_HANDLE when port != null => MidiPortGone(port),
    _ => MidiNativeError(api: api, code: status),
  };

  /// Throws the exception of [status] when it is a failure, a negative
  /// value; see [exception].
  static void check({
    required String api,
    required int status,
    MidiPortId? port,
    MidiPermission permission = MidiPermission.midi,
    String? feature,
  }) {
    if (status >= 0) return;
    throw exception(
      api: api,
      status: status,
      port: port,
      permission: permission,
      feature: feature,
    );
  }

  /// Returns [status] as eight hex digits, e.g. `0x80070005`.
  static String hex(int status) =>
      '0x${(status & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

  // ...........................................................................
  /// HRESULT_FROM_WIN32(ERROR_TIMEOUT), the status of a request the shim
  /// did not complete in time.
  static const int timeout = -2147023436;
}
