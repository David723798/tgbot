import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/default_config_template.dart';
import 'package:tgbot/src/runtime/supervisor.dart';
import 'package:tgbot/src/version.dart';

/// Entry point for the `tgbot` CLI.
Future<void> main(List<String> args) async {
  // Top-level command runner for all CLI subcommands.
  final runner = CommandRunner<void>(
    'tgbot',
    'A CLI tool that bridges Telegram messages to AI CLIs, allowing you to interact with agents through a Telegram bot.',
  )
    ..addCommand(StartCommand())
    ..addCommand(InitCommand())
    ..addCommand(ValidateCommand())
    ..addCommand(UpgradeCommand())
    ..argParser.addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print the version.',
    );

  // Handle --version / -v before command dispatch.
  try {
    // Parsed top-level arguments used to intercept `--version`.
    final topResults = runner.argParser.parse(args);
    if (topResults['version'] == true) {
      stdout.writeln('tgbot $version');
      return;
    }
  } on FormatException {
    // Ignore – let CommandRunner handle unknown flags.
  }

  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  } on ConfigException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  } catch (error, stackTrace) {
    stderr.writeln('Fatal error: $error');
    stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

/// Starts the bot bridge using the given configuration file.
class StartCommand extends Command<void> {
  /// Configures the `start` subcommand.
  StartCommand() {
    argParser.addOption(
      'config',
      abbr: 'c',
      help: 'Path to the YAML configuration file.',
      defaultsTo: 'tgbot.yaml',
    );
  }

  @override

  /// CLI name for this subcommand.
  String get name => 'start';

  @override

  /// Help text shown for this subcommand.
  String get description => 'Start the Telegram–AI CLI bridge.';

  @override

  /// Loads the config and starts every configured bot.
  Future<void> run() async {
    // CLI path to the YAML configuration file.
    final configPath = argResults!['config'] as String;
    final configs = AppConfig.loadMany(path: configPath);
    stdout.writeln('Starting ${configs.length} bot(s) from $configPath …');
    final supervisor = BotSupervisor(configPath: configPath);

    Future<void> handleShutdown(String signalName) async {
      stdout.writeln('Received $signalName, stopping bots...');
      await supervisor.stop();
    }

    StreamSubscription<ProcessSignal>? sigIntSub;
    StreamSubscription<ProcessSignal>? sigTermSub;
    try {
      sigIntSub = ProcessSignal.sigint.watch().listen((_) {
        unawaited(handleShutdown('SIGINT'));
      });
    } catch (_) {
      // Signal is not available on this platform/runtime.
    }
    try {
      sigTermSub = ProcessSignal.sigterm.watch().listen((_) {
        unawaited(handleShutdown('SIGTERM'));
      });
    } catch (_) {
      // Signal is not available on this platform/runtime.
    }

    try {
      await supervisor.run();
    } finally {
      await sigIntSub?.cancel();
      await sigTermSub?.cancel();
      await supervisor.stop();
    }
  }
}

/// Generates a starter tgbot.yaml in the current directory.
class InitCommand extends Command<void> {
  /// Configures the `init` subcommand.
  InitCommand() {
    argParser.addOption(
      'output',
      abbr: 'o',
      help: 'Output path for the generated config file.',
      defaultsTo: 'tgbot.yaml',
    );
  }

  @override

  /// CLI name for this subcommand.
  String get name => 'init';

  @override

  /// Help text shown for this subcommand.
  String get description => 'Generate a starter tgbot.yaml configuration file.';

  @override

  /// Writes the default config template to the requested output path.
  Future<void> run() async {
    // CLI path where the config file will be written.
    final output = argResults!['output'] as String;
    // Filesystem handle for the target output path.
    final file = File(output);

    if (file.existsSync()) {
      stderr.writeln('File already exists: $output');
      stderr.writeln('Remove it first or use --output to choose another path.');
      exitCode = 1;
      return;
    }

    file.writeAsStringSync(defaultConfigTemplate);
    stdout.writeln('Created $output');
    stdout
        .writeln('Edit the file to add your bot token and user ID, then run:');
    stdout.writeln('  tgbot start');
  }
}

/// Upgrades tgbot to the latest version.
class UpgradeCommand extends Command<void> {
  @override

  /// CLI name for this subcommand.
  String get name => 'upgrade';

  @override

  /// Help text shown for this subcommand.
  String get description => 'Upgrade tgbot to the latest version.';

  @override

  /// Reactivates the latest published package globally with Dart.
  Future<void> run() async {
    stdout.writeln('Current version: $version');
    stdout.writeln('Upgrading tgbot via dart pub global activate …');
    stdout.writeln('');

    // Result of `dart pub global activate tgbot`.
    final result = await Process.run(
      'dart',
      ['pub', 'global', 'activate', 'tgbot'],
    );

    if (result.exitCode != 0) {
      stderr.writeln('Upgrade failed (exit code ${result.exitCode}):');
      // Trimmed stderr from the failed upgrade command.
      final errOut = (result.stderr as String).trim();
      if (errOut.isNotEmpty) stderr.writeln(errOut);
      // Trimmed stdout from the failed upgrade command.
      final stdOut = (result.stdout as String).trim();
      if (stdOut.isNotEmpty) stderr.writeln(stdOut);
      exitCode = 1;
    } else {
      // Trimmed stdout from the successful upgrade command.
      final output = (result.stdout as String).trim();
      if (output.isNotEmpty) stdout.writeln(output);
      stdout.writeln('');
      stdout.writeln('Upgrade complete!');
    }
  }
}

/// Validates a tgbot.yaml configuration file without starting any bots.
class ValidateCommand extends Command<void> {
  /// Configures the `validate` subcommand.
  ValidateCommand() {
    argParser.addOption(
      'config',
      abbr: 'c',
      help: 'Path to the YAML configuration file.',
      defaultsTo: 'tgbot.yaml',
    );
  }

  @override

  /// CLI name for this subcommand.
  String get name => 'validate';

  @override

  /// Help text shown for this subcommand.
  String get description => 'Validate a configuration file.';

  @override

  /// Loads the config file and reports success when parsing succeeds.
  Future<void> run() async {
    // CLI path to the YAML configuration file.
    final configPath = argResults!['config'] as String;
    // Parsed configs used only to validate the file.
    final configs = AppConfig.loadMany(path: configPath);
    stdout.writeln(
      'Config OK: $configPath (${configs.length} bot(s) configured)',
    );
  }
}
