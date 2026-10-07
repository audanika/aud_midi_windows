// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../shim/aud_midi_windows_bindings.g.dart';
import '../shim/windows_midi_endpoint_record.dart';
import '../shim/windows_midi_group_terminal_block.dart';
import '../shim/windows_midi_port_record.dart';
import 'windows_midi_port_kind.dart';

// #############################################################################
/// Turns the port records of the shim into the ports of the aud_midi family.
///
/// A WinRT MIDI 1.0 port becomes one byte port on a synthetic one-port
/// device. A UMP endpoint of Windows MIDI Services becomes an input and an
/// output UMP port on one device, or only one of them when its function
/// blocks or group terminal blocks point one way.
final class WindowsMidiPortMapper {
  /// Creates a mapper.
  const WindowsMidiPortMapper();

  // ...........................................................................
  /// Returns the ports of [record].
  List<MidiPortInfo> map(WindowsMidiPortRecord record) =>
      switch (record.source) {
        AMW_SOURCE_MIDI1_IN => [
          _bytePort(record, WindowsMidiPortKind.midi1Input),
        ],
        AMW_SOURCE_MIDI1_OUT => [
          _bytePort(record, WindowsMidiPortKind.midi1Output),
        ],
        _ => _umpPorts(record, record.endpoint ?? WindowsMidiEndpointRecord()),
      };

  /// Returns how Windows reaches the port of [record].
  MidiTransport transportOf(WindowsMidiPortRecord record) {
    final endpoint = record.endpoint;
    if (endpoint != null) {
      final transport =
          _transportOfPurpose(endpoint.purpose) ??
          _transportOfCode(endpoint.transportCode.toUpperCase());
      if (transport != null) return transport;
    }
    return _transportOfIds(
      '${record.id}|${record.deviceInstanceId}'.toUpperCase(),
    );
  }

  /// Returns the directions, seen from the app, of the ports of [endpoint].
  Set<MidiDirection> directionsOf(WindowsMidiEndpointRecord endpoint) {
    final blocks = endpoint.functionBlocks;
    if (blocks.isNotEmpty) {
      final active = blocks.where((block) => block.isActive).toList();
      return {
        for (final block in active.isEmpty ? blocks : active)
          ..._blockDirections(block.direction),
      };
    }
    final terminals = endpoint.groupTerminalBlocks;
    if (terminals.isNotEmpty) {
      return {
        for (final block in terminals) ..._terminalDirections(block.direction),
      };
    }
    return _both;
  }

  /// Returns the groups of [endpoint] that carry messages in [direction],
  /// seen from the app, named after their blocks.
  List<MidiGroupInfo> groupsOf(
    WindowsMidiEndpointRecord endpoint,
    MidiDirection direction,
  ) {
    final groups = <int, MidiGroupInfo>{};
    void add(int first, int count, String name, bool isActive) {
      for (var group = first; group < first + count && group < 16; group++) {
        groups.putIfAbsent(
          group,
          () => MidiGroupInfo(group: group, name: name, isActive: isActive),
        );
      }
    }

    final blocks = [...endpoint.functionBlocks]
      ..sort((a, b) => a.number.compareTo(b.number));
    for (final block in blocks) {
      if (!_blockDirections(block.direction).contains(direction)) continue;
      add(block.firstGroup, block.groupCount, block.name, block.isActive);
    }
    if (blocks.isEmpty) {
      for (final block in endpoint.groupTerminalBlocks) {
        if (!_terminalDirections(block.direction).contains(direction)) {
          continue;
        }
        add(block.firstGroup, block.groupCount, block.name, true);
      }
    }
    return [for (final group in groups.keys.toList()..sort()) groups[group]!];
  }

  /// Returns the protocol [endpoint] speaks: the one of its stream
  /// configuration, else MIDI 2.0 for UMP devices that support it.
  MidiProtocol protocolOf(WindowsMidiEndpointRecord endpoint) =>
      switch (endpoint.protocol) {
        2 => MidiProtocol.midi2,
        1 => MidiProtocol.midi1,
        _ =>
          endpoint.isUmpNative && endpoint.supportsMidi2
              ? MidiProtocol.midi2
              : MidiProtocol.midi1,
      };

  /// Returns what [endpoint] declares about itself, or null when it
  /// declares nothing, e.g. a MIDI 1.0 device behind Windows MIDI Services.
  MidiEndpointInfo? endpointInfoOf(WindowsMidiEndpointRecord endpoint) {
    if (!endpoint.supportsMidi1 &&
        !endpoint.supportsMidi2 &&
        endpoint.endpointName.isEmpty) {
      return null;
    }
    final declaresVersion = endpoint.umpVersionMajor != 0;
    return MidiEndpointInfo(
      name: endpoint.endpointName,
      productInstanceId: endpoint.productInstanceId,
      identity: endpoint.identity,
      umpVersionMajor: declaresVersion ? endpoint.umpVersionMajor : 1,
      umpVersionMinor: declaresVersion ? endpoint.umpVersionMinor : 1,
      supportsMidi1: endpoint.supportsMidi1,
      supportsMidi2: endpoint.supportsMidi2,
      supportsRxJr: endpoint.supportsRxJr,
      supportsTxJr: endpoint.supportsTxJr,
      staticFunctionBlocks: endpoint.staticFunctionBlocks,
      functionBlockCount: endpoint.declaredFunctionBlockCount,
      protocol: protocolOf(endpoint),
      receiveJr: endpoint.receivesJr,
      transmitJr: endpoint.transmitsJr,
    );
  }

  // ...........................................................................
  /// The driver of WinRT MIDI 1.0 ports in [MidiPortInfo.native].
  static const String driverMidi1 = 'winrt';

  /// The driver of Windows MIDI Services ports in [MidiPortInfo.native].
  static const String driverMidi2 = 'midi2';

  // ...........................................................................
  static const Set<MidiDirection> _both = {
    MidiDirection.input,
    MidiDirection.output,
  };

  MidiPortInfo _bytePort(
    WindowsMidiPortRecord record,
    WindowsMidiPortKind kind,
  ) {
    final transport = transportOf(record);
    return MidiPortInfo(
      id: kind.portId(record.id),
      deviceId: MidiDeviceId.of(
        backend: WindowsMidiPortKind.backend,
        nativeId: kind.nativeId(record.id),
      ),
      name: record.name,
      direction: kind.direction,
      transport: transport,
      state: _state(record),
      isVirtual: transport == MidiTransport.virtual,
      capabilities: MidiPortCapabilities(
        timestampsIn: kind.direction == MidiDirection.input,
      ),
      native: _native(record),
    );
  }

  List<MidiPortInfo> _umpPorts(
    WindowsMidiPortRecord record,
    WindowsMidiEndpointRecord endpoint,
  ) {
    final directions = directionsOf(endpoint);
    return [
      for (final kind in const [
        WindowsMidiPortKind.umpInput,
        WindowsMidiPortKind.umpOutput,
      ])
        if (directions.contains(kind.direction))
          _umpPort(record, endpoint, kind),
    ];
  }

  MidiPortInfo _umpPort(
    WindowsMidiPortRecord record,
    WindowsMidiEndpointRecord endpoint,
    WindowsMidiPortKind kind,
  ) {
    final transport = transportOf(record);
    final input = kind.direction == MidiDirection.input;
    return MidiPortInfo(
      id: kind.portId(record.id),
      deviceId: MidiDeviceId.of(
        backend: WindowsMidiPortKind.backend,
        nativeId: 'ump:${record.id}',
      ),
      name: record.name,
      manufacturer: endpoint.manufacturer,
      direction: kind.direction,
      transport: transport,
      protocol: protocolOf(endpoint),
      state: _state(record),
      isVirtual: transport == MidiTransport.virtual,
      groups: groupsOf(endpoint, kind.direction),
      functionBlocks: endpoint.functionBlocks,
      endpoint: endpointInfoOf(endpoint),
      capabilities: MidiPortCapabilities(
        timestampsIn: input,
        scheduledSend: !input,
        ump: true,
        sysEx8: endpoint.isUmpNative,
      ),
      serialNumber: endpoint.serialNumber,
      native: _native(record),
    );
  }

  MidiPortState _state(WindowsMidiPortRecord record) =>
      record.isEnabled ? MidiPortState.connected : MidiPortState.offline;

  Map<String, Object?> _native(WindowsMidiPortRecord record) {
    final endpoint = record.endpoint;
    final description = endpoint?.description ?? '';
    return {
      MidiPortRegistry.deviceNameKey: record.name,
      MidiPortRegistry.productKey: description.isEmpty
          ? record.name
          : description,
      MidiPortRegistry.driverKey: endpoint == null ? driverMidi1 : driverMidi2,
      'windowsId': record.id,
      'deviceInstanceId': record.deviceInstanceId,
      'containerId': record.containerId,
      if (endpoint != null) ...{
        'transportCode': endpoint.transportCode,
        'purpose': endpoint.purpose,
        'nativeDataFormat': endpoint.nativeDataFormat,
        'vendorId': endpoint.vendorId,
        'productId': endpoint.productId,
        'productInstanceId': endpoint.productInstanceId,
      },
    };
  }

  static Set<MidiDirection> _blockDirections(
    MidiFunctionBlockDirection direction,
  ) => switch (direction) {
    // A block that receives is a destination of the app, and the reverse.
    MidiFunctionBlockDirection.input => const {MidiDirection.output},
    MidiFunctionBlockDirection.output => const {MidiDirection.input},
    _ => _both,
  };

  static Set<MidiDirection> _terminalDirections(int direction) =>
      switch (direction) {
        WindowsMidiGroupTerminalBlock.directionInput => const {
          MidiDirection.output,
        },
        WindowsMidiGroupTerminalBlock.directionOutput => const {
          MidiDirection.input,
        },
        _ => _both,
      };

  static MidiTransport? _transportOfPurpose(int purpose) => switch (purpose) {
    WindowsMidiEndpointRecord.purposeVirtualDeviceResponder =>
      MidiTransport.virtual,
    WindowsMidiEndpointRecord.purposeGeneralMidiSynth ||
    WindowsMidiEndpointRecord.purposeDiagnosticLoopback ||
    WindowsMidiEndpointRecord.purposeDiagnosticPing => MidiTransport.software,
    _ => null,
  };

  static MidiTransport? _transportOfCode(String code) {
    if (code.isEmpty) return null;
    if (code.startsWith('KS')) return MidiTransport.usb;
    if (code.startsWith('BLE') || code.startsWith('BT')) {
      return MidiTransport.bluetoothLe;
    }
    if (code.startsWith('NET') ||
        code.startsWith('RTP') ||
        code.contains('UDP')) {
      return MidiTransport.network;
    }
    if (code.startsWith('APP') || code.startsWith('VIRT')) {
      return MidiTransport.virtual;
    }
    if (code.contains('LOOP') ||
        code.startsWith('DIAG') ||
        code.contains('SYNTH')) {
      return MidiTransport.software;
    }
    return null;
  }

  static MidiTransport _transportOfIds(String ids) {
    if (ids.contains('BTHLE') || ids.contains('MIDIU_BLE')) {
      return MidiTransport.bluetoothLe;
    }
    if (ids.contains('MIDIU_APP') || ids.contains('MIDIU_VIRT')) {
      return MidiTransport.virtual;
    }
    if (ids.contains('MIDIU_NET') || ids.contains('MIDIU_RTP')) {
      return MidiTransport.network;
    }
    if (ids.contains('MIDIU_DIAG') ||
        ids.contains('MIDIU_LOOP') ||
        ids.contains('SYNTH')) {
      return MidiTransport.software;
    }
    if (ids.contains('MIDIU_KS') ||
        ids.contains('USB\\') ||
        ids.contains('USB#')) {
      return MidiTransport.usb;
    }
    return MidiTransport.unknown;
  }
}
