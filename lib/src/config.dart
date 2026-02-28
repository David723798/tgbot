import 'dart:io';

import 'package:yaml/yaml.dart';

/// Supported AI CLI providers.
enum AiProvider { codex, opencode, gemini, claude }

/// Parsed runtime configuration for a single Telegram bot.
class AppConfig {
  /// Creates an immutable bot configuration.
  AppConfig({
    this.provider = AiProvider.codex,
    required this.name,
    required this.botToken,
    required this.allowedUserIds,
    required this.aiCliCmd,
    required this.aiCliArgs,
    required this.projectPath,
    required this.pollTimeoutSec,
    required this.aiCliTimeout,
    required this.additionalSystemPrompt,
    required this.finalResponseOnly,
    required this.telegramCommands,
  });

  /// Human-readable bot name used in logs and status messages.
  final String name;

  /// Provider selected for this bot.
  final AiProvider provider;

  /// Telegram Bot API token.
  final String botToken;

  /// Telegram user ids allowed to talk to the bot.
  final List<int> allowedUserIds;

  /// Executable used to launch the selected provider CLI.
  final String aiCliCmd;

  /// Arguments passed to the selected provider CLI.
  final List<String> aiCliArgs;

  /// Working directory where Codex runs.
  final String projectPath;

  /// Telegram long-poll timeout in seconds.
  final int pollTimeoutSec;

  /// Maximum duration allowed for a single provider request.
  final Duration aiCliTimeout;

  /// Optional extra system prompt prepended to every provider request.
  final String? additionalSystemPrompt;

  /// Whether Telegram should receive only the final assistant response.
  final bool finalResponseOnly;

  /// Commands shown in Telegram and recognized by the bridge.
  final List<ConfiguredTelegramCommand> telegramCommands;

  /// Reserved commands added automatically when not already configured.
  static const List<ConfiguredTelegramCommand> _systemTelegramCommands =
      <ConfiguredTelegramCommand>[
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
  ];

  /// Loads all bot configurations declared in the YAML file at [path].
  static List<AppConfig> loadMany({String path = 'tgbot.yaml'}) {
    // Configuration file to parse.
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('Missing config file: $path');
    }

    // Parsed root YAML document.
    final root = loadYaml(file.readAsStringSync());
    if (root is! YamlMap) {
      throw StateError('Config root must be a map.');
    }

    // Shared defaults inherited by each bot entry.
    final defaults = _asMap(root['defaults']);
    // Raw list of bot configuration entries.
    final botsNode = root['bots'];
    if (botsNode is! YamlList || botsNode.isEmpty) {
      throw StateError('Config must contain a non-empty bots list.');
    }

    // Parsed configurations returned to the caller.
    final out = <AppConfig>[];
    for (var i = 0; i < botsNode.length; i++) {
      // Current bot entry being validated.
      final node = botsNode[i];
      if (node is! YamlMap) {
        throw StateError('bots[$i] must be a map.');
      }
      out.add(_fromMap(index: i, bot: node, defaults: defaults));
    }
    return out;
  }

  static AppConfig _fromMap({
    required int index,
    required YamlMap bot,
    required YamlMap defaults,
  }) {
    // Display name for this bot instance.
    final name = _requiredString(bot, 'name');
    // Provider selected for this bot.
    final provider = _parseProvider(
      _optionalString(bot, 'provider') ?? _optionalString(defaults, 'provider'),
    );
    // Telegram token used for API calls.
    final token = _requiredString(bot, 'telegram_bot_token');
    // Telegram user ids authorized to use the bot.
    final allowedUsers = _requiredIntList(bot, 'allowed_user_ids');

    // Long-poll timeout, with bot-level config overriding defaults.
    final pollTimeout = _optionalInt(bot, 'poll_timeout_sec') ??
        _optionalInt(defaults, 'poll_timeout_sec') ??
        60;
    // Provider execution timeout in seconds.
    final aiCliTimeoutSec = _optionalInt(bot, 'ai_cli_timeout_sec') ??
        _optionalInt(defaults, 'ai_cli_timeout_sec') ??
        1000;

    // Raw project path before converting to an absolute path.
    final projectPathRaw = _optionalString(bot, 'project_path') ??
        _optionalString(defaults, 'project_path');
    if (projectPathRaw == null || projectPathRaw.isEmpty) {
      throw StateError('Missing required key: project_path');
    }

    // Provider executable name or path.
    final aiCliCmd = _optionalString(bot, 'ai_cli_cmd') ??
        _optionalString(defaults, 'ai_cli_cmd') ??
        _defaultCommandForProvider(provider);

    // Configured provider CLI arguments.
    final aiCliArgsRaw = _asArgs(bot['ai_cli_args']) ??
        _asArgs(defaults['ai_cli_args']) ??
        const <String>[];
    // Effective argument list for provider invocation.
    final aiCliArgs = aiCliArgsRaw;
    // Optional additional system prompt for this bot.
    final additionalSystemPrompt =
        _optionalString(bot, 'additional_system_prompt') ??
            _optionalString(defaults, 'additional_system_prompt');
    // Whether to send only the final assistant response to Telegram.
    final finalResponseOnly = _optionalBool(bot, 'final_response_only') ??
        _optionalBool(defaults, 'final_response_only') ??
        false;
    // User-defined Telegram slash commands from config.
    final configuredTelegramCommands =
        _asTelegramCommands(bot['telegram_commands']) ??
            _asTelegramCommands(defaults['telegram_commands']) ??
            const <ConfiguredTelegramCommand>[];
    // Final Telegram command list including built-ins.
    final telegramCommands = _withSystemTelegramCommands(
      configuredTelegramCommands,
    );

    return AppConfig(
      provider: provider,
      name: name,
      botToken: token,
      allowedUserIds: allowedUsers,
      aiCliCmd: aiCliCmd,
      aiCliArgs: aiCliArgs,
      projectPath: Directory(projectPathRaw).absolute.path,
      pollTimeoutSec: pollTimeout,
      aiCliTimeout: Duration(seconds: aiCliTimeoutSec),
      additionalSystemPrompt: _normalizeOptionalPrompt(additionalSystemPrompt),
      finalResponseOnly: finalResponseOnly,
      telegramCommands: telegramCommands,
    );
  }

  /// Parses a provider name, defaulting to Codex.
  static AiProvider _parseProvider(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return AiProvider.codex;
    }
    final normalized = raw.trim().toLowerCase();
    switch (normalized) {
      case 'codex':
        return AiProvider.codex;
      case 'opencode':
        return AiProvider.opencode;
      case 'gemini':
        return AiProvider.gemini;
      case 'claude':
        return AiProvider.claude;
      default:
        throw StateError(
          'Invalid provider "$raw". Use one of: codex, opencode, gemini, claude.',
        );
    }
  }

  /// Provides a default executable for each provider.
  static String _defaultCommandForProvider(AiProvider provider) {
    switch (provider) {
      case AiProvider.codex:
        return 'codex';
      case AiProvider.opencode:
        return 'opencode';
      case AiProvider.gemini:
        return 'gemini';
      case AiProvider.claude:
        return 'claude';
    }
  }

  /// Trims a prompt and converts blank strings to `null`.
  static String? _normalizeOptionalPrompt(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Reads a required string from a YAML map.
  static String _requiredString(YamlMap map, String key) {
    final value = _optionalString(map, key);
    if (value == null || value.isEmpty) {
      throw StateError('Missing required key: $key');
    }
    return value;
  }

  /// Reads an optional string from a YAML map.
  static String? _optionalString(YamlMap map, String key) {
    // Raw YAML value stored under [key].
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is String) {
      return value;
    }
    return value.toString();
  }

  /// Reads a required integer list from a YAML map.
  static List<int> _requiredIntList(YamlMap map, String key) {
    final value = map[key];
    if (value == null) {
      throw StateError('Missing or invalid integer list key: $key');
    }
    if (value is YamlList) {
      final out = <int>[];
      for (var i = 0; i < value.length; i++) {
        final parsed = _parseIntValue(value[i]);
        if (parsed == null) {
          throw StateError('Missing or invalid integer list key: $key');
        }
        out.add(parsed);
      }
      if (out.isEmpty) {
        throw StateError('Missing or invalid integer list key: $key');
      }
      return List<int>.unmodifiable(out);
    }

    final parsedSingle = _parseIntValue(value);
    if (parsedSingle == null) {
      throw StateError('Missing or invalid integer list key: $key');
    }
    return List<int>.unmodifiable(<int>[parsedSingle]);
  }

  /// Reads an optional integer from a YAML map.
  static int? _optionalInt(YamlMap map, String key) {
    // Raw YAML value stored under [key].
    final value = map[key];
    if (value == null) {
      return null;
    }
    return _parseIntValue(value);
  }

  /// Parses an integer from either an int or numeric string.
  static int? _parseIntValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  /// Reads an optional boolean from a YAML map.
  static bool? _optionalBool(YamlMap map, String key) {
    // Raw YAML value stored under [key].
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is bool) {
      return value;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') {
        return true;
      }
      if (normalized == 'false') {
        return false;
      }
    }
    throw StateError('Missing or invalid boolean key: $key');
  }

  /// Converts a nullable YAML value into a [YamlMap].
  static YamlMap _asMap(Object? value) {
    if (value == null) {
      return YamlMap();
    }
    if (value is YamlMap) {
      return value;
    }
    throw StateError('Expected a map value.');
  }

  /// Parses provider args from either a string or a YAML list.
  static List<String>? _asArgs(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return _splitArgs(value);
    }
    if (value is YamlList) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    throw StateError('ai_cli_args must be a string or list.');
  }

  /// Splits a whitespace-delimited args string into a list.
  static List<String> _splitArgs(String raw) {
    if (raw.trim().isEmpty) {
      return const <String>[];
    }
    return raw
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  /// Parses the optional `telegram_commands` YAML list.
  static List<ConfiguredTelegramCommand>? _asTelegramCommands(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! YamlList) {
      throw StateError('telegram_commands must be a list.');
    }

    // Parsed command definitions in declaration order.
    final commands = <ConfiguredTelegramCommand>[];
    for (var i = 0; i < value.length; i++) {
      // Current command entry being validated.
      final entry = value[i];
      if (entry is! YamlMap) {
        throw StateError('telegram_commands[$i] must be a map.');
      }
      // Slash command name without the leading `/`.
      final command = _requiredString(entry, 'command');
      // Telegram-visible description and prompt template.
      final description = _requiredString(entry, 'description');
      _validateTelegramCommand(command);
      commands.add(
        ConfiguredTelegramCommand(command: command, description: description),
      );
    }

    if (commands.isEmpty) {
      throw StateError('telegram_commands must not be empty when provided.');
    }
    return List<ConfiguredTelegramCommand>.unmodifiable(commands);
  }

  /// Merges configured commands with built-ins, keeping the first occurrence.
  static List<ConfiguredTelegramCommand> _withSystemTelegramCommands(
    List<ConfiguredTelegramCommand> configuredCommands,
  ) {
    // Command names already included in the merged result.
    final seen = <String>{};
    // Final ordered list of commands.
    final merged = <ConfiguredTelegramCommand>[];

    for (final command in configuredCommands) {
      if (seen.add(command.command)) {
        merged.add(command);
      }
    }
    for (final command in _systemTelegramCommands) {
      if (seen.add(command.command)) {
        merged.add(command);
      }
    }

    return List<ConfiguredTelegramCommand>.unmodifiable(merged);
  }

  /// Validates Telegram command names against Bot API constraints.
  static void _validateTelegramCommand(String command) {
    // Allowed Telegram command pattern.
    final pattern = RegExp(r'^[a-z0-9_]{1,32}$');
    if (!pattern.hasMatch(command)) {
      throw StateError(
        'Invalid telegram command "$command". Use 1-32 chars: a-z, 0-9, _.',
      );
    }
  }
}

/// Configured Telegram slash command definition.
class ConfiguredTelegramCommand {
  /// Creates an immutable Telegram command.
  const ConfiguredTelegramCommand({
    required this.command,
    required this.description,
  });

  /// Command name without the leading slash.
  final String command;

  /// Description shown in Telegram and reused as a prompt template.
  final String description;
}
