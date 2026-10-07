// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/backend/windows_midi_port_mapper.dart';
import 'package:aud_midi_windows/src/backend/windows_midi_port_table.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:test/test.dart';

void main() {
  const mapper = WindowsMidiPortMapper();
  const input = WindowsMidiPortRecord(
    source: AMW_SOURCE_MIDI1_IN,
    id: 'in',
    name: 'In',
  );
  const output = WindowsMidiPortRecord(
    source: AMW_SOURCE_MIDI1_OUT,
    id: 'out',
    name: 'Out',
  );
  final endpoint = WindowsMidiPortRecord(
    source: AMW_SOURCE_MIDI2,
    id: 'client',
    name: 'Client',
    endpoint: WindowsMidiEndpointRecord(
      endpointName: 'Client',
      productInstanceId: 'aud_midi-1',
    ),
  );
  final own = MidiPortInfo(
    id: const MidiPortId('winrt:vout:device'),
    name: 'Own',
    direction: MidiDirection.output,
    isOwn: true,
  );
  late WindowsMidiPortTable table;

  List<String> ids() => [for (final port in table.ports) port.id.value];

  setUp(() => table = WindowsMidiPortTable());

  group('WindowsMidiPortTable', () {
    group('put(record), remove(...)', () {
      test('keep the ports in the order they arrived', () {
        table
          ..put(output)
          ..put(input);
        expect(ids(), equals(['winrt:out:out', 'winrt:in:in']));
        table.put(output.copyWith(name: 'Renamed'));
        expect(table.ports.first.name, 'Renamed');
        table.remove(source: AMW_SOURCE_MIDI1_OUT, id: 'out');
        expect(ids(), equals(['winrt:in:in']));
        table.remove(source: AMW_SOURCE_MIDI1_OUT, id: 'out');
        expect(ids(), equals(['winrt:in:in']));
        expect(table.mapper, same(table.mapper));
      });

      test('map with the given mapper', () {
        expect(WindowsMidiPortTable(mapper: mapper).mapper, same(mapper));
      });
    });

    group('putOwn(port), removeOwn(id)', () {
      test('list own ports after the records and mark their endpoints', () {
        table
          ..put(endpoint)
          ..putOwn(own, productInstanceId: 'aud_midi-1');
        expect(
          ids(),
          equals([
            'winrt:umpin:client',
            'winrt:umpout:client',
            'winrt:vout:device',
          ]),
        );
        expect([
          for (final port in table.ports) port.isOwn,
        ], equals([true, true, true]));
        table.removeOwn(own.id);
        expect([
          for (final port in table.ports) port.isOwn,
        ], equals([false, false]));
      });

      test('mark nothing without a product instance id', () {
        table
          ..put(endpoint)
          ..putOwn(own);
        expect(table.ports.first.isOwn, isFalse);
      });
    });

    group('markDisconnected(id)', () {
      test('marks a port until its record changes', () {
        table
          ..put(input)
          ..markDisconnected(const MidiPortId('winrt:in:in'));
        expect(table.ports.single.state, MidiPortState.disconnected);
        table.put(input);
        expect(table.ports.single.state, MidiPortState.connected);
        table
          ..markDisconnected(const MidiPortId('winrt:in:in'))
          ..remove(source: AMW_SOURCE_MIDI1_IN, id: 'in')
          ..put(input);
        expect(table.ports.single.state, MidiPortState.connected);
      });
    });

    group('find(id)', () {
      test('returns the port or null', () {
        table.put(input);
        expect(table.find(const MidiPortId('winrt:in:in'))?.name, 'In');
        expect(table.find(const MidiPortId('winrt:in:x')), isNull);
      });
    });

    group('ports', () {
      test('are cached and cannot be modified', () {
        table.put(input);
        expect(identical(table.ports, table.ports), isTrue);
        expect(() => table.ports.clear(), throwsUnsupportedError);
      });
    });

    group('diff(previous, current)', () {
      test('lists removals, then additions and changes', () {
        final a = mapper.map(input).single;
        final b = mapper.map(output).single;
        final changedA = a.copyWith(name: 'Changed');
        final c = mapper.map(endpoint).first;
        expect(
          WindowsMidiPortTable.diff([a, b], [changedA, c]),
          equals([
            MidiPortRemoved(port: b),
            MidiPortChanged(port: changedA, previous: a),
            MidiPortAdded(port: c),
          ]),
        );
        expect(WindowsMidiPortTable.diff([a], [a]), isEmpty);
      });
    });
  });
}
