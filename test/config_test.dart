import 'dart:io';

import 'package:test/test.dart';
import 'package:tgbot/src/config.dart';

void main() {
  group('AppConfig.loadMany', () {
    test('parses defaults, args, and telegram commands', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final inheritedProject = Directory('${tempDir.path}/project')
        ..createSync(recursive: true);
      final yaml = '''
defaults:
  project_path: ${inheritedProject.path}
  provider: codex
  ai_cli_cmd: codex-bin
  ai_cli_args: --model gpt-5 --add-dir /tmp/shared
  poll_timeout_sec: "15"
  ai_cli_timeout_sec: 90
  additional_system_prompt: "   keep answers short   "
  memory: true
  memory_filename: TEAM_MEMORY.md
  final_response_only: true
  allowed_chat_ids:
    - -1001234567890
  telegram_commands:
    - command: fix
      description: "Fix this: {args}"
    - command: start
      description: Custom start
bots:
  - name: bot-one
    telegram_bot_token: TOKEN
    allowed_user_ids: "42"
''';
      final configFile = File('${tempDir.path}/tgbot.yaml')
        ..writeAsStringSync(yaml);

      final configs = AppConfig.loadMany(path: configFile.path);
      final config = configs.single;

      expect(config.name, 'bot-one');
      expect(config.provider, AiProvider.codex);
      expect(config.botToken, 'TOKEN');
      expect(config.allowedUserIds, const <int>[42]);
      expect(config.allowedChatIds, const <int>[-1001234567890]);
      expect(config.aiCliCmd, 'codex-bin');
      expect(
          config.projectPath, Directory(inheritedProject.path).absolute.path);
      expect(config.pollTimeoutSec, 15);
      expect(config.aiCliTimeout, const Duration(seconds: 90));
      expect(config.additionalSystemPrompt, 'keep answers short');
      expect(config.memory, isTrue);
      expect(config.memoryFilename, 'TEAM_MEMORY.md');
      expect(config.finalResponseOnly, isTrue);
      expect(
        config.aiCliArgs,
        <String>[
          '--model',
          'gpt-5',
          '--add-dir',
          '/tmp/shared',
        ],
      );
      expect(
        config.telegramCommands.map((command) => command.command),
        <String>['fix', 'start', 'new', 'stop', 'restart'],
      );
      expect(config.telegramCommands.first.description, 'Fix this: {args}');
      expect(config.telegramCommands[1].description, 'Custom start');
    });

    test('uses bot overrides and list-based args without blank values',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final project = Directory('${tempDir.path}/project')..createSync();
      final yaml = '''
defaults:
  project_path: ${tempDir.path}
  ai_cli_args: --model gpt-5
bots:
  - name: bot-two
    telegram_bot_token: TOKEN
    allowed_user_ids: 7
    project_path: ${project.path}
    ai_cli_args:
      - --sandbox
      - " "
      - workspace-write
    additional_system_prompt: "   "
    memory: false
    memory_filename: "   "
    final_response_only: false
    provider: opencode
    telegram_commands:
      - command: review_1
        description: Review branch
''';
      final configFile = File('${tempDir.path}/tgbot.yaml')
        ..writeAsStringSync(yaml);

      final config = AppConfig.loadMany(path: configFile.path).single;

      expect(
        config.aiCliArgs,
        <String>[
          '--sandbox',
          'workspace-write',
        ],
      );
      expect(config.provider, AiProvider.opencode);
      expect(config.additionalSystemPrompt, isNull);
      expect(config.memory, isFalse);
      expect(config.memoryFilename, 'MEMORY.md');
      expect(config.finalResponseOnly, isFalse);
      expect(
        config.telegramCommands.map((command) => command.command),
        <String>['review_1', 'start', 'new', 'stop', 'restart'],
      );
    });

    test('keeps custom restart command and dedupes built-in restart', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final file = File('${tempDir.path}/restart.yaml')..writeAsStringSync('''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    telegram_commands:
      - command: restart
        description: Custom restart behavior
''');

      final config = AppConfig.loadMany(path: file.path).single;
      expect(
        config.telegramCommands.map((command) => command.command),
        <String>['restart', 'start', 'new', 'stop'],
      );
      expect(
          config.telegramCommands.first.description, 'Custom restart behavior');
    });

    test('throws for missing files and malformed configs', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/missing.yaml'),
        throwsA(
          isA<ConfigException>().having(
            (error) => error.message,
            'message',
            contains('Missing config file'),
          ),
        ),
      );

      File('${tempDir.path}/root-list.yaml').writeAsStringSync('- nope');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/root-list.yaml'),
        throwsA(isA<ConfigException>()),
      );

      File('${tempDir.path}/empty-bots.yaml').writeAsStringSync('bots: []');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/empty-bots.yaml'),
        throwsA(isA<ConfigException>()),
      );

      File('${tempDir.path}/bot-not-map.yaml').writeAsStringSync('''
bots:
  - just-a-string
''');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/bot-not-map.yaml'),
        throwsA(isA<ConfigException>()),
      );

      File('${tempDir.path}/bad-defaults.yaml').writeAsStringSync('''
defaults: nope
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
''');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/bad-defaults.yaml'),
        throwsA(isA<ConfigException>()),
      );

      File('${tempDir.path}/missing-project.yaml').writeAsStringSync('''
bots:
  - name: bot
    telegram_bot_token: TOKEN
''');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/missing-project.yaml'),
        throwsA(isA<ConfigException>()),
      );

      File('${tempDir.path}/missing-name.yaml').writeAsStringSync('''
bots:
  - telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
''');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/missing-name.yaml'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('accepts chat-only authorization using allowed_chat_ids', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final file = File('${tempDir.path}/chat-only.yaml')..writeAsStringSync('''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_chat_ids:
      - -1009876543210
    project_path: ${tempDir.path}
''');

      final config = AppConfig.loadMany(path: file.path).single;
      expect(config.allowedUserIds, isEmpty);
      expect(config.allowedChatIds, const <int>[-1009876543210]);
    });

    test('throws for invalid typed fields and telegram command entries',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final cases = <String>[
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: nope
    project_path: ${tempDir.path}
''',
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    provider: unknown
''',
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    ai_cli_args: 3
''',
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    telegram_commands: nope
''',
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    telegram_commands: []
''',
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    telegram_commands:
      - nope
''',
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    final_response_only: maybe
''',
        '''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    telegram_commands:
      - command: Bad-Name
        description: invalid
''',
      ];

      for (var i = 0; i < cases.length; i++) {
        final file = File('${tempDir.path}/case-$i.yaml')
          ..writeAsStringSync(cases[i]);
        expect(
          () => AppConfig.loadMany(path: file.path),
          throwsA(isA<ConfigException>()),
        );
      }
    });

    test('stringifies non-string optional values before parsing', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final file = File('${tempDir.path}/coerce.yaml')..writeAsStringSync('''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: 123
''');

      final config = AppConfig.loadMany(path: file.path).single;
      expect(config.projectPath, Directory('123').absolute.path);
    });

    test('supports shell-style quoted ai_cli_args strings', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final file = File('${tempDir.path}/quoted-args.yaml')
        ..writeAsStringSync('''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    ai_cli_args: --model "gpt 5" --note 'hello world' --path "/tmp/a b"
''');

      final config = AppConfig.loadMany(path: file.path).single;
      expect(
        config.aiCliArgs,
        <String>[
          '--model',
          'gpt 5',
          '--note',
          'hello world',
          '--path',
          '/tmp/a b',
        ],
      );
    });

    test('defaults ai_cli_cmd to cursor-agent for cursor provider', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final file = File('${tempDir.path}/cursor-default-cmd.yaml')
        ..writeAsStringSync('''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    provider: cursor
''');

      final config = AppConfig.loadMany(path: file.path).single;
      expect(config.provider, AiProvider.cursor);
      expect(config.aiCliCmd, 'cursor-agent');
    });

    test('enforces strict_config unknown-key rejection', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final file = File('${tempDir.path}/strict.yaml')..writeAsStringSync('''
defaults:
  strict_config: true
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
    unexpected: nope
''');

      expect(
        () => AppConfig.loadMany(path: file.path),
        throwsA(
          isA<ConfigException>().having(
            (error) => error.path,
            'path',
            'bots[0].unexpected',
          ),
        ),
      );
    });

    test('validates project_path when validate_project_path is true', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      final missingPath = '${tempDir.path}/missing-project';
      final file = File('${tempDir.path}/validate-project.yaml')
        ..writeAsStringSync('''
defaults:
  validate_project_path: true
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: $missingPath
''');

      expect(
        () => AppConfig.loadMany(path: file.path),
        throwsA(
          isA<ConfigException>().having(
            (error) => error.path,
            'path',
            'bots[0].project_path',
          ),
        ),
      );
    });
  });
}
