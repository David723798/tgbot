import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/logger.dart';
import 'package:tgbot/src/models/telegram_models.dart';
import 'package:tgbot/src/runtime/bot_app.dart';
import 'package:tgbot/src/runtime/restart_contract.dart';
import 'package:tgbot/src/runner/ai_cli_runner.dart';
import 'package:tgbot/src/runner/runner_factory.dart';
import 'package:tgbot/src/session/session_store.dart';
import 'package:tgbot/src/telegram/telegram_client.dart';

/// Coordinates Telegram polling, provider execution, and per-chat sessions.
class BridgeApp implements BotApp {
  /// Creates a bridge app from its runtime dependencies.
  BridgeApp({
    required this.config,
    required this.telegram,
    AiCliRunner? runner,
    AiCliRunner? codex,
    this.onRestartRequested,
    required this.sessions,
    AppLogger? logger,
  })  : assert(runner != null || codex != null),
        runner = runner ?? codex!,
        logger = logger ??
            AppLogger(
              botName: config.name,
              provider: config.provider,
              level: config.logLevel,
              format: config.logFormat,
            );

  /// Bot-specific configuration values.
  @override
  final AppConfig config;

  /// Telegram API client.
  final TelegramClient telegram;

  /// Provider CLI wrapper used for prompts.
  final AiCliRunner runner;

  /// Backwards-compatible alias for the provider runner.
  AiCliRunner get codex => runner;

  /// In-memory session store keyed by Telegram chat id.
  final SessionStore sessions;

  /// Runtime logger.
  final AppLogger logger;

  /// Callback used to request a process-level restart.
  final RestartRequestHandler? onRestartRequested;

  /// Per-chat work queue for normal message handling.
  final Map<int, Future<void>> _chatWork = <int, Future<void>>{};

  bool _running = false;
  bool _disposed = false;
  int _requestSeq = 0;
  int _processedCount = 0;
  int _errorCount = 0;

  /// Builds a fully wired app from a parsed config object.
  factory BridgeApp.fromConfig(
    AppConfig config, {
    RestartRequestHandler? onRestartRequested,
  }) {
    return BridgeApp(
      config: config,
      telegram: TelegramClient(config.botToken),
      runner: createRunner(config),
      onRestartRequested: onRestartRequested,
      sessions: SessionStore(),
    );
  }

  /// Registers bot commands and starts long-polling Telegram updates.
  @override
  Future<void> run() async {
    if (_running) {
      return;
    }
    _running = true;
    logger.info('bridge_started', fields: <String, Object?>{
      'poll_timeout_sec': config.pollTimeoutSec,
      'allowed_user_count': config.allowedUserIds.length,
      'allowed_chat_count': config.allowedChatIds.length,
    });

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
      logger.warn(
        'command_registration_failed',
        fields: <String, Object?>{'error': error.toString()},
      );
    }

    var offset = 0;
    while (_running) {
      try {
        final updates = await telegram.getUpdates(
          offset: offset,
          timeoutSec: config.pollTimeoutSec,
        );
        for (final update in updates) {
          if (!_running) {
            break;
          }
          offset = update.updateId + 1;
          final message = update.message;
          if (message == null || !_isAuthorizedMessage(message)) {
            continue;
          }
          if (_isStopCommand(message.text) || _isRestartCommand(message.text)) {
            unawaited(_handleMessage(message));
            continue;
          }
          _enqueueMessage(message);
        }
      } catch (error) {
        if (!_running) {
          break;
        }
        _errorCount++;
        logger.error(
          'polling_failed',
          fields: <String, Object?>{'error': error.toString()},
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    await _drainQueuedWork();
    await _dispose();
    logger.info('bridge_stopped', fields: <String, Object?>{
      'processed_count': _processedCount,
      'error_count': _errorCount,
    });
  }

  /// Stops polling and in-flight runs, then closes Telegram resources.
  @override
  Future<void> stop() async {
    if (!_running) {
      await _dispose();
      return;
    }
    _running = false;
    logger.info('bridge_stopping');
    await sessions.stopAllRuns();
    await _dispose();
  }

  /// Handles a single Telegram message from the allowed user.
  Future<void> _handleMessage(TelegramMessage message) async {
    final requestId = '${message.chatId}-${++_requestSeq}';
    final startedAt = DateTime.now();

    final text = message.text?.trim();

    if (text == null ||
        text.isEmpty ||
        text == '/start' ||
        text.startsWith('/start ')) {
      final commandsText = config.telegramCommands
          .map((command) => '/${command.command} - ${command.description}')
          .join('\n');
      await _sendControlMessage(
        chatId: message.chatId,
        text:
            'Send any message to chat with ${_providerLabel()}.\n$commandsText',
      );
      return;
    }

    if (text == '/new' || text.startsWith('/new ')) {
      sessions.reset(message.chatId);
      await _sendControlMessage(
        chatId: message.chatId,
        text: '${config.name} has started a new session.',
      );
      return;
    }

    if (_isStopCommand(text)) {
      final stopped = await sessions.stopRun(message.chatId);
      await _sendControlMessage(
        chatId: message.chatId,
        text: stopped
            ? '${config.name} stopped the active ${_providerLabel()} run.'
            : 'No ${_providerLabel()} run is active for this chat.',
      );
      return;
    }

    if (_isRestartCommand(text)) {
      final handler = onRestartRequested;
      if (handler == null) {
        await _sendControlMessage(
          chatId: message.chatId,
          text: 'Restart is not enabled for this bot runtime.',
        );
        return;
      }
      await _sendControlMessage(
        chatId: message.chatId,
        text: 'Restart requested. Reloading config and restarting all bots...',
      );
      final outcome = await handler(
        requesterUserId: message.fromUserId,
        requesterChatId: message.chatId,
        requesterBotName: config.name,
      );
      if (outcome.sendToRequester) {
        await _sendControlMessage(
            chatId: message.chatId, text: outcome.message);
      }
      return;
    }

    var prompt = text;
    for (final command in config.telegramCommands) {
      final prefix = '/${command.command}';
      if (!text.startsWith(prefix)) {
        continue;
      }
      if (text.length > prefix.length && text[prefix.length] != ' ') {
        continue;
      }
      final commandArgs = text.length > prefix.length
          ? text.substring(prefix.length).trim()
          : '';
      prompt = _buildCommandPrompt(command, commandArgs);
      break;
    }

    logger.info('request_started', fields: <String, Object?>{
      'request_id': requestId,
      'chat_id': message.chatId,
      'from_user_id': message.fromUserId,
      'prompt_length': prompt.length,
      'final_response_only': config.finalResponseOnly,
    });

    try {
      final session = sessions.current(message.chatId);
      final sessionVersion = session.version;
      final activeRun = ActiveCodexRun();
      if (!sessions.startRun(message.chatId, activeRun)) {
        await telegram.sendMessage(
          chatId: message.chatId,
          text:
              'An ${_providerLabel()} run is already active. Send /stop to cancel it.',
        );
        return;
      }

      final deliveredMessages = <String>{};
      final typingSignal = _TypingSignal(
        telegram: telegram,
        chatId: message.chatId,
      );
      var sentMessages = 0;

      Future<void> sendAssistantMessage(String assistantMessage) async {
        final normalized = _normalizeMessageForDedup(assistantMessage);
        if (normalized.isEmpty || !deliveredMessages.add(normalized)) {
          return;
        }
        sentMessages++;
        await telegram.sendMessage(
            chatId: message.chatId, text: assistantMessage);
      }

      CodexResult result;
      try {
        await typingSignal.start();
        result = await runner.runPrompt(
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

      final nextThreadId = result.threadId;
      if (nextThreadId != null &&
          nextThreadId.isNotEmpty &&
          sessions.current(message.chatId).version == sessionVersion) {
        sessions.setThreadId(message.chatId, nextThreadId);
      }

      final messagesToSend = config.finalResponseOnly
          ? <String>[_resolveFinalAssistantMessage(result)]
          : (result.messages.isEmpty ? <String>[result.text] : result.messages);
      for (final providerMessage in messagesToSend) {
        await sendAssistantMessage(providerMessage);
      }

      for (final artifact in result.artifacts) {
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

      _processedCount++;
      logger.info('request_finished', fields: <String, Object?>{
        'request_id': requestId,
        'chat_id': message.chatId,
        'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
        'messages_sent': sentMessages,
        'artifact_count': result.artifacts.length,
        'thread_id_updated': nextThreadId != null && nextThreadId.isNotEmpty,
      });
    } on CodexCancelledException {
      logger.warn('request_cancelled', fields: <String, Object?>{
        'request_id': requestId,
        'chat_id': message.chatId,
        'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
      });
      return;
    } catch (error) {
      _errorCount++;
      logger.error('request_failed', fields: <String, Object?>{
        'request_id': requestId,
        'chat_id': message.chatId,
        'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
        'error': error.toString(),
      });
      await _sendErrorMessage(chatId: message.chatId, error: error);
    }
  }

  /// Returns true when a message sender or target chat is authorized.
  bool _isAuthorizedMessage(TelegramMessage message) {
    return config.allowedUserIds.contains(message.fromUserId) ||
        config.allowedChatIds.contains(message.chatId);
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

  /// Returns whether [text] targets the built-in `/restart` command.
  bool _isRestartCommand(String? text) {
    if (text == null) {
      return false;
    }
    final trimmed = text.trim();
    return trimmed == '/restart' || trimmed.startsWith('/restart ');
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
      logger.error(
        'error_delivery_failed',
        fields: <String, Object?>{'error': fallbackError.toString()},
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

  /// Renders a configured Telegram command into the prompt sent to the provider.
  String _buildCommandPrompt(
    ConfiguredTelegramCommand command,
    String commandArgs,
  ) {
    final template = command.description;
    if (template.contains('{args}')) {
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
    final root = p.normalize(p.absolute(config.projectPath));
    final full = p.normalize(
      p.isAbsolute(artifactPath)
          ? artifactPath
          : p.join(config.projectPath, artifactPath),
    );

    if (!(full == root || p.isWithin(root, full))) {
      throw StateError('Artifact path is outside project_path: $artifactPath');
    }

    final file = File(full);
    if (!file.existsSync()) {
      throw StateError('Artifact file not found: $artifactPath');
    }
    return full;
  }

  String _providerLabel() {
    switch (config.provider) {
      case AiProvider.codex:
        return 'Codex';
      case AiProvider.cursor:
        return 'Cursor';
      case AiProvider.opencode:
        return 'OpenCode';
      case AiProvider.gemini:
        return 'Gemini';
      case AiProvider.claude:
        return 'Claude';
    }
  }

  /// Sends command/status text and swallows failures caused by shutdown races.
  Future<void> _sendControlMessage({
    required int chatId,
    required String text,
  }) async {
    try {
      await telegram.sendMessage(chatId: chatId, text: text);
    } catch (error) {
      if (_isExpectedControlSendShutdownError(error)) {
        return;
      }
      logger.warn('control_message_send_failed', fields: <String, Object?>{
        'chat_id': chatId,
        'error': error.toString(),
      });
    }
  }

  /// Returns true for known benign send failures during shutdown handover.
  bool _isExpectedControlSendShutdownError(Object error) {
    final text = error.toString();
    return text.contains('Client is already closed');
  }

  Future<void> _drainQueuedWork() async {
    if (_chatWork.isEmpty) {
      return;
    }
    final pending = List<Future<void>>.from(_chatWork.values);
    await Future.wait<void>(pending.map((future) => future.catchError((_) {})));
  }

  Future<void> _dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    telegram.dispose();
  }
}

/// Sends periodic `typing` chat actions while a provider run is active.
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
