import 'dart:async';

import 'package:tgbot/src/models/telegram_models.dart';

/// Normalized output returned by an AI CLI invocation.
class CodexResult {
  /// Creates a result object for a completed run.
  CodexResult({
    required this.text,
    required this.messages,
    this.artifacts = const <ArtifactResponse>[],
    this.threadId,
  });

  /// Final plain-text reply used as a fallback summary.
  final String text;

  /// Assistant messages extracted from the stream.
  final List<String> messages;

  /// File or image artifacts discovered in the output.
  final List<ArtifactResponse> artifacts;

  /// Conversation id used to resume when supported by the provider.
  final String? threadId;

  /// Returns the first artifact, if any, for backwards compatibility.
  ArtifactResponse? get artifact => artifacts.isEmpty ? null : artifacts.first;
}

/// Thrown when an AI CLI process is intentionally terminated.
class CodexCancelledException implements Exception {
  /// Returns a concise cancellation message for logs and user errors.
  @override
  String toString() => 'AI CLI run cancelled.';
}

/// Common interface for provider-specific CLI runners.
abstract class AiCliRunner {
  /// Executes [prompt] and returns parsed text, artifacts, and thread id.
  Future<CodexResult> runPrompt({
    required String prompt,
    String? threadId,
    FutureOr<void> Function(String message)? onAssistantMessage,
    void Function(Future<void> Function() cancel)? onCancelReady,
  });
}
