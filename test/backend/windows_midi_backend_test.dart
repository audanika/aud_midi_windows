// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/shim/aud_midi_windows_bindings.g.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_status.dart';
import 'package:test/test.dart';

// #############################################################################
/// Records what a backend reports.
final class _Host implements MidiBackendHost {
  @override
  final MidiFakeClock clock = MidiFakeClock(start: const MidiTime(1000000));

  final List<MidiPortEvent> events = [];
  final List<(MidiPortId, MidiPacket)> packets = [];
  final List<MidiDiagnostic> diagnostics = [];

  @override
  void portsChanged(List<MidiPortEvent> events) => this.events.addAll(events);

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port, packet));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);
}

void main() {
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
    id: 'ep',
    name: 'Endpoint',
    endpoint: WindowsMidiEndpointRecord(nativeDataFormat: 2),
  );
  const inId = MidiPortId('winrt:in:in');
  const outId = MidiPortId('winrt:out:out');
  const umpInId = MidiPortId('winrt:umpin:ep');
  const umpOutId = MidiPortId('winrt:umpout:ep');
  const midi2Features =
      AMW_FEATURE_MIDI1 | AMW_FEATURE_MIDI2 | AMW_FEATURE_VIRTUAL_DEVICES;

  late WindowsMidiFakeShim shim;
  late WindowsMidiBackend backend;
  late _Host host;

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  Future<void> start({
    int features = AMW_FEATURE_MIDI1,
    List<WindowsMidiPortRecord> ports = const [input, output],
    WindowsMidiApi api = WindowsMidiApi.auto,
    bool loopback = false,
    Duration enumerationTimeout = const Duration(seconds: 5),
    Duration requestTimeout = const Duration(seconds: 5),
    Duration resyncInterval = const Duration(seconds: 10),
  }) async {
    shim = WindowsMidiFakeShim(features: features, ports: ports);
    backend = WindowsMidiBackend(
      shim: shim,
      api: api,
      includeDiagnosticLoopback: loopback,
      enumerationTimeout: enumerationTimeout,
      requestTimeout: requestTimeout,
      resyncInterval: resyncInterval,
    );
    host = _Host();
    await backend.start(host);
  }

  List<String> ids() => [for (final port in backend.ports) port.id.value];

  List<String> causes() => [for (final d in host.diagnostics) d.cause];

  tearDown(() => backend.stop());

  group('WindowsMidiBackend', () {
    group('WindowsMidiBackend(...)', () {
      test('defaults to the FFI shim and automatic API selection', () {
        backend = WindowsMidiBackend();
        expect(backend.api, WindowsMidiApi.auto);
        expect(backend.includeDiagnosticLoopback, isFalse);
        expect(
          [
            backend.enumerationTimeout,
            backend.requestTimeout,
            backend.resyncInterval,
          ],
          equals([
            const Duration(seconds: 5),
            const Duration(seconds: 10),
            const Duration(seconds: 10),
          ]),
        );
        expect(backend.name, 'winrt');
      });

      test('reports nothing before start', () {
        backend = WindowsMidiBackend(shim: WindowsMidiFakeShim());
        expect(backend.ports, isEmpty);
        expect(backend.capabilities, const MidiCapabilities.none());
        expect([
          backend.bluetooth,
          backend.virtualPorts,
          backend.network,
        ], equals([null, null, null]));
      });
    });

    group('start(host)', () {
      test('enumerates the WinRT MIDI 1.0 ports', () async {
        await start();
        expect(ids(), equals(['winrt:in:in', 'winrt:out:out']));
        expect(shim.calls, equals(['create', 'watchStart(3)']));
        expect(host.events, isEmpty);
        expect(
          backend.capabilities,
          MidiCapabilities(
            virtualPorts: MidiVirtualPortSupport.none,
            scheduling: MidiSchedulingSupport.software,
          ),
        );
        expect([
          backend.bluetooth,
          backend.virtualPorts,
          backend.network,
        ], equals([null, null, null]));
      });

      test('offers Bluetooth LE when a radio is present', () async {
        await start(features: AMW_FEATURE_MIDI1 | AMW_FEATURE_BLUETOOTH);
        expect(backend.bluetooth, isA<WindowsMidiBluetooth>());
        expect(backend.capabilities.bleScan, isTrue);
      });

      test('uses Windows MIDI Services alone when present', () async {
        await start(features: midi2Features, ports: [input, endpoint]);
        expect(shim.calls.last, 'watchStart(4)');
        expect(ids(), equals(['winrt:umpin:ep', 'winrt:umpout:ep']));
        expect(
          backend.capabilities,
          MidiCapabilities(
            virtualPorts: MidiVirtualPortSupport.dynamicPorts,
            ump: true,
            scheduling: MidiSchedulingSupport.hardware,
          ),
        );
        expect(backend.virtualPorts, isA<WindowsMidiVirtualPorts>());
      });

      test('adds the loopback endpoints when asked', () async {
        await start(features: midi2Features, loopback: true);
        expect(shim.calls.last, 'watchStart(12)');
      });

      test('uses both APIs in hybrid legacy mode', () async {
        await start(
          features: midi2Features | AMW_FEATURE_MIDI2_HYBRID,
          ports: [input, endpoint],
        );
        expect(shim.calls.last, 'watchStart(7)');
        expect(
          ids(),
          equals(['winrt:in:in', 'winrt:umpin:ep', 'winrt:umpout:ep']),
        );
      });

      test('uses WinRT MIDI 1.0 alone when asked', () async {
        await start(features: midi2Features, api: WindowsMidiApi.midi1);
        expect(shim.calls.last, 'watchStart(3)');
        expect(backend.virtualPorts, isNull);
      });

      test('fails without Windows MIDI Services when it is required', () async {
        await expectLater(
          start(api: WindowsMidiApi.midi2),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'Windows MIDI Services',
            ),
          ),
        );
        expect(shim.isDestroyed, isTrue);
        expect(backend.ports, isEmpty);
      });

      test('fails without WinRT MIDI 1.0', () async {
        await expectLater(
          start(features: 0),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'Windows.Devices.Midi',
            ),
          ),
        );
      });

      test('fails when the shim fails and may start again', () async {
        shim = WindowsMidiFakeShim()..failures['watchStart'] = AMW_E_UNEXPECTED;
        backend = WindowsMidiBackend(shim: shim);
        host = _Host();
        await expectLater(backend.start(host), throwsA(isA<MidiNativeError>()));
        expect(shim.isDestroyed, isTrue);
        await backend.start(host);
        expect(backend.ports, isEmpty);
      });

      test('fails when started twice', () async {
        await start();
        await expectLater(backend.start(host), throwsStateError);
      });

      test('continues after an enumeration timeout', () async {
        shim = WindowsMidiFakeShim(ports: [input])..completeEnumeration = false;
        backend = WindowsMidiBackend(
          shim: shim,
          enumerationTimeout: const Duration(milliseconds: 10),
        );
        host = _Host();
        await backend.start(host);
        expect(ids(), equals(['winrt:in:in']));
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.nativeError);
        expect(causes().single, contains('did not complete'));
      });

      test('treats a failed watcher as enumerated', () async {
        shim = WindowsMidiFakeShim()..completeEnumeration = false;
        backend = WindowsMidiBackend(shim: shim);
        host = _Host();
        final starting = backend.start(host);
        await tick();
        shim
          ..fail(
            status: AMW_E_UNEXPECTED,
            source: AMW_SOURCE_MIDI1_IN,
            api: 'DeviceWatcher',
            message: 'broken',
          )
          ..completeEnumerationOf(AMW_SOURCE_MIDI1_OUT);
        await starting;
        expect(
          causes(),
          equals(['DeviceWatcher failed with 0x8000ffff: broken']),
        );
      });

      test('returns when stopped during the enumeration', () async {
        shim = WindowsMidiFakeShim()..completeEnumeration = false;
        backend = WindowsMidiBackend(shim: shim);
        host = _Host();
        final starting = backend.start(host);
        await tick();
        await backend.stop();
        await starting;
        expect(backend.ports, isEmpty);
        expect(backend.capabilities, const MidiCapabilities.none());
      });
    });

    group('stop()', () {
      test('stops the sources, then destroys the shim', () async {
        await start(features: midi2Features, ports: [endpoint]);
        await backend.openPort(umpInId);
        await backend.virtualPorts!.create(
          MidiVirtualPortSpec(name: 'V', direction: MidiDirection.output),
        );
        await backend.stop();
        expect(
          shim.calls.skip(4),
          equals(['watchStop', 'closePort(1)', 'closePort(2)', 'destroy']),
        );
        expect(backend.ports, isEmpty);
        await backend.stop();
        expect(shim.calls.last, 'destroy');
      });

      test('reports failing closes', () async {
        await start();
        await backend.openPort(inId);
        shim.failures['closePort'] = AMW_E_UNEXPECTED;
        await backend.stop();
        expect(causes().single, contains('fake closePort'));
      });

      test('fails the waiting requests', () async {
        await start();
        shim.autoComplete = false;
        final opening = expectLater(backend.openPort(inId), throwsStateError);
        await tick();
        await backend.stop();
        await opening;
      });

      test('ignores signals that arrive afterwards', () async {
        await start();
        await backend.stop();
        shim.signalNow();
        expect(host.events, isEmpty);
      });

      test('does nothing before start', () async {
        backend = WindowsMidiBackend(shim: WindowsMidiFakeShim());
        await backend.stop();
      });
    });

    group('hotplug', () {
      test('reports added, changed and removed ports', () async {
        await start(ports: [input]);
        shim.addPort(output);
        await tick();
        shim.updatePort(output.copyWith(name: 'Renamed'));
        await tick();
        shim.removePort(source: AMW_SOURCE_MIDI1_IN, id: 'in');
        await tick();
        expect([
          for (final event in host.events) event.runtimeType,
        ], equals([MidiPortAdded, MidiPortChanged, MidiPortRemoved]));
        expect(ids(), equals(['winrt:out:out']));
        expect(backend.ports.single.name, 'Renamed');
      });

      test('closes ports that disappear', () async {
        await start();
        await backend.openPort(inId);
        shim.removePort(source: AMW_SOURCE_MIDI1_IN, id: 'in');
        await tick();
        expect(shim.calls.last, 'closePort(1)');
        expect(shim.openPorts, isEmpty);
      });

      test('marks ports whose endpoint disconnected', () async {
        await start(features: midi2Features, ports: [endpoint]);
        await backend.openPort(umpOutId);
        shim
          ..disconnect(1)
          ..disconnect(99);
        await tick();
        expect(shim.openPorts, isEmpty);
        expect(
          host.events.single,
          isA<MidiPortChanged>()
              .having((e) => e.port.id, 'id', umpOutId)
              .having((e) => e.port.state, 'state', MidiPortState.disconnected),
        );
      });

      test('reports failed watchers, scans and other errors', () async {
        await start();
        shim
          ..stopWatcher(source: AMW_SOURCE_MIDI1_IN, status: 4)
          ..stopWatcher(source: AMW_SOURCE_MIDI1_IN, status: 5)
          ..stopScan(0)
          ..stopScan(7)
          ..fail(status: AMW_E_UNEXPECTED, api: 'X', message: 'y')
          ..dropEvents(3)
          ..emit(99, [1]);
        await tick();
        expect(
          causes(),
          equals([
            'The watcher of source 1 failed (status 5)',
            'The Bluetooth LE scan stopped with BluetoothError 7',
            'X failed with 0x8000ffff: y',
            'The event queue of the shim was full',
          ]),
        );
        expect(host.diagnostics.last.kind, MidiDiagnosticKind.queueOverflow);
        expect(host.diagnostics.last.count, 3);
      });

      test('reports failing and malformed event reads', () async {
        await start();
        shim
          ..failures['readEvents'] = AMW_E_UNEXPECTED
          ..disconnect(1);
        await tick();
        shim
          ..rearm()
          ..emit(AMW_EVENT_PORT_DISCONNECTED, [1]);
        await tick();
        expect(
          [for (final d in host.diagnostics) d.kind],
          equals([
            MidiDiagnosticKind.nativeError,
            MidiDiagnosticKind.invalidData,
          ]),
        );
      });

      test('maps the native clock anew from time to time', () async {
        await start(resyncInterval: const Duration(milliseconds: 5));
        shim.clockMicros = 500;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await backend.openPort(inId);
        shim.receive(1, [0xF8], timeMicros: 600);
        await tick();
        expect(host.packets.single.$2.time, const MidiTime(1000100));
      });
    });

    group('openPort(port), receive', () {
      test('delivers the packets of an input with mapped times', () async {
        await start();
        await backend.openPort(inId);
        await backend.openPort(inId);
        expect(shim.calls.where((c) => c.startsWith('openPort')), hasLength(1));
        shim
          ..receive(1, [0x90, 0x3C, 0x64], timeMicros: 250)
          ..overflow(1, 2);
        await tick();
        expect(
          host.packets,
          equals([
            (
              inId,
              MidiBytesPacket(
                bytes: MidiBytes([0x90, 0x3C, 0x64]),
                time: const MidiTime(1000250),
              ),
            ),
          ]),
        );
        expect(
          host.diagnostics.single,
          const MidiDiagnostic(
            kind: MidiDiagnosticKind.queueOverflow,
            port: inId,
            count: 2,
            cause: 'The receive buffer of the shim was full',
            time: MidiTime(1000000),
          ),
        );
      });

      test('delivers UMP packets of UMP inputs', () async {
        await start(features: midi2Features, ports: [endpoint]);
        await backend.openPort(umpInId);
        shim.receive(1, [0x64, 0, 0x90, 0x20], timeMicros: 1, ump: true);
        await tick();
        expect(
          host.packets.single.$2,
          MidiUmpPacket(words: [0x20900064], time: const MidiTime(1000001)),
        );
      });

      test('drains data that arrived with the open', () async {
        await start();
        shim.autoComplete = false;
        final opening = backend.openPort(inId);
        await tick();
        shim.completeOpen(shim.pendingOpens.single);
        shim.receive(1, [0xF8], timeMicros: 0);
        await opening;
        expect(host.packets, hasLength(1));
      });

      test('shares a running open', () async {
        await start();
        await Future.wait([backend.openPort(inId), backend.openPort(inId)]);
        expect(shim.openPorts, hasLength(1));
      });

      test('forgets inputs that fail to read', () async {
        await start();
        await backend.openPort(inId);
        shim.failures['readPort'] = AMW_E_UNEXPECTED;
        shim.receive(1, [0xF8], timeMicros: 0);
        await tick();
        expect(causes().single, contains('Reading the port failed'));
        await backend.openPort(inId);
        expect(
          shim.calls.where((call) => call.startsWith('openPort')),
          hasLength(2),
        );
      });

      test('reports malformed records', () async {
        await start();
        await backend.openPort(inId);
        shim.corrupt(1, [1, 2, 3]);
        await tick();
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.invalidData);
      });

      test('fails for unknown ports', () async {
        await start();
        for (final port in const [
          MidiPortId('winrt:in:x'),
          MidiPortId('coremidi:in:in'),
        ]) {
          await expectLater(
            backend.openPort(port),
            throwsA(isA<MidiPortGone>()),
          );
        }
      });

      test('maps failed opens to exceptions', () async {
        await start();
        shim.openStatus['in'] = AMW_E_CLOSED;
        await expectLater(
          backend.openPort(inId),
          throwsA(isA<MidiPortGone>().having((e) => e.port, 'port', inId)),
        );
        shim.openStatus['in'] = AMW_E_PORT_UNAVAILABLE;
        await expectLater(
          backend.openPort(inId),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              AMW_E_PORT_UNAVAILABLE,
            ),
          ),
        );
      });

      test('fails after the timeout and closes a late port', () async {
        await start(requestTimeout: const Duration(milliseconds: 10));
        shim.autoComplete = false;
        await expectLater(
          backend.openPort(inId),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              WindowsMidiStatus.timeout,
            ),
          ),
        );
        shim.completeOpen(shim.pendingOpens.single);
        await tick();
        expect(shim.openPorts, isEmpty);
        await expectLater(
          backend.openPort(inId),
          throwsA(isA<MidiNativeError>()),
        );
        shim.completeOpen(shim.pendingOpens.single, status: AMW_E_CLOSED);
        await tick();
        expect(
          shim.calls.where((c) => c.startsWith('closePort')),
          hasLength(1),
        );
      });

      test('closes a port that disappeared while it opened', () async {
        await start();
        shim.autoComplete = false;
        final opening = backend.openPort(inId);
        await tick();
        shim.removePort(source: AMW_SOURCE_MIDI1_IN, id: 'in');
        await tick();
        shim.completeOpen(shim.pendingOpens.single);
        await expectLater(opening, throwsA(isA<MidiPortGone>()));
        expect(shim.openPorts, isEmpty);
      });

      test('fails when the backend does not run', () {
        backend = WindowsMidiBackend(shim: WindowsMidiFakeShim());
        expect(() => backend.openPort(inId), throwsStateError);
      });
    });

    group('closePort(port)', () {
      test('closes an open port', () async {
        await start();
        await backend.openPort(inId);
        await backend.closePort(inId);
        await backend.closePort(inId);
        expect(shim.openPorts, isEmpty);
        expect(
          shim.calls.where((c) => c.startsWith('closePort')),
          hasLength(1),
        );
      });

      test('ignores ports the shim closed already', () async {
        await start();
        await backend.openPort(inId);
        shim.failures['closePort'] = AMW_E_UNKNOWN_HANDLE;
        await backend.closePort(inId);
      });

      test('reports other failures', () async {
        await start();
        await backend.openPort(inId);
        shim.failures['closePort'] = AMW_E_UNEXPECTED;
        await expectLater(
          backend.closePort(inId),
          throwsA(isA<MidiNativeError>()),
        );
      });
    });

    group('send(port, packet)', () {
      test('sends bytes to byte outputs at once', () async {
        await start();
        await backend.openPort(outId);
        await backend.send(
          outId,
          MidiBytesPacket(
            bytes: MidiBytes([0x90, 0x3C, 0x64]),
            time: const MidiTime(2000000),
          ),
        );
        await backend.send(
          outId,
          MidiBytesPacket(bytes: MidiBytes.empty, time: MidiTime.zero),
        );
        expect(shim.sent.single.data, equals([0x90, 0x3C, 0x64]));
        expect(shim.sent.single.dueMicros, 0);
      });

      test('schedules UMP packets on the native clock', () async {
        await start(features: midi2Features, ports: [endpoint]);
        await backend.openPort(umpOutId);
        shim.clockMicros = 0;
        await backend.send(
          umpOutId,
          MidiUmpPacket(
            words: [0x20903C64, 0x40903C00, 0xC8000000],
            time: const MidiTime(1000300),
          ),
        );
        await backend.send(
          umpOutId,
          MidiUmpPacket(words: [0x20903C64], time: const MidiTime(999000)),
        );
        expect(
          [for (final sent in shim.sent) sent.data],
          equals([
            [
              0x64, 0x3C, 0x90, 0x20, //
              0x00, 0x3C, 0x90, 0x40,
              0x00, 0x00, 0x00, 0xC8,
            ],
            [0x64, 0x3C, 0x90, 0x20],
          ]),
        );
        expect([
          for (final sent in shim.sent) sent.dueMicros,
        ], equals([300, 0]));
      });

      test('rejects wrong ports and packets', () async {
        await start(
          features: midi2Features | AMW_FEATURE_MIDI2_HYBRID,
          ports: [input, output, endpoint],
        );
        final bytes = MidiBytesPacket(
          bytes: MidiBytes([0xF8]),
          time: MidiTime.zero,
        );
        final words = MidiUmpPacket(words: [0x10F80000], time: MidiTime.zero);
        await expectLater(
          backend.send(const MidiPortId('winrt:out:x'), bytes),
          throwsA(isA<MidiPortGone>()),
        );
        await expectLater(
          backend.send(inId, bytes),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(backend.send(outId, bytes), throwsStateError);
        await backend.openPort(outId);
        await backend.openPort(umpOutId);
        await expectLater(
          backend.send(outId, words),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'UMP words on byte ports',
            ),
          ),
        );
        await expectLater(
          backend.send(umpOutId, bytes),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'MIDI 1.0 bytes on UMP ports',
            ),
          ),
        );
      });

      test('maps send failures to exceptions', () async {
        await start();
        await backend.openPort(outId);
        final packet = MidiBytesPacket(
          bytes: MidiBytes([0xF8]),
          time: MidiTime.zero,
        );
        shim.failures['send'] = AMW_E_CLOSED;
        await expectLater(
          backend.send(outId, packet),
          throwsA(isA<MidiPortGone>().having((e) => e.port, 'port', outId)),
        );
        shim.failures['send'] = AMW_E_UNKNOWN_HANDLE;
        await expectLater(
          backend.send(outId, packet),
          throwsA(isA<MidiPortGone>()),
        );
        shim.failures['send'] = AMW_E_UNEXPECTED;
        await expectLater(
          backend.send(outId, packet),
          throwsA(isA<MidiNativeError>()),
        );
      });
    });

    group('cancelPending(port)', () {
      test('has nothing to cancel on byte ports', () async {
        await start();
        await backend.cancelPending(outId);
      });

      test('is unsupported on scheduling UMP ports', () async {
        await start(features: midi2Features, ports: [endpoint]);
        await expectLater(
          backend.cancelPending(umpOutId),
          throwsA(isA<MidiUnsupported>()),
        );
      });

      test('fails for unknown ports and inputs', () async {
        await start();
        await expectLater(
          backend.cancelPending(const MidiPortId('winrt:out:x')),
          throwsA(isA<MidiPortGone>()),
        );
        await expectLater(
          backend.cancelPending(inId),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('virtualPorts', () {
      test('add and remove own ports', () async {
        await start(features: midi2Features, ports: const []);
        final created = await backend.virtualPorts!.create(
          MidiVirtualPortSpec(name: 'In', direction: MidiDirection.input),
        );
        expect(ids(), equals([created.id.value]));
        expect(host.events.single, MidiPortAdded(port: created));
        await backend.openPort(created.id);
        await backend.closePort(created.id);
        shim
          ..receive(1, [0x10, 0, 0xF8, 0x10], timeMicros: 5, ump: true)
          ..disconnect(1);
        await tick();
        expect(host.packets.single.$1, created.id);
        expect(backend.ports.single.state, MidiPortState.connected);
        await backend.virtualPorts!.remove(created.id);
        expect(ids(), isEmpty);
        expect(host.events.last, MidiPortRemoved(port: created));
      });

      test('send through own outputs', () async {
        await start(features: midi2Features, ports: const []);
        final created = await backend.virtualPorts!.create(
          MidiVirtualPortSpec(name: 'Out', direction: MidiDirection.output),
        );
        await backend.send(
          created.id,
          MidiUmpPacket(words: [0x10F80000], time: MidiTime.zero),
        );
        expect(shim.sent.single.handle, 1);
      });
    });

    group('bluetooth', () {
      test('connects to the ports the backend lists', () async {
        await start(features: AMW_FEATURE_MIDI1 | AMW_FEATURE_BLUETOOTH);
        final connecting = backend.bluetooth!.connect('00:00:00:00:00:2a');
        await tick();
        const ble = WindowsMidiPortRecord(
          source: AMW_SOURCE_MIDI1_IN,
          id: r'\\?\BTHLEDEVICE#{03b80e5a}_00000000002a#x',
          name: 'WIDI',
        );
        shim
          ..addPort(ble)
          ..addPort(
            const WindowsMidiPortRecord(
              source: AMW_SOURCE_MIDI1_OUT,
              id: r'\\?\BTHLEDEVICE#{03b80e5a}_00000000002a#y',
              name: 'WIDI',
            ),
          );
        final ports = await connecting;
        expect([
          for (final port in ports) port.direction,
        ], equals([MidiDirection.input, MidiDirection.output]));
      });

      test('reports scans and their end', () async {
        await start(features: AMW_FEATURE_MIDI1 | AMW_FEATURE_BLUETOOTH);
        final found = backend.bluetooth!.scan().toList();
        shim
          ..advertise(address: 1, name: 'A')
          ..stopScan(0);
        expect([
          for (final peripheral in await found) peripheral.name,
        ], equals(['A']));
      });
    });
  });
}
