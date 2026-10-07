// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../shim/windows_midi_port_record.dart';
import 'windows_midi_port_mapper.dart';

// #############################################################################
/// The ports of the Windows backend: the records the watchers report, the
/// own virtual ports and the ports whose endpoint disconnected.
///
/// [diff] turns two snapshots of [ports] into the port events of a hotplug.
final class WindowsMidiPortTable {
  /// Creates an empty table that maps records with [mapper].
  WindowsMidiPortTable({this.mapper = const WindowsMidiPortMapper()});

  // ...........................................................................
  /// Adds or replaces [record]; its ports lose a disconnected state.
  void put(WindowsMidiPortRecord record) {
    _records[_key(record.source, record.id)] = record;
    for (final port in mapper.map(record)) {
      _disconnected.remove(port.id);
    }
    _cache = null;
  }

  /// Removes the record [id] of the watcher [source].
  void remove({required int source, required String id}) {
    final record = _records.remove(_key(source, id));
    if (record == null) return;
    for (final port in mapper.map(record)) {
      _disconnected.remove(port.id);
    }
    _cache = null;
  }

  /// Adds the own virtual [port]; endpoints that declare
  /// [productInstanceId] are marked as own as well.
  void putOwn(MidiPortInfo port, {String productInstanceId = ''}) {
    _own[port.id] = (port: port, productInstanceId: productInstanceId);
    _cache = null;
  }

  /// Removes the own virtual port [id].
  void removeOwn(MidiPortId id) {
    _own.remove(id);
    _cache = null;
  }

  /// Marks the port [id] as disconnected until its record changes.
  void markDisconnected(MidiPortId id) {
    _disconnected.add(id);
    _cache = null;
  }

  /// Returns the port [id], or null when it does not exist.
  MidiPortInfo? find(MidiPortId id) {
    for (final port in ports) {
      if (port.id == id) return port;
    }
    return null;
  }

  // ...........................................................................
  /// Maps the records to ports.
  final WindowsMidiPortMapper mapper;

  /// The current ports: the ports of the records in the order they arrived,
  /// then the own virtual ports; cannot be modified.
  List<MidiPortInfo> get ports => _cache ??= List.unmodifiable([
    for (final record in _records.values)
      for (final port in mapper.map(record)) _decorate(port),
    for (final own in _own.values) own.port,
  ]);

  // ...........................................................................
  /// Returns the events that turn the ports [previous] into [current]:
  /// removals first, then additions and changes in the order of [current].
  static List<MidiPortEvent> diff(
    List<MidiPortInfo> previous,
    List<MidiPortInfo> current,
  ) {
    final before = {for (final port in previous) port.id: port};
    final after = {for (final port in current) port.id: port};
    final events = <MidiPortEvent>[
      for (final port in previous)
        if (!after.containsKey(port.id)) MidiPortRemoved(port: port),
    ];
    for (final port in current) {
      final old = before[port.id];
      if (old == null) {
        events.add(MidiPortAdded(port: port));
      } else if (old != port) {
        events.add(MidiPortChanged(port: port, previous: old));
      }
    }
    return events;
  }

  // ...........................................................................
  static String _key(int source, String id) => '$source|$id';

  MidiPortInfo _decorate(MidiPortInfo port) {
    var result = port;
    final instance = port.endpoint?.productInstanceId ?? '';
    if (instance.isNotEmpty &&
        _own.values.any((own) => own.productInstanceId == instance)) {
      result = result.copyWith(isOwn: true);
    }
    if (_disconnected.contains(port.id)) {
      result = result.copyWith(state: MidiPortState.disconnected);
    }
    return result;
  }

  final Map<String, WindowsMidiPortRecord> _records = {};
  final Map<MidiPortId, ({MidiPortInfo port, String productInstanceId})> _own =
      {};
  final Set<MidiPortId> _disconnected = {};
  List<MidiPortInfo>? _cache;
}
