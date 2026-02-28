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
  final_response_only: true
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
      expect(config.aiCliCmd, 'codex-bin');
      expect(
          config.projectPath, Directory(inheritedProject.path).absolute.path);
      expect(config.pollTimeoutSec, 15);
      expect(config.aiCliTimeout, const Duration(seconds: 90));
      expect(config.additionalSystemPrompt, 'keep answers short');
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
        <String>['fix', 'start', 'new', 'stop'],
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
      expect(config.finalResponseOnly, isFalse);
      expect(
        config.telegramCommands.map((command) => command.command),
        <String>['review_1', 'start', 'new', 'stop'],
      );
    });

    test('throws for missing files and malformed configs', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-config-');
      addTearDown(() => tempDir.delete(recursive: true));

      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/missing.yaml'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Missing config file'),
          ),
        ),
      );

      File('${tempDir.path}/root-list.yaml').writeAsStringSync('- nope');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/root-list.yaml'),
        throwsA(isA<StateError>()),
      );

      File('${tempDir.path}/empty-bots.yaml').writeAsStringSync('bots: []');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/empty-bots.yaml'),
        throwsA(isA<StateError>()),
      );

      File('${tempDir.path}/bot-not-map.yaml').writeAsStringSync('''
bots:
  - just-a-string
''');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/bot-not-map.yaml'),
        throwsA(isA<StateError>()),
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
        throwsA(isA<StateError>()),
      );

      File('${tempDir.path}/missing-project.yaml').writeAsStringSync('''
bots:
  - name: bot
    telegram_bot_token: TOKEN
    allowed_user_ids: 1
''');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/missing-project.yaml'),
        throwsA(isA<StateError>()),
      );

      File('${tempDir.path}/missing-name.yaml').writeAsStringSync('''
bots:
  - telegram_bot_token: TOKEN
    allowed_user_ids: 1
    project_path: ${tempDir.path}
''');
      expect(
        () => AppConfig.loadMany(path: '${tempDir.path}/missing-name.yaml'),
        throwsA(isA<StateError>()),
      );
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
            () => AppConfig.loadMany(path: file.path), throwsA(isA<Object>()));
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
  });
}
