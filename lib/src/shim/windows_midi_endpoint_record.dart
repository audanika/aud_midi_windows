// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'aud_midi_windows_bindings.g.dart';
import 'windows_midi_group_terminal_block.dart';
import 'windows_midi_list_equality.dart';

// #############################################################################
/// What Windows MIDI Services reports about a UMP endpoint: the endpoint part
/// of a port record of the shim (`src/aud_midi_windows.h`).
final class WindowsMidiEndpointRecord {
  /// Creates an endpoint record from copies of [functionBlocks] and
  /// [groupTerminalBlocks].
  ///
  /// - [purpose] the MidiEndpointDevicePurpose value, e.g. 500 for the
  ///   diagnostic loopback endpoints.
  /// - [nativeDataFormat] 1 for MIDI 1.0 byte devices, 2 for UMP devices.
  /// - [transportCode] the code of the transport, e.g. `KS`, `BLE10`, `APP`.
  /// - [flags] the `AMW_ENDPOINT_*` bits.
  /// - [protocol] the protocol of the stream configuration: 0 default,
  ///   1 MIDI 1.0, 2 MIDI 2.0.
  WindowsMidiEndpointRecord({
    this.purpose = 0,
    this.nativeDataFormat = 0,
    this.transportCode = '',
    this.manufacturer = '',
    this.serialNumber = '',
    this.description = '',
    this.vendorId = 0,
    this.productId = 0,
    this.flags = 0,
    this.endpointName = '',
    this.productInstanceId = '',
    this.declaredFunctionBlockCount = 0,
    this.umpVersionMajor = 0,
    this.umpVersionMinor = 0,
    this.protocol = 0,
    this.identity,
    List<MidiFunctionBlockInfo> functionBlocks = const [],
    List<WindowsMidiGroupTerminalBlock> groupTerminalBlocks = const [],
  }) : functionBlocks = List.unmodifiable(functionBlocks),
       groupTerminalBlocks = List.unmodifiable(groupTerminalBlocks);

  // ...........................................................................
  /// The purpose of the endpoint.
  final int purpose;

  /// The data format the device speaks natively.
  final int nativeDataFormat;

  /// The code of the transport that provides the endpoint.
  final String transportCode;

  /// The manufacturer the transport reports.
  final String manufacturer;

  /// The serial number the transport reports.
  final String serialNumber;

  /// The description the transport reports.
  final String description;

  /// The USB vendor id, 0 when unknown.
  final int vendorId;

  /// The USB product id, 0 when unknown.
  final int productId;

  /// The `AMW_ENDPOINT_*` bits.
  final int flags;

  /// The name the endpoint declares.
  final String endpointName;

  /// The product instance id the endpoint declares.
  final String productInstanceId;

  /// The number of function blocks the endpoint declares.
  final int declaredFunctionBlockCount;

  /// The major UMP version the endpoint declares.
  final int umpVersionMajor;

  /// The minor UMP version the endpoint declares.
  final int umpVersionMinor;

  /// The protocol of the stream configuration.
  final int protocol;

  /// The device identity, or null when the endpoint declares none.
  final MidiDeviceIdentity? identity;

  /// The function blocks the endpoint declares; cannot be modified.
  final List<MidiFunctionBlockInfo> functionBlocks;

  /// The group terminal blocks of the device; cannot be modified.
  final List<WindowsMidiGroupTerminalBlock> groupTerminalBlocks;

  /// Whether the endpoint supports the MIDI 1.0 protocol.
  bool get supportsMidi1 => _has(AMW_ENDPOINT_SUPPORTS_MIDI1);

  /// Whether the endpoint supports the MIDI 2.0 protocol.
  bool get supportsMidi2 => _has(AMW_ENDPOINT_SUPPORTS_MIDI2);

  /// Whether the endpoint can receive JR timestamps.
  bool get supportsRxJr => _has(AMW_ENDPOINT_SUPPORTS_RX_JR);

  /// Whether the endpoint can send JR timestamps.
  bool get supportsTxJr => _has(AMW_ENDPOINT_SUPPORTS_TX_JR);

  /// Whether the function blocks of the endpoint never change.
  bool get staticFunctionBlocks => _has(AMW_ENDPOINT_STATIC_BLOCKS);

  /// Whether several applications can use the endpoint at once.
  bool get isMultiClient => _has(AMW_ENDPOINT_MULTI_CLIENT);

  /// Whether the stream configuration receives JR timestamps.
  bool get receivesJr => _has(AMW_ENDPOINT_RECEIVES_JR);

  /// Whether the stream configuration sends JR timestamps.
  bool get transmitsJr => _has(AMW_ENDPOINT_TRANSMITS_JR);

  /// Whether Windows finished the endpoint discovery.
  bool get isDiscoveryComplete => _has(AMW_ENDPOINT_DISCOVERY_COMPLETE);

  /// Whether the device speaks UMP natively instead of MIDI 1.0 bytes.
  bool get isUmpNative => nativeDataFormat == nativeDataFormatUmp;

  // ...........................................................................
  /// The native data format of MIDI 1.0 byte devices.
  static const int nativeDataFormatMidi1 = 1;

  /// The native data format of UMP devices.
  static const int nativeDataFormatUmp = 2;

  /// The purpose of an ordinary endpoint.
  static const int purposeNormal = 0;

  /// The purpose of the device side of a virtual device.
  static const int purposeVirtualDeviceResponder = 100;

  /// The purpose of the in-box General MIDI synthesizer.
  static const int purposeGeneralMidiSynth = 400;

  /// The purpose of the diagnostic loopback endpoints.
  static const int purposeDiagnosticLoopback = 500;

  /// The purpose of the diagnostic ping endpoint.
  static const int purposeDiagnosticPing = 510;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowsMidiEndpointRecord &&
          other.purpose == purpose &&
          other.nativeDataFormat == nativeDataFormat &&
          other.transportCode == transportCode &&
          other.manufacturer == manufacturer &&
          other.serialNumber == serialNumber &&
          other.description == description &&
          other.vendorId == vendorId &&
          other.productId == productId &&
          other.flags == flags &&
          other.endpointName == endpointName &&
          other.productInstanceId == productInstanceId &&
          other.declaredFunctionBlockCount == declaredFunctionBlockCount &&
          other.umpVersionMajor == umpVersionMajor &&
          other.umpVersionMinor == umpVersionMinor &&
          other.protocol == protocol &&
          other.identity == identity &&
          other.functionBlocks.equals(functionBlocks) &&
          other.groupTerminalBlocks.equals(groupTerminalBlocks);

  @override
  int get hashCode => Object.hash(
    purpose,
    nativeDataFormat,
    transportCode,
    manufacturer,
    serialNumber,
    description,
    vendorId,
    productId,
    flags,
    endpointName,
    productInstanceId,
    declaredFunctionBlockCount,
    umpVersionMajor,
    umpVersionMinor,
    protocol,
    identity,
    Object.hashAll(functionBlocks),
    Object.hashAll(groupTerminalBlocks),
  );

  @override
  String toString() =>
      'WindowsMidiEndpointRecord(purpose: $purpose, '
      'nativeDataFormat: $nativeDataFormat, '
      "transportCode: '$transportCode', manufacturer: '$manufacturer', "
      "serialNumber: '$serialNumber', description: '$description', "
      'vendorId: $vendorId, productId: $productId, flags: $flags, '
      "endpointName: '$endpointName', "
      "productInstanceId: '$productInstanceId', "
      'declaredFunctionBlockCount: $declaredFunctionBlockCount, '
      'umpVersion: $umpVersionMajor.$umpVersionMinor, '
      'protocol: $protocol, identity: $identity, '
      'functionBlocks: $functionBlocks, '
      'groupTerminalBlocks: $groupTerminalBlocks)';

  // ...........................................................................
  bool _has(int flag) => flags & flag != 0;
}
