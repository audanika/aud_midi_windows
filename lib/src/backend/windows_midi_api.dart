// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The Windows MIDI API a `WindowsMidiBackend` uses.
enum WindowsMidiApi {
  /// Windows MIDI Services when present and usable, WinRT MIDI 1.0
  /// otherwise; both in hybrid legacy mode, where devices with MIDI 1.0
  /// drivers are reachable through WinRT MIDI 1.0 only.
  auto,

  /// WinRT MIDI 1.0 (`Windows.Devices.Midi`) only: byte ports, no virtual
  /// ports, no scheduling.
  midi1,

  /// Windows MIDI Services (`Windows.Devices.Midi2`) only; the backend
  /// fails to start without it.
  midi2,
}
