import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tgbot/src/app.dart';
import 'package:tgbot/src/runner/codex_runner.dart';
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/models/telegram_models.dart';
import 'package:tgbot/src/runner/claude_runner.dart';
import 'package:tgbot/src/runner/cursor_runner.dart';
import 'package:tgbot/src/runner/gemini_runner.dart';
import 'package:tgbot/src/runner/opencode_runner.dart';
import 'package:tgbot/src/runtime/restart_contract.dart';
import 'package:tgbot/src/session/session_store.dart';
import 'package:tgbot/src/telegram/telegram_client.dart';
import 'package:tgbot/src/topic/topic_registry.dart';

void main() {
  group('BridgeApp', () {
    test('fromConfig wires default dependencies', () {
      final config = AppConfig(
        name: 'bot',
        botToken: 'TOKEN',
        allowedUserIds: const <int>[1],
        aiCliCmd: 'codex',
        aiCliArgs: const <String>['--model', 'gpt-5'],
        projectPath: Directory.current.path,
        pollTimeoutSec: 10,
        aiCliTimeout: const Duration(seconds: 2),
        additionalSystemPrompt: 'extra',
        finalResponseOnly: false,
        telegramCommands: const <ConfiguredTelegramCommand>[
          ConfiguredTelegramCommand(
              command: 'start', description: 'Show usage help'),
          ConfiguredTelegramCommand(
              command: 'new', description: 'Start a new session'),
        ],
      );

      final app = BridgeApp.fromConfig(config);

      expect(app.config, same(config));
      expect(app.telegram, isA<TelegramClient>());
      expect(app.codex, isA<CodexRunner>());
      expect(app.sessions, isA<SessionStore>());
    });

    test('fromConfig wires provider-specific runners', () {
      final base = _config(Directory.current.path);
      final opencodeApp = BridgeApp.fromConfig(
        AppConfig(
          provider: AiProvider.opencode,
          name: base.name,
          botToken: base.botToken,
          allowedUserIds: base.allowedUserIds,
          aiCliCmd: 'opencode',
          aiCliArgs: base.aiCliArgs,
          projectPath: base.projectPath,
          pollTimeoutSec: base.pollTimeoutSec,
          aiCliTimeout: base.aiCliTimeout,
          additionalSystemPrompt: base.additionalSystemPrompt,
          finalResponseOnly: base.finalResponseOnly,
          telegramCommands: base.telegramCommands,
        ),
      );
      final cursorApp = BridgeApp.fromConfig(
        AppConfig(
          provider: AiProvider.cursor,
          name: base.name,
          botToken: base.botToken,
          allowedUserIds: base.allowedUserIds,
          aiCliCmd: 'cursor-agent',
          aiCliArgs: base.aiCliArgs,
          projectPath: base.projectPath,
          pollTimeoutSec: base.pollTimeoutSec,
          aiCliTimeout: base.aiCliTimeout,
          additionalSystemPrompt: base.additionalSystemPrompt,
          finalResponseOnly: base.finalResponseOnly,
          telegramCommands: base.telegramCommands,
        ),
      );
      final geminiApp = BridgeApp.fromConfig(
        AppConfig(
          provider: AiProvider.gemini,
          name: base.name,
          botToken: base.botToken,
          allowedUserIds: base.allowedUserIds,
          aiCliCmd: 'gemini',
          aiCliArgs: base.aiCliArgs,
          projectPath: base.projectPath,
          pollTimeoutSec: base.pollTimeoutSec,
          aiCliTimeout: base.aiCliTimeout,
          additionalSystemPrompt: base.additionalSystemPrompt,
          finalResponseOnly: base.finalResponseOnly,
          telegramCommands: base.telegramCommands,
        ),
      );
      final claudeApp = BridgeApp.fromConfig(
        AppConfig(
          provider: AiProvider.claude,
          name: base.name,
          botToken: base.botToken,
          allowedUserIds: base.allowedUserIds,
          aiCliCmd: 'claude',
          aiCliArgs: base.aiCliArgs,
          projectPath: base.projectPath,
          pollTimeoutSec: base.pollTimeoutSec,
          aiCliTimeout: base.aiCliTimeout,
          additionalSystemPrompt: base.additionalSystemPrompt,
          finalResponseOnly: base.finalResponseOnly,
          telegramCommands: base.telegramCommands,
        ),
      );

      expect(opencodeApp.codex, isA<OpenCodeRunner>());
      expect(cursorApp.codex, isA<CursorRunner>());
      expect(geminiApp.codex, isA<GeminiRunner>());
      expect(claudeApp.codex, isA<ClaudeRunner>());
    });

    test('handles help and new-session commands', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message:
                  TelegramMessage(chatId: 10, fromUserId: 99, text: 'ignored'),
            ),
            TelegramUpdate(
              updateId: 2,
              message: TelegramMessage(chatId: 10, fromUserId: 1, text: null),
            ),
            TelegramUpdate(
              updateId: 3,
              message: TelegramMessage(
                  chatId: 10, fromUserId: 1, text: '/new again'),
            ),
          ],
        ],
      );
      final sessions = SessionStore()..current(10);
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: _FakeCodexRunner(projectPath: Directory.current.path),
        sessions: sessions,
      );

      await _runUntilIdle(app);

      expect(telegram.setCommandsCalls, 1);
      expect(telegram.sentMessages, hasLength(2));
      expect(telegram.sentMessages.first.text,
          contains('Send any message to chat with Codex'));
      expect(telegram.sentMessages.first.text,
          contains('/start - Show usage help'));
      expect(telegram.sentMessages.first.text,
          contains('/new - Start a new session'));
      expect(telegram.sentMessages.first.text,
          contains('/stop - Stop the active AI CLI run'));
      expect(telegram.sentMessages.first.text,
          contains('/restart - Restart all bots and reload config'));
      expect(telegram.sentMessages.last.text, 'bot has started a new session.');
      expect(sessions.current(10).version, 2);
    });

    test('accepts messages from allowed chat ids', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: -1001234567890,
                fromUserId: 999999,
                text: 'chat-allowed',
              ),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: Directory.current.path,
        result: CodexResult(text: 'ok', messages: const <String>[]),
      );
      final app = BridgeApp(
        config: _config(
          Directory.current.path,
          allowedUserIds: const <int>[],
          allowedChatIds: const <int>[-1001234567890],
        ),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(codex.prompts, <String>['chat-allowed']);
      expect(telegram.sentMessages.single.text, 'ok');
    });

    test('routes topic messages to topic-specific project paths and sessions',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-topic-');
      addTearDown(() => tempDir.delete(recursive: true));
      final defaultProject = Directory('${tempDir.path}/default')
        ..createSync(recursive: true);
      final topicProject = Directory('${tempDir.path}/topic-77')
        ..createSync(recursive: true);

      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: -1001,
                fromUserId: 1,
                messageThreadId: 77,
                text: 'topic run',
              ),
            ),
            TelegramUpdate(
              updateId: 2,
              message: TelegramMessage(
                chatId: -1001,
                fromUserId: 1,
                text: 'root run',
              ),
            ),
          ],
        ],
      );
      final defaultRunner = _FakeCodexRunner(
        projectPath: defaultProject.path,
        result: CodexResult(text: 'default ok', messages: const <String>[]),
      );
      final topicRunner = _FakeCodexRunner(
        projectPath: topicProject.path,
        result: CodexResult(
          text: 'topic ok',
          messages: const <String>[],
          threadId: 'topic-thread',
        ),
      );
      final registry = TopicRegistry(
        path: '${tempDir.path}/topic-registry.json',
      );
      await registry.store(
        botName: 'bot',
        chatId: -1001,
        topicName: 'Topic 77',
        topicId: 77,
      );
      final app = BridgeApp(
        config: _config(
          defaultProject.path,
          topics: <ConfiguredTelegramTopic>[
            ConfiguredTelegramTopic(
              chatId: -1001,
              name: 'Topic 77',
              projectPath: topicProject.path,
            ),
          ],
        ),
        telegram: telegram,
        codex: defaultRunner,
        runnerFactory: (config, projectPath) {
          if (projectPath == topicProject.path) {
            return topicRunner;
          }
          return _FakeCodexRunner(projectPath: projectPath);
        },
        topicRegistry: registry,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(topicRunner.prompts, <String>['topic run']);
      expect(defaultRunner.prompts, <String>['root run']);
      expect(telegram.sentMessages[0].messageThreadId, 77);
      expect(telegram.sentMessages[0].text, 'topic ok');
      expect(telegram.sentMessages[1].messageThreadId, isNull);
      expect(telegram.sentMessages[1].text, 'default ok');
      expect(app.sessions.current(-1001, topicId: 77).threadId, 'topic-thread');
      expect(app.sessions.current(-1001).threadId, isNull);
    });

    test('creates configured topics by name and persists the resolved topic id',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-topic-');
      addTearDown(() => tempDir.delete(recursive: true));
      final defaultProject = Directory('${tempDir.path}/default')
        ..createSync(recursive: true);
      final topicProject = Directory('${tempDir.path}/backend')
        ..createSync(recursive: true);
      final registry = TopicRegistry(
        path: '${tempDir.path}/topic-registry.json',
      );
      final telegram = _FakeTelegramClient(
        createdTopicsByName: <String, TelegramForumTopic>{
          'Backend': TelegramForumTopic(messageThreadId: 456, name: 'Backend'),
        },
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: -100123,
                fromUserId: 1,
                messageThreadId: 456,
                text: 'deploy',
              ),
            ),
          ],
        ],
      );
      final defaultRunner = _FakeCodexRunner(
        projectPath: defaultProject.path,
        result: CodexResult(text: 'default ok', messages: const <String>[]),
      );
      final topicRunner = _FakeCodexRunner(
        projectPath: topicProject.path,
        result: CodexResult(text: 'topic ok', messages: const <String>[]),
      );
      final app = BridgeApp(
        config: _config(
          defaultProject.path,
          topics: <ConfiguredTelegramTopic>[
            ConfiguredTelegramTopic(
              chatId: -100123,
              name: 'Backend',
              projectPath: topicProject.path,
            ),
          ],
        ),
        telegram: telegram,
        codex: defaultRunner,
        runnerFactory: (config, projectPath) {
          if (projectPath == topicProject.path) {
            return topicRunner;
          }
          return _FakeCodexRunner(projectPath: projectPath);
        },
        topicRegistry: registry,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(telegram.createdTopics, hasLength(1));
      expect(telegram.createdTopics.single.chatId, -100123);
      expect(telegram.createdTopics.single.name, 'Backend');
      expect(topicRunner.prompts, <String>['deploy']);
      expect(defaultRunner.prompts, isEmpty);
      expect(telegram.sentMessages.single.messageThreadId, 456);
      expect(
        registry.lookup(botName: 'bot', chatId: -100123, topicName: 'Backend'),
        456,
      );
    });

    test('uses topic-specific telegram commands and start help', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-topic-');
      addTearDown(() => tempDir.delete(recursive: true));
      final topicProject = Directory('${tempDir.path}/backend')
        ..createSync(recursive: true);
      final registry = TopicRegistry(
        path: '${tempDir.path}/topic-registry.json',
      );
      await registry.store(
        botName: 'bot',
        chatId: -100123,
        topicName: 'Backend',
        topicId: 456,
      );
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: -100123,
                fromUserId: 1,
                messageThreadId: 456,
                text: '/start',
              ),
            ),
            TelegramUpdate(
              updateId: 2,
              message: TelegramMessage(
                chatId: -100123,
                fromUserId: 1,
                messageThreadId: 456,
                text: '/topic_fix bug',
              ),
            ),
          ],
        ],
      );
      final topicRunner = _FakeCodexRunner(
        projectPath: topicProject.path,
        result: CodexResult(text: 'topic ok', messages: const <String>[]),
      );
      final app = BridgeApp(
        config: _config(
          null,
          allowedUserIds: const <int>[],
          allowedChatIds: const <int>[-100123],
          topics: <ConfiguredTelegramTopic>[
            ConfiguredTelegramTopic(
              chatId: -100123,
              name: 'Backend',
              projectPath: topicProject.path,
              telegramCommands: const <ConfiguredTelegramCommand>[
                ConfiguredTelegramCommand(
                  command: 'topic_fix',
                  description: 'Fix this topic issue: {args}',
                ),
                ConfiguredTelegramCommand(
                  command: 'start',
                  description: 'Show usage help',
                ),
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
            ),
          ],
        ),
        telegram: telegram,
        runnerFactory: (config, projectPath) => topicRunner,
        topicRegistry: registry,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(telegram.sentMessages.first.text,
          contains('/topic_fix - Fix this topic issue: {args}'));
      expect(topicRunner.prompts, <String>['Fix this topic issue: bug']);
    });

    test('uses topic-specific final_response_only override', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-topic-');
      addTearDown(() => tempDir.delete(recursive: true));
      final topicProject = Directory('${tempDir.path}/backend')
        ..createSync(recursive: true);
      final registry = TopicRegistry(
        path: '${tempDir.path}/topic-registry.json',
      );
      await registry.store(
        botName: 'bot',
        chatId: -100123,
        topicName: 'Backend',
        topicId: 456,
      );
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: -100123,
                fromUserId: 1,
                messageThreadId: 456,
                text: 'run',
              ),
            ),
          ],
        ],
      );
      final topicRunner = _FakeCodexRunner(
        projectPath: topicProject.path,
        streamedMessages: const <String>['progress', 'almost there'],
        result: CodexResult(
          text: 'done',
          messages: const <String>['progress', 'almost there', 'done'],
        ),
      );
      final app = BridgeApp(
        config: _config(
          null,
          finalResponseOnly: false,
          allowedUserIds: const <int>[],
          allowedChatIds: const <int>[-100123],
          topics: <ConfiguredTelegramTopic>[
            ConfiguredTelegramTopic(
              chatId: -100123,
              name: 'Backend',
              projectPath: topicProject.path,
              finalResponseOnly: true,
            ),
          ],
        ),
        telegram: telegram,
        runnerFactory: (config, projectPath) => topicRunner,
        topicRegistry: registry,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>['done'],
      );
    });

    test('reports when no default project is configured for an unmatched topic',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-topic-');
      addTearDown(() => tempDir.delete(recursive: true));
      final topicProject = Directory('${tempDir.path}/backend')
        ..createSync(recursive: true);
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: -100123,
                fromUserId: 1,
                text: 'hello',
              ),
            ),
          ],
        ],
      );
      final app = BridgeApp(
        config: _config(
          null,
          allowedUserIds: const <int>[],
          allowedChatIds: const <int>[-100123],
          topics: <ConfiguredTelegramTopic>[
            ConfiguredTelegramTopic(
              chatId: -100123,
              name: 'Backend',
              projectPath: topicProject.path,
            ),
          ],
        ),
        telegram: telegram,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.single.text,
        contains('No project is configured for this chat/topic'),
      );
    });

    test('runs codex, skips duplicate streamed output, and sends artifacts',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-app-');
      addTearDown(() => tempDir.delete(recursive: true));

      final photo = File('${tempDir.path}/images/pic.png')
        ..createSync(recursive: true)
        ..writeAsStringSync('png');
      final document = File('${tempDir.path}/docs/report.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('report');

      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                  chatId: 5, fromUserId: 1, text: '/fix race condition'),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: tempDir.path,
        streamedMessage: 'streamed',
        result: CodexResult(
          text: 'final',
          messages: const <String>['streamed', 'final'],
          artifacts: <ArtifactResponse>[
            ArtifactResponse(
                kind: 'image', path: 'images/pic.png', caption: 'Pic'),
            ArtifactResponse(
                kind: 'file', path: document.path, caption: 'Report'),
          ],
          threadId: 'thread-9',
        ),
      );
      final sessions = SessionStore();
      final app = BridgeApp(
        config: _config(
          tempDir.path,
          telegramCommands: const <ConfiguredTelegramCommand>[
            ConfiguredTelegramCommand(
                command: 'fix', description: 'Fix this: {args}'),
            ConfiguredTelegramCommand(
                command: 'start', description: 'Show usage help'),
            ConfiguredTelegramCommand(
                command: 'new', description: 'Start a new session'),
          ],
        ),
        telegram: telegram,
        codex: codex,
        sessions: sessions,
      );

      await _runUntilIdle(app);

      expect(codex.prompts, <String>['Fix this: race condition']);
      expect(codex.threadIds, <String?>[null]);
      expect(telegram.chatActions, <String>['typing']);
      expect(telegram.sentMessages.map((entry) => entry.text),
          <String>['streamed', 'final']);
      expect(telegram.sentPhotos.single.filePath, photo.path);
      expect(telegram.sentDocuments.single.filePath, document.path);
      expect(telegram.sentPhotos.single.caption, 'Pic');
      expect(telegram.sentDocuments.single.caption, 'Report');
      expect(sessions.current(5).threadId, 'thread-9');
    });

    test('suppresses duplicate final messages within one codex reply',
        () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: 7,
                fromUserId: 1,
                text: 'dedupe please',
              ),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: Directory.current.path,
        streamedMessages: const <String>['working', 'final', 'final'],
        result: CodexResult(
          text: 'final',
          messages: const <String>['working', 'final'],
        ),
      );
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>['working', 'final'],
      );
    });

    test('sends only the final response when final_response_only is enabled',
        () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: 8,
                fromUserId: 1,
                text: 'final only',
              ),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: Directory.current.path,
        streamedMessages: const <String>['progress', 'almost there'],
        result: CodexResult(
          text: 'done',
          messages: const <String>['progress', 'almost there', 'done'],
        ),
      );
      final app = BridgeApp(
        config: _config(Directory.current.path, finalResponseOnly: true),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>['done'],
      );
    });

    test(
        'final_response_only prefers the last parsed provider message over fallback text',
        () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: 9,
                fromUserId: 1,
                text: 'final only provider mismatch',
              ),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: Directory.current.path,
        result: CodexResult(
          text: 'provider fallback',
          messages: const <String>['working', 'provider final'],
        ),
      );
      final app = BridgeApp(
        config: _config(Directory.current.path, finalResponseOnly: true),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>['provider final'],
      );
    });

    test(
        'builds prompts for command templates with and without args placeholders',
        () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message:
                  TelegramMessage(chatId: 1, fromUserId: 1, text: '/review'),
            ),
            TelegramUpdate(
              updateId: 2,
              message: TelegramMessage(
                  chatId: 1, fromUserId: 1, text: '/plain details'),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(projectPath: Directory.current.path);
      final app = BridgeApp(
        config: _config(
          Directory.current.path,
          telegramCommands: const <ConfiguredTelegramCommand>[
            ConfiguredTelegramCommand(
                command: 'review', description: 'Review branch'),
            ConfiguredTelegramCommand(command: 'plain', description: 'Do this'),
            ConfiguredTelegramCommand(
                command: 'start', description: 'Show usage help'),
            ConfiguredTelegramCommand(
                command: 'new', description: 'Start a new session'),
          ],
        ),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(codex.prompts, <String>['Review branch', 'Do this\n\ndetails']);
    });

    test('handles polling errors and missing artifact files', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-app-');
      addTearDown(() => tempDir.delete(recursive: true));

      final telegram = _FakeTelegramClient(
        getUpdatesErrors: 1,
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                  chatId: 1, fromUserId: 1, text: 'missing file'),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: tempDir.path,
        resultsByPrompt: <String, CodexResult>{
          'missing file': CodexResult(
            text: 'missing file',
            messages: const <String>[],
            artifacts: <ArtifactResponse>[
              ArtifactResponse(kind: 'file', path: 'missing.txt'),
            ],
          ),
        },
      );
      final app = BridgeApp(
        config: _config(tempDir.path),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app, timeout: const Duration(milliseconds: 2250));

      expect(telegram.sentMessages.first.text, 'missing file');
      expect(
          telegram.sentMessages.last.text, contains('Artifact file not found'));
    });

    test('stops an active codex run from /stop', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                chatId: 1,
                fromUserId: 1,
                text: 'long run',
              ),
            ),
          ],
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 2,
              message: TelegramMessage(
                chatId: 1,
                fromUserId: 1,
                text: '/stop',
              ),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: Directory.current.path,
        cancellablePrompts: const <String>{'long run'},
      );
      final sessions = SessionStore();
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: codex,
        sessions: sessions,
      );

      await _runUntilIdle(app, timeout: const Duration(milliseconds: 250));

      expect(codex.prompts, <String>['long run']);
      expect(codex.cancelledPrompts, <String>['long run']);
      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>['bot stopped the active Codex run.'],
      );
      expect(sessions.hasActiveRun(1), isFalse);
    });

    test('reports when /stop is sent without an active codex run', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(chatId: 3, fromUserId: 1, text: '/stop'),
            ),
          ],
        ],
      );
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: _FakeCodexRunner(projectPath: Directory.current.path),
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.single.text,
        'No Codex run is active for this chat.',
      );
    });

    test('delegates /restart to restart callback', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message:
                  TelegramMessage(chatId: 4, fromUserId: 1, text: '/restart'),
            ),
          ],
        ],
      );
      var called = 0;
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: _FakeCodexRunner(projectPath: Directory.current.path),
        onRestartRequested: ({
          required requesterUserId,
          required requesterChatId,
          required requesterBotName,
        }) async {
          called++;
          expect(requesterUserId, 1);
          expect(requesterChatId, 4);
          expect(requesterBotName, 'bot');
          return const RestartOutcome(
              message: 'restart ok', sendToRequester: true);
        },
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(called, 1);
      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>[
          'Restart requested. Reloading config and restarting all bots...',
          'restart ok',
        ],
      );
    });

    test('handles /restart while restart is in progress', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message:
                  TelegramMessage(chatId: 4, fromUserId: 1, text: '/restart'),
            ),
          ],
        ],
      );
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: _FakeCodexRunner(projectPath: Directory.current.path),
        onRestartRequested: ({
          required requesterUserId,
          required requesterChatId,
          required requesterBotName,
        }) async =>
            const RestartOutcome(message: 'Restart already in progress.'),
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>[
          'Restart requested. Reloading config and restarting all bots...',
          'Restart already in progress.',
        ],
      );
    });

    test('handles /restart unauthorized response', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message:
                  TelegramMessage(chatId: 4, fromUserId: 1, text: '/restart'),
            ),
          ],
        ],
      );
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: _FakeCodexRunner(projectPath: Directory.current.path),
        onRestartRequested: ({
          required requesterUserId,
          required requesterChatId,
          required requesterBotName,
        }) async =>
            const RestartOutcome(
          message: 'Restart denied: your user id must be allowed.',
        ),
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(
        telegram.sentMessages.map((entry) => entry.text),
        <String>[
          'Restart requested. Reloading config and restarting all bots...',
          'Restart denied: your user id must be allowed.',
        ],
      );
    });

    test('does not crash when /restart reply send fails after restart',
        () async {
      final telegram = _FakeTelegramClient(
        throwOnSendMessage: true,
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message:
                  TelegramMessage(chatId: 4, fromUserId: 1, text: '/restart'),
            ),
          ],
        ],
      );
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: _FakeCodexRunner(projectPath: Directory.current.path),
        onRestartRequested: ({
          required requesterUserId,
          required requesterChatId,
          required requesterBotName,
        }) async =>
            const RestartOutcome(
          message: 'Restart completed',
          sendToRequester: false,
        ),
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);
      expect(telegram.sentMessages, isEmpty);
    });

    test('keeps typing alive during longer codex runs', () async {
      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message:
                  TelegramMessage(chatId: 1, fromUserId: 1, text: 'slow run'),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: Directory.current.path,
        delay: const Duration(milliseconds: 4100),
      );
      final app = BridgeApp(
        config: _config(Directory.current.path),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app, timeout: const Duration(milliseconds: 4300));

      expect(telegram.chatActions.length, greaterThanOrEqualTo(2));
    });

    test('reports artifact path and codex errors back to telegram', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-app-');
      addTearDown(() => tempDir.delete(recursive: true));

      final telegram = _FakeTelegramClient(
        throwOnSetCommands: true,
        throwOnChatAction: true,
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(
                  chatId: 1, fromUserId: 1, text: 'send artifact'),
            ),
            TelegramUpdate(
              updateId: 2,
              message: TelegramMessage(
                  chatId: 2, fromUserId: 1, text: 'cause codex error'),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: tempDir.path,
        resultsByPrompt: <String, CodexResult>{
          'send artifact': CodexResult(
            text: 'bad artifact',
            messages: const <String>['bad artifact'],
            artifacts: <ArtifactResponse>[
              ArtifactResponse(kind: 'file', path: '../outside.txt'),
            ],
          ),
        },
        errorsByPrompt: <String, Object>{
          'cause codex error': StateError('boom'),
        },
      );
      final app = BridgeApp(
        config: _config(tempDir.path),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(telegram.sentMessages, hasLength(3));
      expect(
        telegram.sentMessages.map((entry) => entry.text),
        containsAll(<Matcher>[
          equals('bad artifact'),
          contains('Artifact path is outside project_path'),
          contains('Bad state: boom'),
        ]),
      );
      expect(telegram.sentDocuments, isEmpty);
      expect(telegram.sentPhotos, isEmpty);
    });

    test('sanitizes ProcessException reply text for telegram', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-app-');
      addTearDown(() => tempDir.delete(recursive: true));

      final telegram = _FakeTelegramClient(
        updates: <List<TelegramUpdate>>[
          <TelegramUpdate>[
            TelegramUpdate(
              updateId: 1,
              message: TelegramMessage(chatId: 1, fromUserId: 1, text: '1+1='),
            ),
          ],
        ],
      );
      final codex = _FakeCodexRunner(
        projectPath: tempDir.path,
        errorsByPrompt: <String, Object>{
          '1+1=': ProcessException(
            'opencode',
            <String>[
              '--yolo',
              'run',
              '--format',
              'json',
              'SYSTEM FOR TELEGRAM BRIDGE: ...',
            ],
            'unknown argument: --yolo',
            1,
          ),
        },
      );
      final app = BridgeApp(
        config: _config(tempDir.path),
        telegram: telegram,
        codex: codex,
        sessions: SessionStore(),
      );

      await _runUntilIdle(app);

      expect(telegram.sentMessages, hasLength(1));
      final reply = telegram.sentMessages.single.text;
      expect(reply, contains('Provider command failed (exit code 1)'));
      expect(reply, contains('unknown argument: --yolo'));
      expect(reply, isNot(contains('SYSTEM FOR TELEGRAM BRIDGE')));
    });
  });
}

Future<void> _runUntilIdle(
  BridgeApp app, {
  Duration timeout = const Duration(milliseconds: 100),
}) async {
  try {
    await app.run().timeout(timeout);
  } on TimeoutException {
    // Expected: the app is intentionally long-running.
    await app.stop();
  }
}

AppConfig _config(
  String? projectPath, {
  bool finalResponseOnly = false,
  List<int> allowedUserIds = const <int>[1],
  List<int> allowedChatIds = const <int>[],
  List<ConfiguredTelegramTopic> topics = const <ConfiguredTelegramTopic>[],
  List<ConfiguredTelegramCommand> telegramCommands =
      const <ConfiguredTelegramCommand>[
    ConfiguredTelegramCommand(command: 'start', description: 'Show usage help'),
    ConfiguredTelegramCommand(
        command: 'new', description: 'Start a new session'),
    ConfiguredTelegramCommand(
        command: 'stop', description: 'Stop the active AI CLI run'),
    ConfiguredTelegramCommand(
      command: 'restart',
      description: 'Restart all bots and reload config',
    ),
  ],
}) {
  return AppConfig(
    name: 'bot',
    botToken: 'TOKEN',
    logLevel: LogLevel.error,
    allowedUserIds: allowedUserIds,
    allowedChatIds: allowedChatIds,
    aiCliCmd: 'codex',
    aiCliArgs: const <String>[],
    projectPath: projectPath,
    topics: topics,
    pollTimeoutSec: 1,
    aiCliTimeout: const Duration(seconds: 1),
    additionalSystemPrompt: null,
    finalResponseOnly: finalResponseOnly,
    telegramCommands: telegramCommands,
  );
}

class _FakeTelegramClient extends TelegramClient {
  _FakeTelegramClient({
    this.updates = const <List<TelegramUpdate>>[],
    this.throwOnSetCommands = false,
    this.throwOnChatAction = false,
    this.throwOnSendMessage = false,
    this.getUpdatesErrors = 0,
    this.createdTopicsByName = const <String, TelegramForumTopic>{},
  }) : super('TOKEN');

  final List<List<TelegramUpdate>> updates;
  final bool throwOnSetCommands;
  final bool throwOnChatAction;
  final bool throwOnSendMessage;
  int getUpdatesErrors;
  final Map<String, TelegramForumTopic> createdTopicsByName;

  int _updateIndex = 0;
  int setCommandsCalls = 0;
  final List<_SentMessage> sentMessages = <_SentMessage>[];
  final List<String> chatActions = <String>[];
  final List<_SentFile> sentPhotos = <_SentFile>[];
  final List<_SentFile> sentDocuments = <_SentFile>[];
  final List<_CreateTopicCall> createdTopics = <_CreateTopicCall>[];

  @override
  Future<List<TelegramUpdate>> getUpdates({
    required int offset,
    required int timeoutSec,
  }) async {
    if (getUpdatesErrors > 0) {
      getUpdatesErrors--;
      throw StateError('poll failed');
    }
    if (_updateIndex < updates.length) {
      return updates[_updateIndex++];
    }
    return Completer<List<TelegramUpdate>>().future;
  }

  @override
  Future<void> setMyCommands(List<TelegramBotCommand> commands) async {
    setCommandsCalls++;
    if (throwOnSetCommands) {
      throw StateError('register failed');
    }
  }

  @override
  Future<TelegramForumTopic> createForumTopic({
    required int chatId,
    required String name,
  }) async {
    createdTopics.add(_CreateTopicCall(chatId: chatId, name: name));
    return createdTopicsByName[name] ??
        TelegramForumTopic(messageThreadId: 999, name: name);
  }

  @override
  Future<void> sendMessage({
    required int chatId,
    required String text,
    int? messageThreadId,
  }) async {
    if (throwOnSendMessage) {
      throw const HttpException(
        'ClientException: HTTP request failed. Client is already closed.',
      );
    }
    sentMessages.add(
      _SentMessage(
        chatId: chatId,
        messageThreadId: messageThreadId,
        text: text,
      ),
    );
  }

  @override
  Future<void> sendChatAction({
    required int chatId,
    required String action,
    int? messageThreadId,
  }) async {
    chatActions.add(action);
    if (throwOnChatAction) {
      throw StateError('chat action failed');
    }
  }

  @override
  Future<void> sendPhoto({
    required int chatId,
    required String filePath,
    String? caption,
    int? messageThreadId,
  }) async {
    sentPhotos.add(
      _SentFile(
        chatId: chatId,
        messageThreadId: messageThreadId,
        filePath: filePath,
        caption: caption,
      ),
    );
  }

  @override
  Future<void> sendDocument({
    required int chatId,
    required String filePath,
    String? caption,
    int? messageThreadId,
  }) async {
    sentDocuments.add(
      _SentFile(
        chatId: chatId,
        messageThreadId: messageThreadId,
        filePath: filePath,
        caption: caption,
      ),
    );
  }
}

class _FakeCodexRunner extends CodexRunner {
  _FakeCodexRunner({
    required super.projectPath,
    this.result,
    this.streamedMessage,
    this.streamedMessages = const <String>[],
    this.resultsByPrompt = const <String, CodexResult>{},
    this.errorsByPrompt = const <String, Object>{},
    this.cancellablePrompts = const <String>{},
    this.delay,
  }) : super(
          command: 'codex',
          args: const <String>[],
          timeout: const Duration(seconds: 1),
        );

  final CodexResult? result;
  final String? streamedMessage;
  final List<String> streamedMessages;
  final Map<String, CodexResult> resultsByPrompt;
  final Map<String, Object> errorsByPrompt;
  final Set<String> cancellablePrompts;
  final Duration? delay;

  final List<String> prompts = <String>[];
  final List<String?> threadIds = <String?>[];
  final List<String> cancelledPrompts = <String>[];

  @override
  Future<CodexResult> runPrompt({
    required String prompt,
    String? threadId,
    FutureOr<void> Function(String message)? onAssistantMessage,
    void Function(Future<void> Function() cancel)? onCancelReady,
  }) async {
    prompts.add(prompt);
    threadIds.add(threadId);

    final error = errorsByPrompt[prompt];
    if (error != null) {
      throw error;
    }

    if (streamedMessage != null && onAssistantMessage != null) {
      await onAssistantMessage(streamedMessage!);
    }
    if (onAssistantMessage != null) {
      for (final message in streamedMessages) {
        await onAssistantMessage(message);
      }
    }

    if (delay != null) {
      await Future<void>.delayed(delay!);
    }

    if (cancellablePrompts.contains(prompt)) {
      final cancelled = Completer<void>();
      onCancelReady?.call(() async {
        cancelledPrompts.add(prompt);
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
      });
      await cancelled.future;
      throw CodexCancelledException();
    }

    return resultsByPrompt[prompt] ??
        result ??
        CodexResult(text: 'ok', messages: const <String>['ok']);
  }
}

class _SentMessage {
  _SentMessage({
    required this.chatId,
    required this.text,
    this.messageThreadId,
  });

  final int chatId;
  final int? messageThreadId;
  final String text;
}

class _SentFile {
  _SentFile({
    required this.chatId,
    required this.filePath,
    this.caption,
    this.messageThreadId,
  });

  final int chatId;
  final int? messageThreadId;
  final String filePath;
  final String? caption;
}

class _CreateTopicCall {
  _CreateTopicCall({required this.chatId, required this.name});

  final int chatId;
  final String name;
}
