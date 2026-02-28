import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/models/telegram_models.dart';
import 'package:tgbot/src/runner/ai_cli_runner.dart';
import 'package:tgbot/src/runner/runner_factory.dart';
import 'package:tgbot/src/session/session_store.dart';
import 'package:tgbot/src/telegram/telegram_client.dart';

/// Coordinates Telegram polling, Codex execution, and per-chat sessions.
class BridgeApp {
  /// Creates a bridge app from its runtime dependencies.
  BridgeApp({
    required this.config,
    required this.telegram,
    required this.codex,
    required this.sessions,
  });

  /// Bot-specific configuration values.
  final AppConfig config;

  /// Telegram API client.
  final TelegramClient telegram;

  /// Provider CLI wrapper used for prompts.
  final AiCliRunner codex;

  /// In-memory session store keyed by Telegram chat id.
  final SessionStore sessions;

  /// Per-chat work queue for normal message handling.
  final Map<int, Future<void>> _chatWork = <int, Future<void>>{};

  /// Builds a fully wired app from a parsed config object.
  factory BridgeApp.fromConfig(AppConfig config) {
    return BridgeApp(
      config: config,
      telegram: TelegramClient(config.botToken),
      codex: createRunner(config),
      sessions: SessionStore(),
    );
  }

  /// Registers bot commands and starts long-polling Telegram updates.
  Future<void> run() async {
    try {
      await telegram.setMyCommands(
        config.telegramCommands
            .map(
              (command) => TelegramBotCommand(
                command: command.command,
                description: command.description,
              ),
            )
            .toList(growable: false),
      );
    } catch (error) {
      stderr.writeln('[${config.name}] Command registration error: $error');
    }

    // Next Telegram update id to request.
    var offset = 0;
    while (true) {
      try {
        final updates = await telegram.getUpdates(
          offset: offset,
          timeoutSec: config.pollTimeoutSec,
        );
        for (final update in updates) {
          offset = update.updateId + 1;
          final message = update.message;
          if (message == null ||
              !config.allowedUserIds.contains(message.fromUserId)) {
            continue;
          }
          if (_isStopCommand(message.text)) {
            _handleMessage(message);
            continue;
          }
          _enqueueMessage(message);
        }
      } catch (error) {
        stderr.writeln('[${config.name}] Polling/handling error: $error');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Handles a single Telegram message from the allowed user.
  Future<void> _handleMessage(TelegramMessage message) async {
    // Trimmed text used for command routing and prompting.
    final text = message.text?.trim();

    if (text == null ||
        text.isEmpty ||
        text == '/start' ||
        text.startsWith('/start ')) {
      final commandsText = config.telegramCommands
          .map((command) => '/${command.command} - ${command.description}')
          .join('\n');
      await telegram.sendMessage(
        chatId: message.chatId,
        text: 'Send any message to chat with Codex.\n$commandsText',
      );
      return;
    }

    if (text == '/new' || text.startsWith('/new ')) {
      sessions.reset(message.chatId);
      await telegram.sendMessage(
        chatId: message.chatId,
        text: '${config.name} has started a new session.',
      );
      return;
    }

    if (_isStopCommand(text)) {
      final stopped = await sessions.stopRun(message.chatId);
      await telegram.sendMessage(
        chatId: message.chatId,
        text: stopped
            ? '${config.name} stopped the active Codex run.'
            : 'No Codex run is active for this chat.',
      );
      return;
    }

    // Prompt sent to Codex after optional command-template expansion.
    var prompt = text;
    for (final command in config.telegramCommands) {
      // Telegram slash-command prefix being matched.
      final prefix = '/${command.command}';
      if (!text.startsWith(prefix)) {
        continue;
      }
      if (text.length > prefix.length && text[prefix.length] != ' ') {
        continue;
      }
      // Text after the slash command, passed into the configured template.
      final commandArgs = text.length > prefix.length
          ? text.substring(prefix.length).trim()
          : '';
      prompt = _buildCommandPrompt(command, commandArgs);
      break;
    }

    try {
      // Session associated with the current Telegram chat.
      final session = sessions.current(message.chatId);
      // Session version captured before this request starts.
      final sessionVersion = session.version;
      // Cancellation handle registered for the in-flight Codex process.
      final activeRun = ActiveCodexRun();
      if (!sessions.startRun(message.chatId, activeRun)) {
        await telegram.sendMessage(
          chatId: message.chatId,
          text: 'A Codex run is already active. Send /stop to cancel it.',
        );
        return;
      }
      // Canonical assistant messages already delivered for this request.
      final deliveredMessages = <String>{};
      // Helper that keeps Telegram's typing indicator active.
      final typingSignal = _TypingSignal(
        telegram: telegram,
        chatId: message.chatId,
      );
      Future<void> sendAssistantMessage(String assistantMessage) async {
        final normalized = _normalizeMessageForDedup(assistantMessage);
        if (normalized.isEmpty || !deliveredMessages.add(normalized)) {
          return;
        }
        await telegram.sendMessage(
            chatId: message.chatId, text: assistantMessage);
      }

      // Final structured result returned by the Codex runner.
      CodexResult result;
      try {
        await typingSignal.start();
        result = await codex.runPrompt(
          prompt: prompt,
          threadId: session.threadId,
          onCancelReady: activeRun.attachCancel,
          onAssistantMessage: config.finalResponseOnly
              ? null
              : (assistantMessage) async {
                  await typingSignal.stop();
                  await sendAssistantMessage(assistantMessage);
                },
        );
      } finally {
        await typingSignal.stop();
        sessions.finishRun(message.chatId, activeRun);
      }
      // Thread id used to resume the same Codex conversation later.
      final nextThreadId = result.threadId;
      if (nextThreadId != null &&
          nextThreadId.isNotEmpty &&
          sessions.current(message.chatId).version == sessionVersion) {
        sessions.setThreadId(message.chatId, nextThreadId);
      }
      // Messages to deliver after excluding ones already streamed.
      final messagesToSend = config.finalResponseOnly
          ? <String>[_resolveFinalAssistantMessage(result)]
          : (result.messages.isEmpty ? <String>[result.text] : result.messages);
      for (final codexMessage in messagesToSend) {
        await sendAssistantMessage(codexMessage);
      }
      for (final artifact in result.artifacts) {
        // Verified local path for the file/image artifact.
        final resolved = _resolveSafePath(artifact.path);
        if (artifact.kind == 'image') {
          await telegram.sendPhoto(
            chatId: message.chatId,
            filePath: resolved,
            caption: artifact.caption,
          );
        } else {
          await telegram.sendDocument(
            chatId: message.chatId,
            filePath: resolved,
            caption: artifact.caption,
          );
        }
      }
    } on CodexCancelledException {
      return;
    } catch (error) {
      await _sendErrorMessage(chatId: message.chatId, error: error);
    }
  }

  /// Queues [message] behind any in-flight work for the same chat.
  void _enqueueMessage(TelegramMessage message) {
    final previous = _chatWork[message.chatId] ?? Future<void>.value();
    final next =
        previous.catchError((_) {}).then((_) => _handleMessage(message));
    _chatWork[message.chatId] = next.whenComplete(() {
      if (identical(_chatWork[message.chatId], next)) {
        _chatWork.remove(message.chatId);
      }
    });
  }

  /// Returns whether [text] targets the built-in `/stop` command.
  bool _isStopCommand(String? text) {
    if (text == null) {
      return false;
    }
    final trimmed = text.trim();
    return trimmed == '/stop' || trimmed.startsWith('/stop ');
  }

  /// Builds a stable key for duplicate Telegram message suppression.
  String _normalizeMessageForDedup(String value) {
    final unified = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = LineSplitter.split(unified)
        .map((line) => line.trimRight())
        .toList(growable: false);
    return lines.join('\n').trim();
  }

  /// Picks the best final assistant message from provider output.
  String _resolveFinalAssistantMessage(CodexResult result) {
    for (var i = result.messages.length - 1; i >= 0; i--) {
      final candidate = result.messages[i].trim();
      if (candidate.isNotEmpty) {
        return result.messages[i];
      }
    }
    return result.text;
  }

  /// Sends a concise error reply and falls back to a generic message on failure.
  Future<void> _sendErrorMessage({
    required int chatId,
    required Object error,
  }) async {
    final primary = _formatErrorForUser(error);
    try {
      await telegram.sendMessage(chatId: chatId, text: primary);
      return;
    } catch (fallbackError) {
      // Primary error delivery failed; send a generic fallback.
      stderr.writeln(
        '[${config.name}] Failed to send error message: $fallbackError',
      );
      await telegram.sendMessage(
        chatId: chatId,
        text: 'Error: provider command failed. Check logs for details.',
      );
    }
  }

  /// Builds a Telegram-safe, compact user-facing error string.
  String _formatErrorForUser(Object error) {
    if (error is ProcessException) {
      final code = error.errorCode;
      final suffix = code == 0 ? '' : ' (exit code $code)';
      final details = _sanitizeErrorDetails(error.message);
      if (details.isEmpty) {
        return 'Provider command failed$suffix.';
      }
      return 'Provider command failed$suffix: $details';
    }
    return 'Error: $error';
  }

  /// Normalizes process stderr/stdout details to a short single-line snippet.
  String _sanitizeErrorDetails(String raw) {
    final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) {
      return '';
    }
    if (collapsed.length <= 500) {
      return collapsed;
    }
    return '${collapsed.substring(0, 500)}...';
  }

  /// Renders a configured Telegram command into the prompt sent to Codex.
  String _buildCommandPrompt(
    ConfiguredTelegramCommand command,
    String commandArgs,
  ) {
    // Command description reused as a prompt template.
    final template = command.description;
    if (template.contains('{args}')) {
      // Template after substituting the command arguments placeholder.
      final rendered = template.replaceAll('{args}', commandArgs).trim();
      if (rendered.isNotEmpty) {
        return rendered;
      }
    }
    if (commandArgs.isEmpty) {
      return template;
    }
    return '$template\n\n$commandArgs';
  }

  /// Resolves an artifact path and ensures it stays inside the project root.
  String _resolveSafePath(String artifactPath) {
    // Canonical absolute project root used for containment checks.
    final root = p.normalize(p.absolute(config.projectPath));
    // Canonical absolute artifact path.
    final full = p.normalize(
      p.isAbsolute(artifactPath)
          ? artifactPath
          : p.join(config.projectPath, artifactPath),
    );

    if (!(full == root || p.isWithin(root, full))) {
      throw StateError('Artifact path is outside project_path: $artifactPath');
    }

    // Filesystem handle used to verify the artifact exists.
    final file = File(full);
    if (!file.existsSync()) {
      throw StateError('Artifact file not found: $artifactPath');
    }
    return full;
  }
}

/// Sends periodic `typing` chat actions while Codex is running.
class _TypingSignal {
  /// Creates a typing-signal helper for one chat.
  _TypingSignal({required this.telegram, required this.chatId});

  /// Telegram client used to send chat actions.
  final TelegramClient telegram;

  /// Target chat id that should receive typing events.
  final int chatId;

  /// Repeating timer that refreshes the typing indicator.
  Timer? _timer;

  /// Guards against sending after the signal has been stopped.
  bool _stopped = false;

  /// Starts the typing loop if it is not already active.
  Future<void> start() async {
    if (_stopped || _timer != null) {
      return;
    }
    await _send();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      _send();
    });
  }

  /// Stops the typing loop for the current request.
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Sends one `typing` action and suppresses non-fatal delivery errors.
  Future<void> _send() async {
    if (_stopped) {
      return;
    }
    try {
      await telegram.sendChatAction(chatId: chatId, action: 'typing');
    } catch (_) {
      // Chat action failures should not interrupt the main response flow.
    }
  }
}
