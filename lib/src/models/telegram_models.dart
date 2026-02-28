/// Telegram update payload with the subset used by the bridge.
class TelegramUpdate {
  /// Creates a parsed Telegram update.
  TelegramUpdate({required this.updateId, this.message});

  /// Monotonic Telegram update id.
  final int updateId;

  /// Message payload when this update contains a message.
  final TelegramMessage? message;

  /// Parses a Telegram update from JSON.
  factory TelegramUpdate.fromJson(Map<String, dynamic> json) {
    return TelegramUpdate(
      updateId: json['update_id'] as int,
      message: json['message'] == null
          ? null
          : TelegramMessage.fromJson(json['message'] as Map<String, dynamic>),
    );
  }
}

/// Minimal Telegram message model used by the bridge.
class TelegramMessage {
  /// Creates a parsed Telegram message.
  TelegramMessage({
    required this.chatId,
    required this.fromUserId,
    required this.text,
  });

  /// Chat id where the message was received.
  final int chatId;

  /// Sender user id.
  final int fromUserId;

  /// Text body, when the message contains text.
  final String? text;

  /// Parses a Telegram message from JSON.
  factory TelegramMessage.fromJson(Map<String, dynamic> json) {
    // Nested chat object from the Telegram payload.
    final chat = json['chat'] as Map<String, dynamic>;
    // Optional sender object from the Telegram payload.
    final from = json['from'] as Map<String, dynamic>?;

    return TelegramMessage(
      chatId: chat['id'] as int,
      fromUserId: (from?['id'] ?? 0) as int,
      text: json['text'] as String?,
    );
  }
}

/// File or image artifact extracted from Codex output.
class ArtifactResponse {
  /// Creates an artifact description for Telegram delivery.
  ArtifactResponse({required this.kind, required this.path, this.caption});

  /// Artifact kind, expected to be `image` or `file`.
  final String kind;

  /// Relative or absolute path to the local artifact file.
  final String path;

  /// Optional caption sent with the artifact upload.
  final String? caption;
}
