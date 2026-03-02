typedef RestartRequestHandler = Future<RestartOutcome> Function({
  required int requesterUserId,
  required int requesterChatId,
  required String requesterBotName,
});

/// Outcome returned when `/restart` is requested from Telegram.
class RestartOutcome {
  const RestartOutcome({
    required this.message,
    this.sendToRequester = true,
  });

  /// Human-readable status that is sent back to Telegram.
  final String message;

  /// Whether BridgeApp should send [message] back in the current chat.
  final bool sendToRequester;
}
