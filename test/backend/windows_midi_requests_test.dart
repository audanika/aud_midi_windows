// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:aud_midi_windows/src/backend/windows_midi_requests.dart';
import 'package:test/test.dart';

void main() {
  late WindowsMidiRequests requests;
  late List<int> sent;

  WindowsMidiShimOpenCompleted completion(int request, {int handle = 1}) =>
      WindowsMidiShimOpenCompleted(request: request, status: 0, handle: handle);

  setUp(() {
    requests = WindowsMidiRequests();
    sent = [];
  });

  group('WindowsMidiRequests', () {
    group('run(...), complete(completion)', () {
      test('complete each request with its completion', () async {
        final first = requests.run<WindowsMidiShimOpenCompleted>(
          send: sent.add,
          timeout: const Duration(seconds: 5),
          onTimeout: () => StateError('timeout'),
        );
        final second = requests.run<WindowsMidiShimOpenCompleted>(
          send: sent.add,
          timeout: const Duration(seconds: 5),
          onTimeout: () => StateError('timeout'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(sent, equals([1, 2]));
        expect(requests.waiting, 2);
        expect(requests.complete(completion(2, handle: 22)), isTrue);
        expect(requests.complete(completion(1, handle: 11)), isTrue);
        expect((await first).handle, 11);
        expect((await second).handle, 22);
        expect(requests.waiting, 0);
        expect(requests.complete(completion(1)), isFalse);
      });

      test('fails when send throws', () async {
        await expectLater(
          requests.run<WindowsMidiShimOpenCompleted>(
            send: (_) => throw StateError('send'),
            timeout: const Duration(seconds: 5),
            onTimeout: () => StateError('timeout'),
          ),
          throwsA(
            isA<StateError>().having((e) => e.message, 'message', 'send'),
          ),
        );
        expect(requests.waiting, 0);
      });

      test('fails after the timeout and hands late completions on', () async {
        final late = <WindowsMidiShimOpenCompleted>[];
        final run = requests.run<WindowsMidiShimOpenCompleted>(
          send: sent.add,
          timeout: const Duration(milliseconds: 10),
          onTimeout: () => StateError('timeout'),
          onLate: late.add,
        );
        await expectLater(
          run,
          throwsA(
            isA<StateError>().having((e) => e.message, 'message', 'timeout'),
          ),
        );
        expect(requests.complete(completion(1)), isFalse);
        expect(late, equals([completion(1)]));
        expect(requests.complete(completion(1)), isFalse);
        expect(late, hasLength(1));
      });

      test('drops late completions without onLate', () async {
        final run = requests.run<WindowsMidiShimOpenCompleted>(
          send: sent.add,
          timeout: const Duration(milliseconds: 10),
          onTimeout: () => StateError('timeout'),
        );
        await expectLater(run, throwsA(isA<StateError>()));
        expect(requests.complete(completion(1)), isFalse);
      });
    });

    group('failAll(error)', () {
      test('fails the waiting requests and forgets the late ones', () async {
        final late = <WindowsMidiShimOpenCompleted>[];
        final timedOut = requests.run<WindowsMidiShimOpenCompleted>(
          send: sent.add,
          timeout: const Duration(milliseconds: 10),
          onTimeout: () => StateError('timeout'),
          onLate: late.add,
        );
        await expectLater(timedOut, throwsA(isA<StateError>()));
        final waiting = requests.run<WindowsMidiShimOpenCompleted>(
          send: sent.add,
          timeout: const Duration(seconds: 5),
          onTimeout: () => StateError('timeout'),
        );
        await Future<void>.delayed(Duration.zero);
        requests.failAll(StateError('stopped'));
        await expectLater(
          waiting,
          throwsA(
            isA<StateError>().having((e) => e.message, 'message', 'stopped'),
          ),
        );
        expect(requests.complete(completion(1)), isFalse);
        expect(late, isEmpty);
      });
    });
  });
}
