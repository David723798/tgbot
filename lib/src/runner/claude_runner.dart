import 'package:tgbot/src/runner/base_runner.dart';
import 'package:tgbot/src/runner/runner_support.dart';

/// Runs Claude Code CLI and normalizes output.
class ClaudeRunner extends BaseRunner {
  /// Creates a Claude runner.
  ClaudeRunner({
    required super.command,
    required super.args,
    required super.projectPath,
    required super.timeout,
    super.additionalSystemPrompt,
    super.memory,
    super.memoryFilename,
  });

  @override
  String get providerName => 'Claude';

  @override
  List<String> buildProcessArgs({
    required String wrappedPrompt,
    required String? threadId,
  }) {
    final hasThread = threadId != null && threadId.isNotEmpty;
    return <String>[
      ...args,
      '--verbose',
      '--print',
      '--output-format',
      'stream-json',
      if (hasThread) '--resume',
      if (hasThread) threadId,
      wrappedPrompt,
    ];
  }

  @override
  String? extractFromEvent(Map<String, dynamic> event) {
    final role = event['role']?.toString();
    if (role != null && role != 'assistant') return null;
    final type = event['type']?.toString();
    if (type == 'error' || type == 'tool_use') return null;
    return extractTextFromCommonEvent(event);
  }

  @override
  String? resolveThreadId({
    required String stdoutText,
    required String stderrText,
    required String? currentThreadId,
  }) {
    return extractIdFromJsonLines(stdoutText,
            const <String>['session_id', 'conversation_id', 'thread_id']) ??
        currentThreadId;
  }
}
