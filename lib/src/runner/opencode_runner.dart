import 'dart:convert';

import 'package:tgbot/src/runner/base_runner.dart';
import 'package:tgbot/src/runner/runner_support.dart';

/// Runs OpenCode CLI and normalizes output.
class OpenCodeRunner extends BaseRunner {
  /// Creates an OpenCode runner.
  OpenCodeRunner({
    required super.command,
    required super.args,
    required super.projectPath,
    required super.timeout,
    super.additionalSystemPrompt,
  });

  @override
  String get providerName => 'OpenCode';

  @override
  bool get parsesStderr => true;

  @override
  List<String> buildProcessArgs({
    required String wrappedPrompt,
    required String? threadId,
  }) {
    final hasThread = threadId != null && threadId.isNotEmpty;
    return <String>[
      ...args,
      'run',
      if (hasThread) '--session',
      if (hasThread) threadId,
      '--format',
      'json',
      wrappedPrompt,
    ];
  }

  @override
  String? extractFromEvent(Map<String, dynamic> event) {
    final role = event['role']?.toString();
    if (role != null && role != 'assistant') return null;
    final type = event['type']?.toString();
    if (type == 'error' || type == 'tool_call') return null;
    return extractTextFromCommonEvent(event);
  }

  @override
  List<String> extractFallbackMessages(String stdoutText, String stderrText) {
    final fromStdout = _extractJsonMessages(stdoutText);
    if (fromStdout.isNotEmpty) return fromStdout;
    final fromStderr = _extractJsonMessages(stderrText);
    if (fromStderr.isNotEmpty) return fromStderr;
    final stdoutFallback = stdoutText.trim();
    if (stdoutFallback.isNotEmpty) return <String>[stdoutFallback];
    final stderrFallback = stderrText.trim();
    if (stderrFallback.isNotEmpty) return <String>[stderrFallback];
    return const <String>[];
  }

  @override
  String? resolveThreadId({
    required String stdoutText,
    required String stderrText,
    required String? currentThreadId,
  }) {
    const keys = <String>[
      'conversation_id',
      'session_id',
      'thread_id',
      'conversationId',
      'sessionId',
      'threadId',
      'sessionID',
    ];
    return extractIdFromJsonLines(stdoutText, keys) ??
        extractIdFromJsonLines(stderrText, keys) ??
        currentThreadId;
  }

  @override
  String buildErrorText(String stderrText, String stdoutText) {
    final stderrTrimmed = stderrText.trim();
    if (stderrTrimmed.isNotEmpty) return stderrTrimmed;
    final lines = const LineSplitter()
        .convert(stdoutText)
        .map((line) => line.trimRight())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      return 'OpenCode command failed with no stderr output.';
    }
    final tail =
        lines.skip(lines.length > 20 ? lines.length - 20 : 0).join('\n');
    return tail.length > 2000 ? tail.substring(0, 2000) : tail;
  }

  /// Extracts assistant messages from JSON lines in [output].
  List<String> _extractJsonMessages(String output) {
    final messages = <String>[];
    for (final line in LineSplitter.split(output)) {
      final text = extractAssistantTextFromJsonLine(line);
      if (text == null || text.trim().isEmpty) continue;
      final normalized = text.trim();
      if (messages.isNotEmpty && messages.last == normalized) continue;
      messages.add(normalized);
    }
    return messages;
  }
}
