import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tgbot/src/runner/ai_cli_runner.dart';
import 'package:tgbot/src/runner/runner_support.dart';

/// Common fields and orchestration shared by all provider runners.
///
/// Subclasses implement [buildProcessArgs], [extractFromEvent],
/// and [resolveThreadId] for provider-specific behavior.
abstract class BaseRunner implements AiCliRunner {
  /// Creates a runner with shared configuration.
  BaseRunner({
    required this.command,
    required this.args,
    required this.projectPath,
    required this.timeout,
    this.additionalSystemPrompt,
  });

  /// Executable used to launch the provider CLI.
  final String command;

  /// Static arguments prepended to every invocation.
  final List<String> args;

  /// Working directory where the provider runs.
  final String projectPath;

  /// Maximum allowed runtime for one request.
  final Duration timeout;

  /// Extra system prompt appended ahead of the user request.
  final String? additionalSystemPrompt;

  /// Human-readable provider name used in timeout error messages.
  String get providerName;

  /// Builds the CLI argument list for this provider.
  List<String> buildProcessArgs({
    required String wrappedPrompt,
    required String? threadId,
  });

  /// Extracts assistant text from a single parsed JSON event.
  /// Returns null if the event is not relevant.
  String? extractFromEvent(Map<String, dynamic> event);

  /// Extracts the thread/session ID from process output.
  String? resolveThreadId({
    required String stdoutText,
    required String stderrText,
    required String? currentThreadId,
  });

  /// Whether stderr should also be parsed for assistant messages.
  /// Default is false; override to true for providers that emit
  /// messages on stderr.
  bool get parsesStderr => false;

  /// Extracts messages from buffered output when nothing was captured
  /// during streaming. Default uses [extractAssistantMessagesFromJsonLines]
  /// with [extractFromEvent].
  List<String> extractFallbackMessages(String stdoutText, String stderrText) {
    return extractAssistantMessagesFromJsonLines(stdoutText, extractFromEvent);
  }

  /// Builds error text for non-zero exit codes. Default: trimmed stderr.
  String buildErrorText(String stderrText, String stdoutText) =>
      stderrText.trim();

  /// Parses one JSON line using [extractFromEvent].
  String? extractAssistantTextFromJsonLine(String line) {
    final candidate = line.trim();
    if (!candidate.startsWith('{') || !candidate.endsWith('}')) return null;
    try {
      final parsed = jsonDecode(candidate) as Map<String, dynamic>;
      return extractFromEvent(parsed);
    } catch (_) {
      // Skip malformed JSON lines.
      return null;
    }
  }

  @override
  Future<CodexResult> runPrompt({
    required String prompt,
    String? threadId,
    FutureOr<void> Function(String message)? onAssistantMessage,
    void Function(Future<void> Function() cancel)? onCancelReady,
  }) async {
    final wrappedPrompt = normalizePromptForProcessArg(buildPrompt(
      userPrompt: prompt,
      additionalSystemPrompt: additionalSystemPrompt,
    ));
    final processArgs = buildProcessArgs(
      wrappedPrompt: wrappedPrompt,
      threadId: threadId,
    );

    final process = await startProcess(
      command: command,
      processArgs: processArgs,
      workingDirectory: projectPath,
    );
    var cancelled = false;
    onCancelReady?.call(() async {
      cancelled = true;
      if (!process.kill()) return;
      try {
        await process.exitCode;
      } catch (_) {
        // Process may already have exited.
      }
    });

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final streamedMessages = <String>[];

    Future<void> handleLine(String line, StringBuffer buffer) async {
      buffer.writeln(line);
      final text = extractAssistantTextFromJsonLine(line);
      if (text == null || text.trim().isEmpty) return;
      final normalized = text.trim();
      if (streamedMessages.isNotEmpty && streamedMessages.last == normalized) {
        return;
      }
      streamedMessages.add(normalized);
      if (onAssistantMessage != null) await onAssistantMessage(normalized);
    }

    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asyncMap((line) => handleLine(line, stdoutBuffer))
        .drain<void>();

    final Future<void> stderrFuture;
    if (parsesStderr) {
      stderrFuture = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asyncMap((line) => handleLine(line, stderrBuffer))
          .drain<void>();
    } else {
      stderrFuture = process.stderr.transform(utf8.decoder).join().then((text) {
        stderrBuffer.write(text);
      });
    }

    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException('$providerName command timed out.');
      },
    );

    await Future.wait<void>([stdoutFuture, stderrFuture]);
    final stdoutText = stdoutBuffer.toString();
    final stderrText = stderrBuffer.toString();

    if (code != 0) {
      if (cancelled) throw CodexCancelledException();
      throw ProcessException(
        command,
        processArgs,
        buildErrorText(stderrText, stdoutText),
        code,
      );
    }

    final extractedMessages = streamedMessages.isEmpty
        ? extractFallbackMessages(stdoutText, stderrText)
        : List<String>.from(streamedMessages);

    // Deliver non-streamed messages via callback so callers that depend
    // on onAssistantMessage (e.g. non-streaming providers) receive them.
    if (streamedMessages.isEmpty && onAssistantMessage != null) {
      for (final message in extractedMessages) {
        await onAssistantMessage(message);
      }
    }

    final parsed = parseAssistantMessages(extractedMessages);
    final nextThreadId = resolveThreadId(
      stdoutText: stdoutText,
      stderrText: stderrText,
      currentThreadId: threadId,
    );

    return CodexResult(
      text: parsed.text,
      messages: parsed.messages,
      artifacts: parsed.artifacts,
      threadId: nextThreadId,
    );
  }
}
