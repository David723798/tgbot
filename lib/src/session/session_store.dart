/// Tracks one Telegram chat's Codex session metadata.
class ChatSession {
  /// Creates a chat session record.
  ChatSession({required this.version, this.threadId});

  /// Session version incremented whenever the chat is reset.
  final int version;

  /// Active Codex thread id for the session, if available.
  String? threadId;

  /// In-flight Codex run for this chat, if one is active.
  ActiveCodexRun? activeRun;
}

/// Unique session scope for one chat or one chat topic.
class SessionScope {
  const SessionScope({required this.chatId, this.topicId});

  final int chatId;
  final int? topicId;

  @override
  bool operator ==(Object other) =>
      other is SessionScope &&
      other.chatId == chatId &&
      other.topicId == topicId;

  @override
  int get hashCode => Object.hash(chatId, topicId);
}

/// Cancellation handle for one in-flight Codex process.
class ActiveCodexRun {
  /// Whether cancellation has already been requested.
  bool _stopRequested = false;

  /// Future returned by the first cancellation attempt.
  Future<void>? _stopFuture;

  /// Completes once the process-level canceller is available.
  Future<void> Function()? _cancel;

  /// Registers the callback that terminates the underlying process.
  void attachCancel(Future<void> Function() cancel) {
    _cancel = cancel;
    if (_stopRequested && _stopFuture == null) {
      _stopFuture = cancel();
    }
  }

  /// Requests termination of the active Codex run.
  Future<void> stop() {
    _stopRequested = true;
    final cancel = _cancel;
    if (cancel == null) {
      return _stopFuture ?? Future<void>.value();
    }
    return _stopFuture ??= cancel();
  }
}

/// In-memory store of chat sessions keyed by Telegram chat id.
class SessionStore {
  /// Active sessions by Telegram chat id and optional topic id.
  final Map<SessionScope, ChatSession> _sessions =
      <SessionScope, ChatSession>{};

  SessionScope scope(int chatId, {int? topicId}) =>
      SessionScope(chatId: chatId, topicId: topicId);

  /// Returns the current session for [chatId], creating one on demand.
  ChatSession current(int chatId, {int? topicId}) => _sessions.putIfAbsent(
        scope(chatId, topicId: topicId),
        () => ChatSession(version: 1),
      );

  /// Replaces the session for [chatId] with a fresh versioned session.
  ChatSession reset(int chatId, {int? topicId}) {
    final key = scope(chatId, topicId: topicId);
    final currentSession = current(chatId, topicId: topicId);
    // New session object installed for the chat.
    final next = ChatSession(version: currentSession.version + 1)
      ..activeRun = currentSession.activeRun;
    _sessions[key] = next;
    return next;
  }

  /// Stores the latest Codex thread id for [chatId].
  void setThreadId(int chatId, String threadId, {int? topicId}) {
    current(chatId, topicId: topicId).threadId = threadId;
  }

  /// Tries to mark [run] as the active Codex request for [chatId].
  bool startRun(int chatId, ActiveCodexRun run, {int? topicId}) {
    final session = current(chatId, topicId: topicId);
    if (session.activeRun != null) {
      return false;
    }
    session.activeRun = run;
    return true;
  }

  /// Clears [run] if it is still the active request for [chatId].
  void finishRun(int chatId, ActiveCodexRun run, {int? topicId}) {
    final session = current(chatId, topicId: topicId);
    if (identical(session.activeRun, run)) {
      session.activeRun = null;
    }
  }

  /// Returns whether a Codex request is currently active for [chatId].
  bool hasActiveRun(int chatId, {int? topicId}) =>
      current(chatId, topicId: topicId).activeRun != null;

  /// Cancels the active request for [chatId], if one exists.
  Future<bool> stopRun(int chatId, {int? topicId}) async {
    final run = current(chatId, topicId: topicId).activeRun;
    if (run == null) {
      return false;
    }
    await run.stop();
    return true;
  }

  /// Cancels all active requests across chats.
  Future<void> stopAllRuns() async {
    final futures = <Future<void>>[];
    for (final session in _sessions.values) {
      final run = session.activeRun;
      if (run != null) {
        futures.add(run.stop());
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait<void>(futures);
    }
  }
}
