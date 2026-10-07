// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'aud_midi_windows_bindings.g.dart';
import 'windows_midi_byte_reader.dart';
import 'windows_midi_data_record.dart';
import 'windows_midi_endpoint_record.dart';
import 'windows_midi_group_terminal_block.dart';
import 'windows_midi_port_record.dart';
import 'windows_midi_shim_event.dart';

// #############################################################################
/// Decodes the buffers the shim hands out: the events of `amw_read_events`
/// and the data records of `amw_port_read` (`src/aud_midi_windows.h`).
///
/// Malformed buffers throw a [FormatException]. Bytes a newer shim appends
/// to a known event are ignored, and events of unknown kinds become
/// [WindowsMidiShimUnknownEvent].
final class WindowsMidiShimDecoder {
  /// Creates a decoder.
  const WindowsMidiShimDecoder();

  // ...........................................................................
  /// Decodes the events in [bytes].
  List<WindowsMidiShimEvent> decodeEvents(Uint8List bytes) {
    final reader = WindowsMidiByteReader(bytes);
    final events = <WindowsMidiShimEvent>[];
    while (!reader.isAtEnd) {
      events.add(_event(reader.u32(), reader.bytes(reader.u32())));
    }
    return events;
  }

  /// Decodes the data records in [bytes].
  List<WindowsMidiDataRecord> decodeRecords(Uint8List bytes) {
    final reader = WindowsMidiByteReader(bytes);
    final records = <WindowsMidiDataRecord>[];
    while (!reader.isAtEnd) {
      records.add(
        WindowsMidiDataRecord(
          timeMicros: reader.i64(),
          flags: reader.u32(),
          data: reader.bytes(reader.u32()),
        ),
      );
    }
    return records;
  }

  // ...........................................................................
  WindowsMidiShimEvent _event(int kind, Uint8List payload) {
    final reader = WindowsMidiByteReader(payload);
    return switch (kind) {
      AMW_EVENT_PORT_ADDED => WindowsMidiShimPortAdded(_port(reader)),
      AMW_EVENT_PORT_UPDATED => WindowsMidiShimPortUpdated(_port(reader)),
      AMW_EVENT_PORT_REMOVED => WindowsMidiShimPortRemoved(
        source: reader.u32(),
        id: reader.string(),
      ),
      AMW_EVENT_ENUMERATION_COMPLETED => WindowsMidiShimEnumerationCompleted(
        reader.u32(),
      ),
      AMW_EVENT_WATCHER_STOPPED => WindowsMidiShimWatcherStopped(
        source: reader.u32(),
        status: reader.u32(),
      ),
      AMW_EVENT_OPEN_COMPLETED => WindowsMidiShimOpenCompleted(
        request: reader.i64(),
        status: reader.i32(),
        handle: reader.i32(),
        message: reader.string(),
      ),
      AMW_EVENT_PORT_DISCONNECTED => WindowsMidiShimPortDisconnected(
        reader.i32(),
      ),
      AMW_EVENT_BLE_ADVERTISEMENT => WindowsMidiShimBleAdvertisement(
        address: reader.u64(),
        rssi: reader.i32(),
        flags: reader.u32(),
        name: reader.string(),
      ),
      AMW_EVENT_BLE_SCAN_STOPPED => WindowsMidiShimBleScanStopped(reader.i32()),
      AMW_EVENT_BLE_PAIR_COMPLETED => WindowsMidiShimBlePairCompleted(
        request: reader.i64(),
        status: reader.i32(),
        result: reader.i32(),
        message: reader.string(),
      ),
      AMW_EVENT_BLE_UNPAIR_COMPLETED => WindowsMidiShimBleUnpairCompleted(
        request: reader.i64(),
        status: reader.i32(),
        result: reader.i32(),
        message: reader.string(),
      ),
      AMW_EVENT_VIRTUAL_CREATED => WindowsMidiShimVirtualCreated(
        request: reader.i64(),
        status: reader.i32(),
        handle: reader.i32(),
        endpointId: reader.string(),
        message: reader.string(),
      ),
      AMW_EVENT_ERROR => WindowsMidiShimError(
        status: reader.i32(),
        source: reader.u32(),
        api: reader.string(),
        message: reader.string(),
      ),
      AMW_EVENT_EVENTS_DROPPED => WindowsMidiShimEventsDropped(reader.u64()),
      _ => WindowsMidiShimUnknownEvent(kind: kind, payload: payload),
    };
  }

  WindowsMidiPortRecord _port(WindowsMidiByteReader reader) =>
      WindowsMidiPortRecord(
        source: reader.u32(),
        id: reader.string(),
        name: reader.string(),
        flags: reader.u32(),
        deviceInstanceId: reader.string(),
        containerId: reader.string(),
        endpoint: reader.u8() == 0 ? null : _endpoint(reader),
      );

  WindowsMidiEndpointRecord _endpoint(WindowsMidiByteReader reader) {
    final purpose = reader.u32();
    final nativeDataFormat = reader.u32();
    final transportCode = reader.string();
    final manufacturer = reader.string();
    final serialNumber = reader.string();
    final description = reader.string();
    final vendorId = reader.u16();
    final productId = reader.u16();
    final flags = reader.u32();
    return WindowsMidiEndpointRecord(
      purpose: purpose,
      nativeDataFormat: nativeDataFormat,
      transportCode: transportCode,
      manufacturer: manufacturer,
      serialNumber: serialNumber,
      description: description,
      vendorId: vendorId,
      productId: productId,
      flags: flags,
      endpointName: reader.string(),
      productInstanceId: reader.string(),
      declaredFunctionBlockCount: reader.u8(),
      umpVersionMajor: reader.u8(),
      umpVersionMinor: reader.u8(),
      protocol: reader.u8(),
      identity: _identity(reader.bytes(11), flags),
      functionBlocks: [
        for (var i = reader.u32(); i > 0; i--) _functionBlock(reader),
      ],
      groupTerminalBlocks: [
        for (var i = reader.u32(); i > 0; i--) _groupTerminalBlock(reader),
      ],
    );
  }

  MidiDeviceIdentity? _identity(Uint8List bytes, int flags) {
    if (flags & AMW_ENDPOINT_HAS_IDENTITY == 0) return null;
    return MidiDeviceIdentity(
      manufacturerId: bytes.sublist(0, 3),
      familyId: bytes[3] | bytes[4] << 7,
      modelId: bytes[5] | bytes[6] << 7,
      softwareRevision: bytes.sublist(7, 11),
    );
  }

  MidiFunctionBlockInfo _functionBlock(WindowsMidiByteReader reader) {
    final number = reader.u8();
    final isActive = reader.u8() != 0;
    final direction = MidiFunctionBlockDirection.fromValue(reader.u8());
    final uiHint = MidiFunctionBlockUiHint.fromValue(reader.u8());
    final midi1 = MidiFunctionBlockMidi1.fromValue(reader.u8());
    return MidiFunctionBlockInfo(
      number: number,
      isActive: isActive,
      direction: direction,
      uiHint: uiHint,
      midi1: midi1,
      firstGroup: reader.u8() & 0xF,
      groupCount: _groupCount(reader.u8()),
      midiCiVersion: reader.u8(),
      maxSysEx8Streams: reader.u8(),
      name: reader.string(),
    );
  }

  WindowsMidiGroupTerminalBlock _groupTerminalBlock(
    WindowsMidiByteReader reader,
  ) => WindowsMidiGroupTerminalBlock(
    number: reader.u8(),
    direction: reader.u8(),
    protocol: reader.u8(),
    firstGroup: reader.u8() & 0xF,
    groupCount: _groupCount(reader.u8()),
    name: reader.string(),
  );

  int _groupCount(int value) => value > 16 ? 16 : value;
}
