import 'dart:async';

import 'package:tgbot/src/app.dart';
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/runtime/bot_app.dart';
import 'package:tgbot/src/runtime/restart_contract.dart';
import 'package:tgbot/src/telegram/telegram_client.dart';

typedef ConfigLoader = List<AppConfig> Function(String path);
typedef BotAppFactory = BotApp Function(
  AppConfig config,
  RestartRequestHandler onRestartRequested,
);
typedef RestartNotifier = Future<void> Function({
  required String botToken,
  required int chatId,
  required String text,
});

/// Owns all running bot apps and handles all-bot restart/reload requests.
class BotSupervisor {
  BotSupervisor({
    required this.configPath,
    ConfigLoader? configLoader,
    BotAppFactory? appFactory,
    RestartNotifier? notifier,
    this.startupProbeWindow = const Duration(milliseconds: 200),
  })  : _configLoader =
            configLoader ?? ((path) => AppConfig.loadMany(path: path)),
        _appFactory = appFactory ??
            ((config, onRestartRequested) => BridgeApp.fromConfig(
                  config,
                  onRestartRequested: onRestartRequested,
                )),
        _notifier = notifier ?? _defaultNotifier;

  /// YAML config path used at startup and every `/restart` reload.
  final String configPath;
  final ConfigLoader _configLoader;
  final BotAppFactory _appFactory;
  final RestartNotifier _notifier;
  final Duration startupProbeWindow;

  List<AppConfig> _activeConfigs = <AppConfig>[];
  List<_RunningApp> _activeApps = <_RunningApp>[];

  bool _running = false;
  bool _stopping = false;
  bool _restartInProgress = false;
  Completer<void>? _runCompleter;

  /// Starts all configured bots and blocks until [stop] is called.
  Future<void> run() async {
    if (_running) {
      await _runCompleter?.future;
      return;
    }
    _running = true;
    _runCompleter = Completer<void>();

    try {
      final initialConfigs = _configLoader(configPath);
      final initialApps = _buildRunningApps(initialConfigs);
      await _startRunningApps(initialApps);
      _activeConfigs = initialConfigs;
      _activeApps = initialApps;
      final startupFailure = await _awaitStartupFailure(initialApps);
      if (startupFailure != null) {
        await _stopRunningApps(initialApps);
        _activeConfigs = <AppConfig>[];
        _activeApps = <_RunningApp>[];
        throw StateError(startupFailure);
      }

      await _runCompleter!.future;
    } finally {
      await stop();
    }
  }

  /// Stops all currently active bots.
  Future<void> stop() async {
    if (_stopping) {
      await _runCompleter?.future;
      return;
    }
    _stopping = true;
    _running = false;

    try {
      await _stopRunningApps(_activeApps);
      _activeApps = <_RunningApp>[];
      _activeConfigs = <AppConfig>[];
    } finally {
      final completer = _runCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      _stopping = false;
    }
  }

  /// Handles `/restart` with authorization, config reload, and rollback.
  Future<RestartOutcome> requestRestart({
    required int requesterUserId,
    required int requesterChatId,
    required String requesterBotName,
  }) async {
    if (!_running || _stopping) {
      return const RestartOutcome(
        message: 'Restart is unavailable because bots are shutting down.',
      );
    }
    if (_restartInProgress) {
      return const RestartOutcome(
        message: 'Restart already in progress.',
      );
    }
    if (!_isGloballyAuthorized(requesterUserId)) {
      return const RestartOutcome(
        message:
            'Restart denied: your user id must be allowed in allowed_user_ids for every configured bot.',
      );
    }

    _restartInProgress = true;
    var nextApps = <_RunningApp>[];
    try {
      final requesterBotToken = _tokenForBotName(requesterBotName);
      final nextConfigs = _configLoader(configPath);
      nextApps = _buildRunningApps(nextConfigs);
      await _startRunningApps(nextApps);
      final startupFailure = await _awaitStartupFailure(nextApps);
      if (startupFailure != null) {
        await _stopRunningApps(nextApps);
        nextApps = <_RunningApp>[];
        return RestartOutcome(
          message:
              'Restart failed and rolled back. Previous bots are still running. $startupFailure',
        );
      }

      final previousApps = _activeApps;
      _activeApps = nextApps;
      _activeConfigs = nextConfigs;
      nextApps = <_RunningApp>[];
      await _stopRunningApps(previousApps);

      if (requesterBotToken != null) {
        await _notifyRestartSuccess(
          botToken: requesterBotToken,
          chatId: requesterChatId,
        );
      }

      return RestartOutcome(
        message: 'Restart completed. Reloaded config from $configPath.',
        sendToRequester: false,
      );
    } catch (error) {
      return RestartOutcome(
        message:
            'Restart failed and rolled back. Previous bots are still running. ${_truncate(error.toString())}',
      );
    } finally {
      if (nextApps.isNotEmpty && !identical(nextApps, _activeApps)) {
        await _stopRunningApps(nextApps);
      }
      _restartInProgress = false;
    }
  }

  bool _isGloballyAuthorized(int requesterUserId) {
    if (_activeConfigs.isEmpty) {
      return false;
    }
    for (final config in _activeConfigs) {
      if (!config.allowedUserIds.contains(requesterUserId)) {
        return false;
      }
    }
    return true;
  }

  String? _tokenForBotName(String botName) {
    for (final config in _activeConfigs) {
      if (config.name == botName) {
        return config.botToken;
      }
    }
    return null;
  }

  List<_RunningApp> _buildRunningApps(List<AppConfig> configs) {
    return configs
        .map(
          (config) => _RunningApp(
            config: config,
            app: _appFactory(config, requestRestart),
          ),
        )
        .toList(growable: false);
  }

  Future<void> _startRunningApps(List<_RunningApp> apps) async {
    for (final app in apps) {
      app.runFuture = app.app.run();
      app.runFuture.catchError((_) {
        // Startup probing observes failures; prevent unhandled async errors.
      });
    }
  }

  Future<void> _stopRunningApps(List<_RunningApp> apps) async {
    if (apps.isEmpty) {
      return;
    }
    await Future.wait<void>(
      apps.map((running) async {
        try {
          await running.app.stop();
        } catch (_) {
          // Best effort stop for all active apps.
        }
      }),
    );
    await Future.wait<void>(
      apps.map((running) async {
        try {
          await running.runFuture;
        } catch (_) {
          // Ignore run futures once stopping is requested.
        }
      }),
    );
  }

  Future<String?> _awaitStartupFailure(List<_RunningApp> apps) async {
    final completer = Completer<String>();
    for (final running in apps) {
      running.runFuture.then((_) {
        if (_stopping || !_running) {
          return;
        }
        if (!completer.isCompleted) {
          completer.complete(
            'Bot "${running.config.name}" stopped during startup.',
          );
        }
      }).catchError((error) {
        if (_stopping || !_running) {
          return;
        }
        if (!completer.isCompleted) {
          completer.complete(
            'Bot "${running.config.name}" failed during startup: ${_truncate(error.toString())}',
          );
        }
      });
    }

    return Future.any<String?>(<Future<String?>>[
      completer.future,
      Future<String?>.delayed(startupProbeWindow, () => null),
    ]);
  }

  String _truncate(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 300) {
      return compact;
    }
    return '${compact.substring(0, 300)}...';
  }

  Future<void> _notifyRestartSuccess({
    required String botToken,
    required int chatId,
  }) async {
    try {
      await _notifier(
        botToken: botToken,
        chatId: chatId,
        text: 'Restart completed. Reloaded config from $configPath.',
      );
    } catch (_) {
      // Keep restart outcome successful even if this best-effort notice fails.
    }
  }

  static Future<void> _defaultNotifier({
    required String botToken,
    required int chatId,
    required String text,
  }) async {
    final telegram = TelegramClient(botToken);
    try {
      await telegram.sendMessage(chatId: chatId, text: text);
    } finally {
      telegram.dispose();
    }
  }
}

class _RunningApp {
  _RunningApp({required this.config, required this.app});

  final AppConfig config;
  final BotApp app;
  Future<void> runFuture = Future<void>.value();
}
