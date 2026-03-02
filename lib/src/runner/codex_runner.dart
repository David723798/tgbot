import 'dart:convert';

import 'package:tgbot/src/runner/base_runner.dart';
import 'package:tgbot/src/runner/runner_support.dart';

export 'package:tgbot/src/runner/ai_cli_runner.dart'
    show AiCliRunner, CodexCancelledException, CodexResult;

/// Runs Codex, streams assistant output, and extracts bridge artifacts.
class CodexRunner extends BaseRunner {
  /// Creates a Codex runner.
  CodexRunner({
    required super.command,
    required super.args,
    required super.projectPath,
    required super.timeout,
    super.additionalSystemPrompt,
  });

  @override
  String get providerName => 'Codex';

  @override
  List<String> buildProcessArgs({
    required String wrappedPrompt,
    required String? threadId,
  }) {
    final hasThread = threadId != null && threadId.isNotEmpty;
    return <String>[
      ...args,
      'exec',
      if (hasThread) 'resume',
      '--skip-git-repo-check',
      '--json',
      if (hasThread) threadId,
      wrappedPrompt,
    ];
  }

  @override
  String? extractFromEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (type == 'item.completed') {
      return _extractAssistantTextFromMap(event['item']);
    }
    if (type == 'assistant_message') {
      return _extractAssistantTextFromMap(event);
    }
    if (event.containsKey('message')) {
      return _extractAssistantTextFromMap(event['message']);
    }
    return null;
  }

  @override
  List<String> extractFallbackMessages(String stdoutText, String stderrText) {
    return extractAssistantMessagesFromJsonLines(stdoutText, extractFromEvent);
  }

  @override
  String? resolveThreadId({
    required String stdoutText,
    required String stderrText,
    required String? currentThreadId,
  }) {
    return _extractThreadId(stdoutText) ?? currentThreadId;
  }

  /// Extracts the Codex thread id from `thread.started` events.
  String? _extractThreadId(String output) {
    for (final line in const LineSplitter().convert(output)) {
      final candidate = line.trim();
      if (!candidate.startsWith('{') || !candidate.endsWith('}')) continue;
      try {
        final parsed = jsonDecode(candidate) as Map<String, dynamic>;
        if (parsed['type'] == 'thread.started') {
          final id = parsed['thread_id']?.toString();
          if (id != null && id.isNotEmpty) return id;
        }
      } catch (_) {
        // Skip malformed JSON lines.
        continue;
      }
    }
    return null;
  }

  /// Extracts assistant text from event `message`/`item` payload maps.
  String? _extractAssistantTextFromMap(Object? value) {
    if (value is! Map) return null;
    final item = Map<String, dynamic>.from(value);
    final role = item['role']?.toString();
    if (role != null && role != 'assistant') return null;
    final content = item['content'];
    if (content is List) {
      final parts = <String>[];
      for (final entry in content) {
        if (entry is! Map) continue;
        final mapEntry = Map<String, dynamic>.from(entry);
        final contentType = mapEntry['type']?.toString();
        if (contentType != null &&
            contentType != 'output_text' &&
            contentType != 'text') {
          continue;
        }
        final text = mapEntry['text'];
        if (text is String && text.trim().isNotEmpty) {
          parts.add(text.trim());
        } else if (text is Map &&
            text['value'] is String &&
            (text['value'] as String).trim().isNotEmpty) {
          parts.add((text['value'] as String).trim());
        }
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }
    final direct = item['text'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    return null;
  }
}
