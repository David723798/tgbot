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
  /// Active sessions by Telegram chat id.
  final Map<int, ChatSession> _sessions = <int, ChatSession>{};

  /// Returns the current session for [chatId], creating one on demand.
  ChatSession current(int chatId) =>
      _sessions.putIfAbsent(chatId, () => ChatSession(version: 1));

  /// Replaces the session for [chatId] with a fresh versioned session.
  ChatSession reset(int chatId) {
    final currentSession = current(chatId);
    // New session object installed for the chat.
    final next = ChatSession(version: currentSession.version + 1)
      ..activeRun = currentSession.activeRun;
    _sessions[chatId] = next;
    return next;
  }

  /// Stores the latest Codex thread id for [chatId].
  void setThreadId(int chatId, String threadId) {
    current(chatId).threadId = threadId;
  }

  /// Tries to mark [run] as the active Codex request for [chatId].
  bool startRun(int chatId, ActiveCodexRun run) {
    final session = current(chatId);
    if (session.activeRun != null) {
      return false;
    }
    session.activeRun = run;
    return true;
  }

  /// Clears [run] if it is still the active request for [chatId].
  void finishRun(int chatId, ActiveCodexRun run) {
    final session = current(chatId);
    if (identical(session.activeRun, run)) {
      session.activeRun = null;
    }
  }

  /// Returns whether a Codex request is currently active for [chatId].
  bool hasActiveRun(int chatId) => current(chatId).activeRun != null;

  /// Cancels the active request for [chatId], if one exists.
  Future<bool> stopRun(int chatId) async {
    final run = current(chatId).activeRun;
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
