import 'dart:convert';

import 'package:tgbot/src/runner/base_runner.dart';
import 'package:tgbot/src/runner/runner_support.dart';

/// Runs Gemini CLI and normalizes output.
class GeminiRunner extends BaseRunner {
  /// Creates a Gemini runner.
  GeminiRunner({
    required String command,
    required List<String> args,
    required String projectPath,
    required Duration timeout,
    String? additionalSystemPrompt,
  }) : super(
          command: command,
          args: args,
          projectPath: projectPath,
          timeout: timeout,
          additionalSystemPrompt: additionalSystemPrompt,
        );

  @override
  String get providerName => 'Gemini';

  @override
  List<String> buildProcessArgs({
    required String wrappedPrompt,
    required String? threadId,
  }) {
    final hasThread = threadId != null && threadId.isNotEmpty;
    return <String>[
      ...args,
      if (hasThread) '--resume',
      if (hasThread) threadId,
      '--prompt',
      wrappedPrompt,
      '--output-format',
      'json',
    ];
  }

  @override
  String? extractFromEvent(Map<String, dynamic> event) {
    return extractTextFromCommonEvent(event);
  }

  @override
  List<String> extractFallbackMessages(String stdoutText, String stderrText) {
    var messages = _extractMessages(stdoutText);
    if (messages.isEmpty) {
      messages = <String>[stdoutText.trim()];
    }
    return messages
        .where((m) => m.trim().isNotEmpty)
        .toList(growable: false);
  }

  @override
  String? resolveThreadId({
    required String stdoutText,
    required String stderrText,
    required String? currentThreadId,
  }) {
    return _extractThreadId(stdoutText) ?? currentThreadId;
  }

  /// Extracts the next session/thread id from Gemini output.
  String? _extractThreadId(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return null;
    try {
      final parsed = jsonDecode(trimmed);
      final id = _findIdInJsonValue(parsed);
      if (id != null && id.isNotEmpty) return id;
    } catch (_) {
      // Ignore parse errors and fall back to JSONL extraction.
    }
    return extractIdFromJsonLines(
      output,
      const <String>['session_id', 'conversation_id', 'thread_id'],
    );
  }

  /// Recursively finds known id keys in an arbitrary JSON value.
  String? _findIdInJsonValue(Object? value) {
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      for (final key in const <String>[
        'session_id',
        'conversation_id',
        'thread_id'
      ]) {
        final candidate = map[key];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate.trim();
        }
      }
      for (final entry in map.values) {
        final nested = _findIdInJsonValue(entry);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    } else if (value is List) {
      for (final entry in value) {
        final nested = _findIdInJsonValue(entry);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return null;
  }

  /// Extracts assistant text messages from Gemini output payloads.
  List<String> _extractMessages(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return const <String>[];
    try {
      final parsed = jsonDecode(trimmed);
      final texts = <String>[];
      _collectText(parsed, texts);
      final deduped = <String>[];
      for (final text in texts) {
        final normalized = text.trim();
        if (normalized.isEmpty) continue;
        if (deduped.isEmpty || deduped.last != normalized) {
          deduped.add(normalized);
        }
      }
      if (deduped.isNotEmpty) return deduped;
    } catch (_) {
      // Fall back to line-delimited JSON extraction.
      return extractAssistantMessagesFromJsonLines(output, (event) {
        return extractTextFromCommonEvent(event);
      });
    }
    return extractAssistantMessagesFromJsonLines(output, (event) {
      return extractTextFromCommonEvent(event);
    });
  }

  /// Recursively collects string text content from parsed JSON nodes.
  void _collectText(Object? value, List<String> out) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) out.add(trimmed);
      return;
    }
    if (value is List) {
      for (final entry in value) {
        _collectText(entry, out);
      }
      return;
    }
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      for (final key in const <String>[
        'text',
        'output',
        'response',
        'content'
      ]) {
        if (map.containsKey(key)) _collectText(map[key], out);
      }
      return;
    }
  }
}
