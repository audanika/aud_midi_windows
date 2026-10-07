// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The Windows backend of the aud_midi family: WinRT MIDI 1.0
/// (`Windows.Devices.Midi`) and, when present, Windows MIDI Services
/// (`Windows.Devices.Midi2`) through a C++/WinRT shim, Bluetooth LE MIDI
/// pairing and DNS-SD advertising for network sessions.
library;

export 'src/advertiser/windows_dns_sd_api.dart';
export 'src/advertiser/windows_midi_service_advertiser.dart';
export 'src/advertiser/windows_midi_service_registration.dart';
export 'src/backend/windows_midi_api.dart';
export 'src/backend/windows_midi_backend.dart';
export 'src/backend/windows_midi_bluetooth.dart';
export 'src/backend/windows_midi_virtual_ports.dart';
export 'src/shim/windows_midi_endpoint_record.dart';
export 'src/shim/windows_midi_fake_shim.dart';
export 'src/shim/windows_midi_group_terminal_block.dart';
export 'src/shim/windows_midi_port_record.dart';
export 'src/shim/windows_midi_shim.dart';
export 'src/shim/windows_midi_shim_event.dart';
