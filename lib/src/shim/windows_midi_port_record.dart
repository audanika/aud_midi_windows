// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'aud_midi_windows_bindings.g.dart';
import 'windows_midi_endpoint_record.dart';

// #############################################################################
/// A port as a watcher of the shim reports it (`src/aud_midi_windows.h`): a
/// WinRT MIDI 1.0 port, or a UMP endpoint of Windows MIDI Services.
final class WindowsMidiPortRecord {
  /// Creates a port record.
  ///
  /// - [source] the watcher that reports the port: [sourceMidi1In],
  ///   [sourceMidi1Out] or [sourceMidi2].
  /// - [id] the Windows device id, `DeviceInformation.Id` or the endpoint
  ///   device id.
  /// - [flags] the `AMW_PORT_*` bits.
  /// - [endpoint] what Windows MIDI Services reports about a UMP endpoint;
  ///   null for WinRT MIDI 1.0 ports.
  const WindowsMidiPortRecord({
    required this.source,
    required this.id,
    required this.name,
    this.flags = AMW_PORT_ENABLED,
    this.deviceInstanceId = '',
    this.containerId = '',
    this.endpoint,
  });

  // ...........................................................................
  /// Returns a copy with the given fields replaced.
  WindowsMidiPortRecord copyWith({
    String? name,
    int? flags,
    WindowsMidiEndpointRecord? endpoint,
  }) => WindowsMidiPortRecord(
    source: source,
    id: id,
    name: name ?? this.name,
    flags: flags ?? this.flags,
    deviceInstanceId: deviceInstanceId,
    containerId: containerId,
    endpoint: endpoint ?? this.endpoint,
  );

  // ...........................................................................
  /// The watcher that reports the port.
  final int source;

  /// The Windows device id of the port.
  final String id;

  /// The name of the port.
  final String name;

  /// The `AMW_PORT_*` bits.
  final int flags;

  /// The instance id of the device the port belongs to, e.g.
  /// `USB\VID_1C75&PID_0206&MI_01\...`; empty when unknown.
  final String deviceInstanceId;

  /// The container id of the physical device, e.g. `{8e1f...}`; empty when
  /// unknown.
  final String containerId;

  /// What Windows MIDI Services reports about the endpoint, or null.
  final WindowsMidiEndpointRecord? endpoint;

  /// Whether the device interface is enabled.
  bool get isEnabled => flags & AMW_PORT_ENABLED != 0;

  // ...........................................................................
  /// The watcher of WinRT MIDI 1.0 input ports.
  static const int sourceMidi1In = AMW_SOURCE_MIDI1_IN;

  /// The watcher of WinRT MIDI 1.0 output ports.
  static const int sourceMidi1Out = AMW_SOURCE_MIDI1_OUT;

  /// The watcher of the UMP endpoints of Windows MIDI Services.
  static const int sourceMidi2 = AMW_SOURCE_MIDI2;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowsMidiPortRecord &&
          other.source == source &&
          other.id == id &&
          other.name == name &&
          other.flags == flags &&
          other.deviceInstanceId == deviceInstanceId &&
          other.containerId == containerId &&
          other.endpoint == endpoint;

  @override
  int get hashCode => Object.hash(
    source,
    id,
    name,
    flags,
    deviceInstanceId,
    containerId,
    endpoint,
  );

  @override
  String toString() =>
      "WindowsMidiPortRecord(source: $source, id: '$id', name: '$name', "
      "flags: $flags, deviceInstanceId: '$deviceInstanceId', "
      "containerId: '$containerId', endpoint: $endpoint)";
}
