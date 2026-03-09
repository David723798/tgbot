import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/runtime/bot_app.dart';
import 'package:tgbot/src/runtime/supervisor.dart';

void main() {
  group('BotSupervisor', () {
    test('starts configured apps and stops them on shutdown', () async {
      final loaderPaths = <String>[];
      var configs = <AppConfig>[
        _config(name: 'bot-a', allowedUserIds: <int>[1])
      ];
      final created = <_FakeBotApp>[];
      final supervisor = BotSupervisor(
        configPath: '/tmp/custom.yaml',
        configLoader: (path) {
          loaderPaths.add(path);
          return configs;
        },
        appFactory: (config, _) {
          final app = _FakeBotApp(config: config);
          created.add(app);
          return app;
        },
      );

      final runFuture = supervisor.run();
      await _waitUntil(() => created.length == 1 && created.first.running);
      await supervisor.stop();
      await runFuture;

      expect(loaderPaths.first, '/tmp/custom.yaml');
      expect(created.first.stopCalls, 1);
    });

    test('authorized restart reloads config and swaps active apps', () async {
      var configs = <AppConfig>[
        _config(name: 'old-bot', allowedUserIds: <int>[1])
      ];
      final created = <_FakeBotApp>[];
      final notifications = <_NotificationCall>[];
      final supervisor = BotSupervisor(
        configPath: '/tmp/tgbot.yaml',
        configLoader: (_) => configs,
        appFactory: (config, _) {
          final app = _FakeBotApp(config: config);
          created.add(app);
          return app;
        },
        notifier: ({required botToken, required chatId, required text}) async {
          notifications.add(
            _NotificationCall(
              botToken: botToken,
              chatId: chatId,
              text: text,
            ),
          );
        },
      );

      final runFuture = supervisor.run();
      await _waitUntil(() => created.length == 1 && created.first.running);
      final old = created.single;

      configs = <AppConfig>[
        _config(name: 'new-bot', allowedUserIds: <int>[1])
      ];
      final outcome = await supervisor.requestRestart(
        requesterUserId: 1,
        requesterChatId: 9,
        requesterBotName: 'old-bot',
      );

      expect(outcome.message, contains('Restart completed'));
      expect(outcome.sendToRequester, isFalse);
      expect(old.stopCalls, 1);
      expect(created.last.config.name, 'new-bot');
      expect(created.last.running, isTrue);
      expect(notifications, hasLength(1));
      expect(notifications.single.chatId, 9);
      expect(notifications.single.botToken, 'TOKEN-old-bot');
      expect(notifications.single.text, contains('Restart completed'));

      await supervisor.stop();
      await runFuture;
    });

    test('restart denies user not authorized on every active bot', () async {
      final supervisor = BotSupervisor(
        configPath: '/tmp/tgbot.yaml',
        configLoader: (_) => <AppConfig>[
          _config(name: 'bot-a', allowedUserIds: <int>[1, 2]),
          _config(name: 'bot-b', allowedUserIds: <int>[2]),
        ],
        appFactory: (config, _) => _FakeBotApp(config: config),
      );

      final runFuture = supervisor.run();
      final outcome = await supervisor.requestRestart(
        requesterUserId: 1,
        requesterChatId: 7,
        requesterBotName: 'bot-a',
      );

      expect(outcome.message, contains('Restart denied'));
      await supervisor.stop();
      await runFuture;
    });

    test('restart rollback keeps previous apps when config reload fails',
        () async {
      var shouldThrow = false;
      final created = <_FakeBotApp>[];
      final supervisor = BotSupervisor(
        configPath: '/tmp/tgbot.yaml',
        configLoader: (_) {
          if (shouldThrow) {
            throw StateError('bad yaml');
          }
          return <AppConfig>[
            _config(name: 'stable-bot', allowedUserIds: <int>[1])
          ];
        },
        appFactory: (config, _) {
          final app = _FakeBotApp(config: config);
          created.add(app);
          return app;
        },
      );

      final runFuture = supervisor.run();
      await _waitUntil(() => created.length == 1 && created.single.running);

      shouldThrow = true;
      final outcome = await supervisor.requestRestart(
        requesterUserId: 1,
        requesterChatId: 1,
        requesterBotName: 'stable-bot',
      );

      expect(outcome.message, contains('rolled back'));
      expect(created.single.stopCalls, 0);
      expect(created.single.running, isTrue);

      await supervisor.stop();
      await runFuture;
    });

    test(
        'restart rollback stops partially started next apps on startup failure',
        () async {
      var generation = 0;
      final created = <_FakeBotApp>[];
      final supervisor = BotSupervisor(
        configPath: '/tmp/tgbot.yaml',
        configLoader: (_) {
          if (generation == 0) {
            return <AppConfig>[
              _config(name: 'old-bot', allowedUserIds: <int>[1])
            ];
          }
          return <AppConfig>[
            _config(name: 'next-ok', allowedUserIds: <int>[1]),
            _config(name: 'next-fail', allowedUserIds: <int>[1]),
          ];
        },
        appFactory: (config, _) {
          final app = _FakeBotApp(
            config: config,
            failOnRun: config.name == 'next-fail',
          );
          created.add(app);
          return app;
        },
      );

      final runFuture = supervisor.run();
      await _waitUntil(() => created.length == 1 && created.first.running);
      final old = created.first;

      generation = 1;
      final outcome = await supervisor.requestRestart(
        requesterUserId: 1,
        requesterChatId: 8,
        requesterBotName: 'old-bot',
      );

      expect(outcome.message, contains('rolled back'));
      final nextOk = created.firstWhere((app) => app.config.name == 'next-ok');
      expect(nextOk.stopCalls, 1);
      expect(old.stopCalls, 0);
      expect(old.running, isTrue);

      await supervisor.stop();
      await runFuture;
    });

    test('concurrent restart requests return in-progress for second caller',
        () async {
      var generation = 0;
      final created = <_FakeBotApp>[];
      final supervisor = BotSupervisor(
        configPath: '/tmp/tgbot.yaml',
        startupProbeWindow: const Duration(milliseconds: 400),
        configLoader: (_) {
          if (generation == 0) {
            return <AppConfig>[
              _config(name: 'old-bot', allowedUserIds: <int>[1])
            ];
          }
          return <AppConfig>[
            _config(name: 'new-bot', allowedUserIds: <int>[1])
          ];
        },
        appFactory: (config, _) {
          final app = _FakeBotApp(config: config);
          created.add(app);
          return app;
        },
      );

      final runFuture = supervisor.run();
      await _waitUntil(() => created.isNotEmpty && created.first.running);
      generation = 1;
      final firstRestart = supervisor.requestRestart(
        requesterUserId: 1,
        requesterChatId: 1,
        requesterBotName: 'old-bot',
      );
      final secondRestart = await supervisor.requestRestart(
        requesterUserId: 1,
        requesterChatId: 1,
        requesterBotName: 'old-bot',
      );

      expect(secondRestart.message, 'Restart already in progress.');
      final firstOutcome = await firstRestart;
      expect(firstOutcome.message, contains('Restart completed'));

      await supervisor.stop();
      await runFuture;
    });
  });
}

class _NotificationCall {
  _NotificationCall({
    required this.botToken,
    required this.chatId,
    required this.text,
  });

  final String botToken;
  final int chatId;
  final String text;
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition not reached before timeout');
}

AppConfig _config({
  required String name,
  required List<int> allowedUserIds,
}) {
  return AppConfig(
    name: name,
    botToken: 'TOKEN-$name',
    allowedUserIds: allowedUserIds,
    aiCliCmd: 'codex',
    aiCliArgs: const <String>[],
    projectPath: Directory.current.path,
    pollTimeoutSec: 1,
    aiCliTimeout: const Duration(seconds: 1),
    additionalSystemPrompt: null,
    finalResponseOnly: false,
    telegramCommands: const <ConfiguredTelegramCommand>[
      ConfiguredTelegramCommand(
          command: 'start', description: 'Show usage help'),
      ConfiguredTelegramCommand(
        command: 'new',
        description: 'Start a new session',
      ),
      ConfiguredTelegramCommand(
        command: 'stop',
        description: 'Stop the active AI CLI run',
      ),
      ConfiguredTelegramCommand(
        command: 'restart',
        description: 'Restart all bots and reload config',
      ),
    ],
  );
}

class _FakeBotApp implements BotApp {
  _FakeBotApp({required this.config, this.failOnRun = false});

  @override
  final AppConfig config;
  final bool failOnRun;

  bool running = false;
  int stopCalls = 0;
  final Completer<void> _stopCompleter = Completer<void>();

  @override
  Future<void> run() async {
    if (failOnRun) {
      throw StateError('startup failed for ${config.name}');
    }
    running = true;
    await _stopCompleter.future;
    running = false;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (!_stopCompleter.isCompleted) {
      _stopCompleter.complete();
    }
  }
}
