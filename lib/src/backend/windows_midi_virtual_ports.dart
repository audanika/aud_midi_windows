// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../shim/aud_midi_windows_bindings.g.dart';
import '../shim/windows_midi_byte_writer.dart';
import '../shim/windows_midi_shim.dart';
import '../shim/windows_midi_shim_event.dart';
import '../shim/windows_midi_status.dart';
import 'windows_midi_port_kind.dart';
import 'windows_midi_port_mapper.dart';
import 'windows_midi_requests.dart';

// #############################################################################
/// Creates virtual ports as virtual devices of Windows MIDI Services
/// (app-to-app MIDI, `MidiVirtualDeviceManager`).
///
/// Each port is a device of its own with one function block. The app holds
/// its device side, an open UMP port; other apps see the client side as an
/// ordinary endpoint. Removing the port closes the device side, which
/// removes the device.
final class WindowsMidiVirtualPorts implements MidiVirtualPortsBackend {
  /// Creates the virtual port support on [shim].
  ///
  /// - [requests] pairs the requests with their completions.
  /// - [onCreated] registers a created port with the handle of its device
  ///   side and its product instance id.
  /// - [handleOf] returns the handle of an own port, or null.
  /// - [onRemoved] unregisters a removed port.
  /// - [timeout] the time [create] waits for Windows.
  /// - [random] makes the product instance ids of ports without a unique
  ///   id.
  WindowsMidiVirtualPorts({
    required this._shim,
    required this._requests,
    required this._onCreated,
    required this._handleOf,
    required this._onRemoved,
    this.timeout = const Duration(seconds: 10),
    Random? random,
  }) : _random = random ?? Random();

  // ...........................................................................
  @override
  Future<MidiPortInfo> create(MidiVirtualPortSpec spec) async {
    final productInstanceId = spec.uniqueId == null
        ? 'aud_midi-${_random.nextInt(1 << 32).toRadixString(16)}'
        : 'aud_midi-${spec.uniqueId}';
    final encoded = encode(spec, productInstanceId: productInstanceId);
    final completion = await _requests.run<WindowsMidiShimVirtualCreated>(
      send: (request) => _shim.virtualCreate(request: request, spec: encoded),
      timeout: timeout,
      onTimeout: () => const MidiNativeError(
        api: 'MidiVirtualDeviceManager.CreateVirtualDevice',
        code: WindowsMidiStatus.timeout,
      ),
      onLate: (late) {
        if (late.isSuccess) _closeQuietly(late.handle);
      },
    );
    WindowsMidiStatus.check(
      api: 'MidiVirtualDeviceManager.CreateVirtualDevice',
      status: completion.status,
      feature: 'virtual ports',
    );
    final port = _port(spec, completion.endpointId, productInstanceId);
    _onCreated(port, completion.handle, productInstanceId);
    return port;
  }

  @override
  Future<void> remove(MidiPortId port) async {
    final handle = _handleOf(port);
    if (handle == null) throw MidiPortGone(port);
    _onRemoved(port);
    _shim.closePort(handle);
  }

  // ...........................................................................
  /// The time [create] waits for Windows.
  final Duration timeout;

  // ...........................................................................
  /// Returns the specification the shim expects for [spec]
  /// (`amw_virtual_create`): one function block over the groups of [spec]
  /// that receives for an input and sends for an output.
  static Uint8List encode(
    MidiVirtualPortSpec spec, {
    required String productInstanceId,
  }) {
    final (first, count) = _groupRange(spec);
    final input = spec.direction == MidiDirection.input;
    final out = WindowsMidiByteWriter()
      ..string(spec.name)
      ..string(spec.model.isEmpty ? 'A virtual port of aud_midi' : spec.model)
      ..string(spec.manufacturer.isEmpty ? 'aud_midi' : spec.manufacturer)
      ..string(productInstanceId)
      ..u32(
        (input ? AMW_VIRTUAL_RECEIVE : 0) |
            (spec.protocol == MidiProtocol.midi2 ? AMW_VIRTUAL_MIDI2 : 0),
      )
      ..u8(first)
      ..u8(count)
      ..u8(input ? 1 : 2);
    return out.toBytes();
  }

  // ...........................................................................
  static (int, int) _groupRange(MidiVirtualPortSpec spec) {
    if (spec.groups.isEmpty) return (0, 1);
    final first = spec.groups.reduce(min);
    final last = spec.groups.reduce(max);
    return (first, last - first + 1);
  }

  MidiPortInfo _port(
    MidiVirtualPortSpec spec,
    String endpointId,
    String productInstanceId,
  ) {
    final input = spec.direction == MidiDirection.input;
    final kind = input
        ? WindowsMidiPortKind.virtualInput
        : WindowsMidiPortKind.virtualOutput;
    final (first, count) = _groupRange(spec);
    return MidiPortInfo(
      id: kind.portId(endpointId),
      deviceId: MidiDeviceId.of(
        backend: WindowsMidiPortKind.backend,
        nativeId: 'ump:$endpointId',
      ),
      name: spec.name,
      manufacturer: spec.manufacturer,
      direction: spec.direction,
      transport: MidiTransport.virtual,
      protocol: spec.protocol,
      isVirtual: true,
      isOwn: true,
      groups: [
        for (var group = first; group < first + count; group++)
          MidiGroupInfo(group: group, name: spec.name),
      ],
      capabilities: MidiPortCapabilities(
        timestampsIn: input,
        scheduledSend: !input,
        ump: true,
      ),
      native: {
        MidiPortRegistry.deviceNameKey: spec.name,
        MidiPortRegistry.productKey: spec.model.isEmpty
            ? spec.name
            : spec.model,
        MidiPortRegistry.driverKey: WindowsMidiPortMapper.driverMidi2,
        'windowsId': endpointId,
        'productInstanceId': productInstanceId,
      },
    );
  }

  void _closeQuietly(int handle) {
    try {
      _shim.closePort(handle);
    } on MidiException {
      // The device side is gone already.
    }
  }

  final WindowsMidiShim _shim;
  final WindowsMidiRequests _requests;
  final void Function(MidiPortInfo port, int handle, String productInstanceId)
  _onCreated;
  final int? Function(MidiPortId port) _handleOf;
  final void Function(MidiPortId port) _onRemoved;
  final Random _random;
}
