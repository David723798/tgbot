import 'package:tgbot/src/runner/claude_runner.dart';
import 'package:tgbot/src/runner/runner_support.dart';

/// Runs Cursor CLI and normalizes stream-json output.
class CursorRunner extends ClaudeRunner {
  /// Creates a Cursor runner.
  CursorRunner({
    required super.command,
    required super.args,
    required super.projectPath,
    required super.timeout,
    super.additionalSystemPrompt,
    super.memory,
    super.memoryFilename,
  });

  @override
  String get providerName => 'Cursor';

  @override
  List<String> buildProcessArgs({
    required String wrappedPrompt,
    required String? threadId,
  }) {
    final hasThread = threadId != null && threadId.isNotEmpty;
    final hasTrustFlag = args.contains('--trust') ||
        args.contains('--yolo') ||
        args.contains('-f');
    return <String>[
      ...args,
      if (!hasTrustFlag) '--trust',
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
    final type = event['type']?.toString();
    if (type == 'assistant') {
      final message = event['message'];
      if (message is Map) {
        return extractTextFromCommonEvent(Map<String, dynamic>.from(message));
      }
      return extractTextFromCommonEvent(event);
    }
    if (type == 'result') {
      final result = event['result'];
      if (result is String && result.trim().isNotEmpty) {
        return result.trim();
      }
    }
    return null;
  }
}
