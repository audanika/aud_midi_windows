// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/shim/windows_midi_status.dart';
import 'package:test/test.dart';

// #############################################################################
/// A registrar that records the calls and completes on request.
final class _Api implements WindowsDnsSdApi {
  void Function(int id, int status, String? instanceName)? onCompleted;
  final List<String> calls = [];
  final Map<int, (String, String, int, Map<String, String>)> registered = {};
  final List<int> released = [];
  int registerStatus = WindowsDnsSdApi.requestPending;
  int deregisterStatus = WindowsDnsSdApi.requestPending;
  bool closed = false;

  @override
  void listen(void Function(int, int, String?) onCompleted) =>
      this.onCompleted = onCompleted;

  @override
  void close() => closed = true;

  @override
  int register({
    required int id,
    required String instanceName,
    required String hostName,
    required int port,
    required Map<String, String> txt,
  }) {
    calls.add('register($id)');
    registered[id] = (instanceName, hostName, port, txt);
    return registerStatus;
  }

  @override
  int deregister(int id) {
    calls.add('deregister($id)');
    return deregisterStatus;
  }

  @override
  void release(int id) => released.add(id);

  /// Reports the completion of [id].
  void complete(int id, {int status = 0, String? name}) =>
      onCompleted!(id, status, name);
}

void main() {
  late _Api api;
  late WindowsMidiServiceAdvertiser advertiser;

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  WindowsMidiServiceAdvertiser make({
    Duration timeout = const Duration(seconds: 5),
  }) => WindowsMidiServiceAdvertiser(
    api: api,
    hostName: 'studio-pc.fritz.box',
    timeout: timeout,
  );

  // Registers `Studio` and completes it with [name].
  Future<MidiServiceRegistration> register({String? name}) async {
    final registering = advertiser.register(
      name: 'Studio',
      type: '_apple-midi._udp',
      port: 5004,
    );
    await tick();
    api.complete(api.registered.keys.last, name: name);
    return registering;
  }

  setUp(() {
    api = _Api();
    advertiser = make();
  });

  group('WindowsMidiServiceAdvertiser', () {
    group('WindowsMidiServiceAdvertiser(...)', () {
      test('listens to the registrar and names the host', () async {
        expect(api.onCompleted, isNotNull);
        expect(advertiser.timeout, const Duration(seconds: 5));
        final defaults = WindowsMidiServiceAdvertiser(api: api);
        expect(defaults.timeout, const Duration(seconds: 10));
        defaults
            .register(name: 'D', type: '_apple-midi._udp', port: 1)
            .ignore();
        await tick();
        expect(
          api.registered.values.last.$2,
          '${Platform.localHostname.split('.').first}.local',
        );
      });
    });

    group('WindowsMidiServiceAdvertiser() with defaults', () {
      test('binds dnsapi.dll lazily and closes its callback', () async {
        final defaults = WindowsMidiServiceAdvertiser();
        await defaults.close();
      });
    });

    group('register(...)', () {
      test('registers the service under its full name', () async {
        final registering = advertiser.register(
          name: 'Studio',
          type: '_midi2._udp',
          port: 5506,
          txt: const {'UMPEndpointName': 'Studio'},
        );
        await tick();
        final (instanceName, hostName, port, txt) = api.registered[1]!;
        expect([
          instanceName,
          hostName,
          port,
        ], equals(['Studio._midi2._udp.local', 'studio-pc.local', 5506]));
        expect(txt, equals({'UMPEndpointName': 'Studio'}));
        api.complete(1, name: 'Studio (2)._midi2._udp.local.');
        expect((await registering).name, 'Studio (2)');
      });

      test('keeps the requested name when the registrar names none', () async {
        expect((await register()).name, 'Studio');
      });

      test('rejects invalid arguments', () async {
        for (final (name, type, port) in [
          ('', '_apple-midi._udp', 5004),
          ('Studio', 'apple-midi', 5004),
          ('Studio', '_apple-midi._udp', 0),
          ('Studio', '_apple-midi._udp', 0x10000),
        ]) {
          await expectLater(
            advertiser.register(name: name, type: type, port: port),
            throwsA(isA<ArgumentError>()),
            reason: '$name $type $port',
          );
        }
        expect(api.calls, isEmpty);
      });

      test('fails when the registrar refuses the call', () async {
        api.registerStatus = 87;
        await expectLater(
          advertiser.register(name: 'S', type: '_apple-midi._udp', port: 1),
          throwsA(
            isA<MidiNativeError>()
                .having((e) => e.api, 'api', 'DnsServiceRegister')
                .having((e) => e.code, 'code', 87),
          ),
        );
        expect(api.released, equals([1]));
      });

      test('fails when the registration fails', () async {
        final registering = advertiser.register(
          name: 'S',
          type: '_apple-midi._udp',
          port: 1,
        );
        await tick();
        api.complete(1, status: 1460);
        await expectLater(
          registering,
          throwsA(isA<MidiNativeError>().having((e) => e.code, 'code', 1460)),
        );
        expect(api.released, equals([1]));
      });

      test('withdraws a registration that completes late', () async {
        advertiser = make(timeout: const Duration(milliseconds: 10));
        await expectLater(
          advertiser.register(name: 'S', type: '_apple-midi._udp', port: 1),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.code,
              'code',
              WindowsMidiStatus.timeout,
            ),
          ),
        );
        api.complete(1);
        expect(api.calls, equals(['register(1)', 'deregister(1)']));
        expect(api.released, isEmpty);
        api.complete(1);
        expect(api.released, equals([1]));
        api.complete(1);
        expect(api.released, equals([1]));
      });

      test('frees late registrations that failed or cannot withdraw', () async {
        advertiser = make(timeout: const Duration(milliseconds: 10));
        for (final (status, deregister) in [
          (1460, WindowsDnsSdApi.requestPending),
          (0, 87),
        ]) {
          api.deregisterStatus = deregister;
          await expectLater(
            advertiser.register(name: 'S', type: '_apple-midi._udp', port: 1),
            throwsA(isA<MidiNativeError>()),
          );
          api.complete(api.registered.keys.last, status: status);
        }
        expect(api.released, equals([1, 2]));
      });

      test('fails after close', () async {
        await advertiser.close();
        await expectLater(
          advertiser.register(name: 'S', type: '_apple-midi._udp', port: 1),
          throwsStateError,
        );
      });
    });

    group('unregister()', () {
      test('withdraws the registration once', () async {
        final registration = await register();
        final unregistering = registration.unregister();
        await tick();
        api.complete(1);
        await unregistering;
        await registration.unregister();
        expect(api.calls, equals(['register(1)', 'deregister(1)']));
        expect(api.released, equals([1]));
      });

      test('fails when the registrar fails', () async {
        final registration = await register();
        final unregistering = registration.unregister();
        await tick();
        api.complete(1, status: 5);
        await expectLater(
          unregistering,
          throwsA(
            isA<MidiNativeError>()
                .having((e) => e.api, 'api', 'DnsServiceDeRegister')
                .having((e) => e.code, 'code', 5),
          ),
        );
        expect(api.released, equals([1]));
      });

      test('fails when the registrar refuses the call', () async {
        final registration = await register();
        api.deregisterStatus = 87;
        await expectLater(
          registration.unregister(),
          throwsA(isA<MidiNativeError>().having((e) => e.code, 'code', 87)),
        );
        expect(api.released, equals([1]));
      });

      test('frees a withdrawal that completes late', () async {
        advertiser = make(timeout: const Duration(milliseconds: 10));
        final registering = advertiser.register(
          name: 'S',
          type: '_apple-midi._udp',
          port: 1,
        );
        await tick();
        api.complete(1);
        final registration = await registering;
        await expectLater(
          registration.unregister(),
          throwsA(isA<MidiNativeError>()),
        );
        expect(api.released, isEmpty);
        api.complete(1);
        expect(api.released, equals([1]));
      });
    });

    group('close()', () {
      test('withdraws all registrations, then closes the registrar', () async {
        await register();
        api.deregisterStatus = 87;
        await register();
        await advertiser.close();
        await advertiser.close();
        expect(
          api.calls.where((call) => call.startsWith('deregister')),
          hasLength(2),
        );
        expect(api.closed, isTrue);
      });

      test('keeps the registrar open for late answers', () async {
        advertiser = make(timeout: const Duration(milliseconds: 10));
        await expectLater(
          advertiser.register(name: 'S', type: '_apple-midi._udp', port: 1),
          throwsA(isA<MidiNativeError>()),
        );
        await advertiser.close();
        expect(api.closed, isFalse);
      });
    });

    group('shortName(instanceName, type)', () {
      test('strips the service type and domain', () {
        const type = '_apple-midi._udp';
        expect([
          WindowsMidiServiceAdvertiser.shortName(
            'Studio._apple-midi._udp.local',
            type: type,
          ),
          WindowsMidiServiceAdvertiser.shortName(
            'Studio._apple-midi._udp.local.',
            type: type,
          ),
          WindowsMidiServiceAdvertiser.shortName('Other', type: type),
          WindowsMidiServiceAdvertiser.shortName('', type: type),
          WindowsMidiServiceAdvertiser.shortName(null, type: type),
        ], equals(['Studio', 'Studio', 'Other', null, null]));
      });
    });
  });
}
