import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:freegosy/core/save/state_sync_record.dart';
import 'package:freegosy/core/save/state_sync_service.dart';

import '../helpers/state_sync_test_env.dart';

/// Waits until the fake API has recorded at least [count] calls matching
/// [test]. Setup does real file I/O first, so the call can take a moment.
Future<void> _waitForCalls(StateSyncTestEnv env, bool Function(String call) test,
    {int count = 1}) async {
  for (var i = 0; i < 400 && env.api.calls.where(test).length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(env.api.calls.where(test), hasLength(count),
      reason: 'the operation never reached the expected server call');
}

bool _isList(String call) => call == 'list';

void main() {
  late StateSyncTestEnv env;

  setUp(() async => env = await StateSyncTestEnv.create());
  tearDown(() => env.dispose());

  test('a pull does nothing while a push is running for the same game', () async {
    await env.writeState(stateFileA, stateBytes(1));
    env.api.seed('42', stateFileB, stateBytes(2)); // a pull would download this
    env.api.listGate = Completer<void>();

    final push = env.service.pushStates(env.game, env.romPath);
    await _waitForCalls(env, _isList);

    // Without the guard this call would queue behind the held list call, so
    // bound it: the guarded call returns at once.
    final pull = await env.service
        .pullStates(env.game, env.romPath)
        .timeout(const Duration(seconds: 2));

    expect(pull.downloaded, 0);
    expect(pull.conflicts, isEmpty);
    expect(pull.skipped, isFalse, reason: 'busy is not "unavailable"');
    expect(pull.busy, isTrue, reason: 'a manual sync must be able to tell busy from a no-op');
    expect(env.api.calls, ['list'], reason: 'only the push may talk to the server');

    env.api.listGate!.complete();
    expect((await push).uploaded, 1);
  });

  test('a push does nothing while a pull is running for the same game', () async {
    env.api.seed('42', stateFileA, stateBytes(1));
    await env.writeState(stateFileB, stateBytes(2)); // a push would upload this
    env.api.listGate = Completer<void>();

    final pull = env.service.pullStates(env.game, env.romPath);
    await _waitForCalls(env, _isList);

    final push = await env.service
        .pushStates(env.game, env.romPath)
        .timeout(const Duration(seconds: 2));

    expect(push.uploaded, 0);
    expect(push.conflicts, isEmpty);
    expect(push.skipped, isFalse, reason: 'busy is not "unavailable"');
    expect(push.busy, isTrue, reason: 'a manual sync must be able to tell busy from a no-op');
    expect(env.api.calls, ['list'], reason: 'only the pull may talk to the server');

    env.api.listGate!.complete();
    expect((await pull).downloaded, 1);
  });

  test('a normal run and a real no-op are not busy', () async {
    final noop = await env.service.pullStates(env.game, env.romPath);
    expect(noop.busy, isFalse);
    expect(noop.downloaded + noop.uploaded, 0);
    expect((await env.service.pushStates(env.game, env.romPath)).busy, isFalse);

    env.api.seed('42', stateFileA, stateBytes(1));
    await env.writeState(stateFileB, stateBytes(2));
    final pull = await env.service.pullStates(env.game, env.romPath);
    final push = await env.service.pushStates(env.game, env.romPath);

    expect(pull.downloaded, 1);
    expect(pull.busy, isFalse);
    expect(push.uploaded, 1);
    expect(push.busy, isFalse);
  });

  test('none, unavailable and busyGame are told apart', () {
    expect(StateSyncResult.none.busy, isFalse);
    expect(StateSyncResult.none.skipped, isFalse);
    expect(StateSyncResult.unavailable.skipped, isTrue);
    expect(StateSyncResult.unavailable.busy, isFalse);
    expect(StateSyncResult.busyGame.busy, isTrue);
    expect(StateSyncResult.busyGame.skipped, isFalse);
    expect(StateSyncResult.busyGame.downloaded, 0);
    expect(StateSyncResult.busyGame.uploaded, 0);
    expect(StateSyncResult.busyGame.conflicts, isEmpty);
  });

  group('resolveConflict', () {
    late StateConflict conflict;
    late int stateId;

    /// Local = seed 3, server = seed 2, both changed since a synced seed 1.
    setUp(() async {
      stateId = env.api.seed('42', stateFileA, stateBytes(1)).id;
      await env.service.pullStates(env.game, env.romPath);
      await env.writeState(stateFileA, stateBytes(3));
      env.api.touch(stateId, stateBytes(2));
      conflict = (await env.service.pullStates(env.game, env.romPath)).conflicts.single;
      env.api.calls.clear();
    });

    test('returns false and changes nothing while the game is busy', () async {
      env.api.listGate = Completer<void>();
      final pull = env.service.pullStates(env.game, env.romPath);
      await _waitForCalls(env, _isList);

      final ok = await env.service
          .resolveConflict(conflict, choice: 'cloud')
          .timeout(const Duration(seconds: 2));

      expect(ok, isFalse);
      expect(env.stateFile(stateFileA).readAsBytesSync(), stateBytes(3));
      expect(env.stateFile('$stateFileA.bak').existsSync(), isFalse);
      expect(env.api.bytesOf(stateId), stateBytes(2));
      expect(env.api.calls, ['list'], reason: 'a busy resolve must not touch the server');

      env.api.listGate!.complete();
      expect((await pull).conflicts, hasLength(1), reason: 'the conflict is still open');
    });

    test('the game is free again after a resolve fails', () async {
      expect(await env.service.resolveConflict(conflict, choice: 'nope'), isFalse);

      final ok = await env.service.resolveConflict(conflict, choice: 'local');

      expect(ok, isTrue, reason: 'a failed resolve must not lock the game');
    });

    test('the game is free again after a resolve succeeds', () async {
      expect(await env.service.resolveConflict(conflict, choice: 'cloud'), isTrue);

      env.api.touch(stateId, stateBytes(4));
      final pull = await env.service.pullStates(env.game, env.romPath);

      expect(pull.downloaded, 1);
    });
  });

  test('the game is free again after a push fails', () async {
    await env.writeState(stateFileA, stateBytes(1));
    env.api.failList = true;
    expect((await env.service.pushStates(env.game, env.romPath)).uploaded, 0);

    env.api.failList = false;
    final retry = await env.service.pushStates(env.game, env.romPath);

    expect(retry.uploaded, 1, reason: 'a failed push must not lock the game');
  });

  test('the game is free again after a push succeeds', () async {
    await env.writeState(stateFileA, stateBytes(1));
    expect((await env.service.pushStates(env.game, env.romPath)).uploaded, 1);
    env.api.seed('42', stateFileB, stateBytes(2));

    final pull = await env.service.pullStates(env.game, env.romPath);

    expect(pull.downloaded, 1);
  });

  test('a push saves its records after each file, not only at the end', () async {
    await env.writeState(stateFileA, stateBytes(1));
    await env.writeState(stateFileB, stateBytes(2));
    bool isPost(String call) => call.startsWith('POST ');
    final gates = {
      stateFileA: Completer<void>(),
      stateFileB: Completer<void>(),
    };
    env.api.uploadGates.addAll(gates);

    final push = env.service.pushStates(env.game, env.romPath);
    try {
      // Whichever file goes first: let it finish and hold the second one open.
      await _waitForCalls(env, isPost);
      final first = env.api.calls.firstWhere(isPost).substring('POST '.length);
      gates[first]!.complete();
      await _waitForCalls(env, isPost, count: 2);

      final persisted = StateRecordStore(env.pcsx2.prefs).load('42');
      expect(persisted[first]?.hasSynced, isTrue,
          reason: 'the finished upload must be on disk while the next one is still running');
    } finally {
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
    }
    expect((await push).uploaded, 2);
  });

  test('a pull saves its records after each file, not only at the end', () async {
    final stateA = env.api.seed('42', stateFileA, stateBytes(1));
    final stateB = env.api.seed('42', stateFileB, stateBytes(2));
    bool isGet(String call) => call.startsWith('GET ');
    final gates = {
      stateA.id: Completer<void>(),
      stateB.id: Completer<void>(),
    };
    env.api.downloadGates.addAll(gates);
    final nameOf = {stateA.id: stateFileA, stateB.id: stateFileB};

    final pull = env.service.pullStates(env.game, env.romPath);
    try {
      // Whichever state is fetched first: let it finish and hold the second.
      await _waitForCalls(env, isGet);
      final first = int.parse(env.api.calls.firstWhere(isGet).substring('GET '.length));
      gates[first]!.complete();
      await _waitForCalls(env, isGet, count: 2);

      final persisted = StateRecordStore(env.pcsx2.prefs).load('42');
      expect(persisted[nameOf[first]]?.hasSynced, isTrue,
          reason: 'the finished download must be on disk while the next one is still running');
    } finally {
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
    }
    expect((await pull).downloaded, 2);
  });
}
