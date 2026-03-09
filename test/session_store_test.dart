import 'package:test/test.dart';
import 'package:tgbot/src/session/session_store.dart';

void main() {
  test('SessionStore creates, resets, and updates chat sessions', () {
    final store = SessionStore();

    final first = store.current(1);
    expect(first.version, 1);
    expect(first.threadId, isNull);
    expect(identical(first, store.current(1)), isTrue);

    store.setThreadId(1, 'thread-1');
    expect(store.current(1).threadId, 'thread-1');

    final reset = store.reset(1);
    expect(reset.version, 2);
    expect(reset.threadId, isNull);
    expect(identical(reset, first), isFalse);

    expect(store.current(2).version, 1);
  });

  test('SessionStore tracks and stops active runs across resets', () async {
    final store = SessionStore();
    final run = ActiveCodexRun();
    var stopCalls = 0;

    expect(store.startRun(1, run), isTrue);
    expect(store.hasActiveRun(1), isTrue);
    expect(store.startRun(1, ActiveCodexRun()), isFalse);

    store.reset(1);
    run.attachCancel(() async {
      stopCalls++;
    });

    expect(await store.stopRun(1), isTrue);
    expect(stopCalls, 1);

    store.finishRun(1, run);
    expect(store.hasActiveRun(1), isFalse);
    expect(await store.stopRun(1), isFalse);
  });

  test('SessionStore isolates topic sessions within the same chat', () async {
    final store = SessionStore();

    store.setThreadId(1, 'thread-root');
    store.setThreadId(1, 'thread-topic', topicId: 77);

    expect(store.current(1).threadId, 'thread-root');
    expect(store.current(1, topicId: 77).threadId, 'thread-topic');

    store.reset(1, topicId: 77);

    expect(store.current(1).threadId, 'thread-root');
    expect(store.current(1, topicId: 77).threadId, isNull);
  });
}
