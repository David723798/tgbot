import 'dart:io';

import 'package:yaml/yaml.dart';

/// Supported AI CLI providers.
enum AiProvider { codex, cursor, opencode, gemini, claude }

/// Supported runtime log levels.
enum LogLevel { debug, info, warn, error }

/// Supported runtime log output formats.
enum LogFormat { text, json }

/// Typed config parsing/validation error.
class ConfigException implements Exception {
  ConfigException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() {
    if (path == null || path!.isEmpty) {
      return 'ConfigException: $message';
    }
    return 'ConfigException($path): $message';
  }
}

/// Parsed runtime configuration for a single Telegram bot.
class AppConfig {
  /// Creates an immutable bot configuration.
  AppConfig({
    this.provider = AiProvider.codex,
    this.logLevel = LogLevel.info,
    this.logFormat = LogFormat.text,
    this.strictConfig = false,
    this.validateProjectPath = false,
    required this.name,
    required this.botToken,
    required this.allowedUserIds,
    this.allowedChatIds = const <int>[],
    required this.aiCliCmd,
    required this.aiCliArgs,
    this.projectPath,
    this.topics = const <ConfiguredTelegramTopic>[],
    required this.pollTimeoutSec,
    required this.aiCliTimeout,
    required this.additionalSystemPrompt,
    this.memory = false,
    this.memoryFilename = 'MEMORY.md',
    required this.finalResponseOnly,
    required this.telegramCommands,
  });

  /// Human-readable bot name used in logs and status messages.
  final String name;

  /// Provider selected for this bot.
  final AiProvider provider;

  /// Minimum log level emitted by the runtime.
  final LogLevel logLevel;

  /// Log serialization format.
  final LogFormat logFormat;

  /// Whether strict key validation is enabled while parsing config.
  final bool strictConfig;

  /// Whether project path existence/readability should be validated.
  final bool validateProjectPath;

  /// Telegram Bot API token.
  final String botToken;

  /// Telegram user ids allowed to talk to the bot.
  final List<int> allowedUserIds;

  /// Telegram chat ids allowed to talk to the bot (for groups/channels).
  final List<int> allowedChatIds;

  /// Executable used to launch the selected provider CLI.
  final String aiCliCmd;

  /// Arguments passed to the selected provider CLI.
  final List<String> aiCliArgs;

  /// Working directory where Codex runs.
  final String? projectPath;

  /// Forum topics that should exist and map to a project path.
  final List<ConfiguredTelegramTopic> topics;

  /// Telegram long-poll timeout in seconds.
  final int pollTimeoutSec;

  /// Maximum duration allowed for a single provider request.
  final Duration aiCliTimeout;

  /// Optional extra system prompt prepended to every provider request.
  final String? additionalSystemPrompt;

  /// Whether to inject MEMORY.md management instructions on first turn.
  final bool memory;

  /// Memory instructions filename injected on first turn when [memory] is true.
  final String memoryFilename;

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
    ConfiguredTelegramCommand(
      command: 'restart',
      description: 'Restart all bots and reload config',
    ),
  ];

  static const Set<String> _rootKeys = <String>{'defaults', 'bots'};
  static const Set<String> _defaultsKeys = <String>{
    'provider',
    'project_path',
    'ai_cli_cmd',
    'ai_cli_args',
    'poll_timeout_sec',
    'ai_cli_timeout_sec',
    'additional_system_prompt',
    'memory',
    'memory_filename',
    'final_response_only',
    'telegram_commands',
    'log_level',
    'log_format',
    'strict_config',
    'validate_project_path',
    'allowed_chat_ids',
    'topics',
  };
  static const Set<String> _botKeys = <String>{
    'name',
    'telegram_bot_token',
    'allowed_user_ids',
    'allowed_chat_ids',
    'provider',
    'project_path',
    'ai_cli_cmd',
    'ai_cli_args',
    'poll_timeout_sec',
    'ai_cli_timeout_sec',
    'additional_system_prompt',
    'memory',
    'memory_filename',
    'final_response_only',
    'telegram_commands',
    'log_level',
    'log_format',
    'strict_config',
    'validate_project_path',
    'topics',
  };
  static const Set<String> _telegramCommandKeys = <String>{
    'command',
    'description',
  };
  static const Set<String> _topicKeys = <String>{
    'chat_id',
    'name',
    'project_path',
    'additional_system_prompt',
    'memory',
    'memory_filename',
    'final_response_only',
    'telegram_commands',
  };

  /// Loads all bot configurations declared in the YAML file at [path].
  static List<AppConfig> loadMany({String path = 'tgbot.yaml'}) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigException('Missing config file: $path');
    }

    final root = loadYaml(file.readAsStringSync());
    if (root is! YamlMap) {
      throw ConfigException('Config root must be a map.', path: 'root');
    }

    final defaults = _asMap(root['defaults'], 'defaults');
    final strictConfig = _optionalBool(defaults, 'strict_config',
            path: 'defaults.strict_config') ??
        false;

    if (strictConfig) {
      _validateKnownKeys(root, _rootKeys, path: 'root');
      _validateKnownKeys(defaults, _defaultsKeys, path: 'defaults');
    }

    final botsNode = root['bots'];
    if (botsNode is! YamlList || botsNode.isEmpty) {
      throw ConfigException(
        'Config must contain a non-empty bots list.',
        path: 'bots',
      );
    }

    final out = <AppConfig>[];
    for (var i = 0; i < botsNode.length; i++) {
      final node = botsNode[i];
      if (node is! YamlMap) {
        throw ConfigException('bots[$i] must be a map.', path: 'bots[$i]');
      }
      out.add(
        _fromMap(
          index: i,
          bot: node,
          defaults: defaults,
          strictConfig: strictConfig,
        ),
      );
    }
    return out;
  }

  static AppConfig _fromMap({
    required int index,
    required YamlMap bot,
    required YamlMap defaults,
    required bool strictConfig,
  }) {
    final path = 'bots[$index]';
    final botStrictConfig =
        _optionalBool(bot, 'strict_config', path: '$path.strict_config') ??
            _optionalBool(
              defaults,
              'strict_config',
              path: 'defaults.strict_config',
            ) ??
            strictConfig;
    if (botStrictConfig) {
      _validateKnownKeys(bot, _botKeys, path: path);
    }

    final name = _requiredString(bot, 'name', path: '$path.name');
    final provider = _parseProvider(
      _optionalString(bot, 'provider') ?? _optionalString(defaults, 'provider'),
      path: '$path.provider',
    );
    final token = _requiredString(bot, 'telegram_bot_token',
        path: '$path.telegram_bot_token');
    final allowedUsers = _optionalIntList(bot, 'allowed_user_ids',
            path: '$path.allowed_user_ids') ??
        const <int>[];
    final allowedChats = _optionalIntList(
          bot,
          'allowed_chat_ids',
          path: '$path.allowed_chat_ids',
        ) ??
        _optionalIntList(
          defaults,
          'allowed_chat_ids',
          path: 'defaults.allowed_chat_ids',
        ) ??
        const <int>[];
    if (allowedUsers.isEmpty && allowedChats.isEmpty) {
      throw ConfigException(
        'At least one of allowed_user_ids or allowed_chat_ids is required.',
        path: path,
      );
    }

    final pollTimeout =
        _optionalInt(bot, 'poll_timeout_sec', path: '$path.poll_timeout_sec') ??
            _optionalInt(
              defaults,
              'poll_timeout_sec',
              path: 'defaults.poll_timeout_sec',
            ) ??
            60;
    final aiCliTimeoutSec = _optionalInt(bot, 'ai_cli_timeout_sec',
            path: '$path.ai_cli_timeout_sec') ??
        _optionalInt(
          defaults,
          'ai_cli_timeout_sec',
          path: 'defaults.ai_cli_timeout_sec',
        ) ??
        1000;

    final aiCliCmd = _optionalString(bot, 'ai_cli_cmd') ??
        _optionalString(defaults, 'ai_cli_cmd') ??
        _defaultCommandForProvider(provider);

    final aiCliArgsRaw =
        _asArgs(bot['ai_cli_args'], path: '$path.ai_cli_args') ??
            _asArgs(defaults['ai_cli_args'], path: 'defaults.ai_cli_args') ??
            const <String>[];
    final aiCliArgs = aiCliArgsRaw;
    final additionalSystemPrompt =
        _optionalString(bot, 'additional_system_prompt') ??
            _optionalString(defaults, 'additional_system_prompt');
    final memory = _optionalBool(
          bot,
          'memory',
          path: '$path.memory',
        ) ??
        _optionalBool(
          defaults,
          'memory',
          path: 'defaults.memory',
        ) ??
        false;
    final memoryFilename = _normalizeMemoryFilename(
      _optionalString(bot, 'memory_filename') ??
          _optionalString(defaults, 'memory_filename'),
    );
    final finalResponseOnly = _optionalBool(
          bot,
          'final_response_only',
          path: '$path.final_response_only',
        ) ??
        _optionalBool(
          defaults,
          'final_response_only',
          path: 'defaults.final_response_only',
        ) ??
        true;
    final botLogLevel = _parseLogLevel(
      _optionalString(bot, 'log_level') ??
          _optionalString(defaults, 'log_level'),
      path: '$path.log_level',
    );
    final botLogFormat = _parseLogFormat(
      _optionalString(bot, 'log_format') ??
          _optionalString(defaults, 'log_format'),
      path: '$path.log_format',
    );
    final validateProjectPath = _optionalBool(
          bot,
          'validate_project_path',
          path: '$path.validate_project_path',
        ) ??
        _optionalBool(
          defaults,
          'validate_project_path',
          path: 'defaults.validate_project_path',
        ) ??
        false;

    final configuredTelegramCommands = _asTelegramCommands(
          bot['telegram_commands'],
          path: '$path.telegram_commands',
          strictConfig: strictConfig,
        ) ??
        _asTelegramCommands(
          defaults['telegram_commands'],
          path: 'defaults.telegram_commands',
          strictConfig: strictConfig,
        ) ??
        const <ConfiguredTelegramCommand>[];
    final telegramCommands = _withSystemTelegramCommands(
      configuredTelegramCommands,
    );

    final topics = _asTopics(
          bot['topics'],
          path: '$path.topics',
          strictConfig: botStrictConfig,
          validateProjectPath: validateProjectPath,
          allowedChatIds: allowedChats,
        ) ??
        _asTopics(
          defaults['topics'],
          path: 'defaults.topics',
          strictConfig: strictConfig,
          validateProjectPath: validateProjectPath,
          allowedChatIds: allowedChats,
        ) ??
        const <ConfiguredTelegramTopic>[];
    final projectPathRaw = _optionalString(bot, 'project_path') ??
        _optionalString(defaults, 'project_path');
    if ((projectPathRaw == null || projectPathRaw.isEmpty) && topics.isEmpty) {
      throw ConfigException(
        'Missing required key: project_path',
        path: '$path.project_path',
      );
    }
    final projectPath = projectPathRaw == null || projectPathRaw.isEmpty
        ? null
        : _normalizeProjectPath(
            projectPathRaw,
            path: '$path.project_path',
            validateProjectPath: validateProjectPath,
          );

    return AppConfig(
      provider: provider,
      logLevel: botLogLevel,
      logFormat: botLogFormat,
      strictConfig: botStrictConfig,
      validateProjectPath: validateProjectPath,
      name: name,
      botToken: token,
      allowedUserIds: allowedUsers,
      allowedChatIds: allowedChats,
      aiCliCmd: aiCliCmd,
      aiCliArgs: aiCliArgs,
      projectPath: projectPath,
      topics: topics,
      pollTimeoutSec: pollTimeout,
      aiCliTimeout: Duration(seconds: aiCliTimeoutSec),
      additionalSystemPrompt: _normalizeOptionalPrompt(additionalSystemPrompt),
      memory: memory,
      memoryFilename: memoryFilename,
      finalResponseOnly: finalResponseOnly,
      telegramCommands: telegramCommands,
    );
  }

  /// Parses a provider name, defaulting to Codex.
  static AiProvider _parseProvider(String? raw, {required String path}) {
    if (raw == null || raw.trim().isEmpty) {
      return AiProvider.codex;
    }
    final normalized = raw.trim().toLowerCase();
    switch (normalized) {
      case 'codex':
        return AiProvider.codex;
      case 'cursor':
        return AiProvider.cursor;
      case 'opencode':
        return AiProvider.opencode;
      case 'gemini':
        return AiProvider.gemini;
      case 'claude':
        return AiProvider.claude;
      default:
        throw ConfigException(
          'Invalid provider "$raw". Use one of: codex, cursor, opencode, gemini, claude.',
          path: path,
        );
    }
  }

  /// Parses log level, defaulting to info.
  static LogLevel _parseLogLevel(String? raw, {required String path}) {
    if (raw == null || raw.trim().isEmpty) {
      return LogLevel.info;
    }
    switch (raw.trim().toLowerCase()) {
      case 'debug':
        return LogLevel.debug;
      case 'info':
        return LogLevel.info;
      case 'warn':
        return LogLevel.warn;
      case 'error':
        return LogLevel.error;
      default:
        throw ConfigException(
          'Invalid log_level "$raw". Use one of: debug, info, warn, error.',
          path: path,
        );
    }
  }

  /// Parses log format, defaulting to text.
  static LogFormat _parseLogFormat(String? raw, {required String path}) {
    if (raw == null || raw.trim().isEmpty) {
      return LogFormat.text;
    }
    switch (raw.trim().toLowerCase()) {
      case 'text':
        return LogFormat.text;
      case 'json':
        return LogFormat.json;
      default:
        throw ConfigException(
          'Invalid log_format "$raw". Use one of: text, json.',
          path: path,
        );
    }
  }

  /// Provides a default executable for each provider.
  static String _defaultCommandForProvider(AiProvider provider) {
    switch (provider) {
      case AiProvider.codex:
        return 'codex';
      case AiProvider.cursor:
        return 'cursor-agent';
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

  /// Trims memory filename and defaults blank values to MEMORY.md.
  static String _normalizeMemoryFilename(String? value) {
    if (value == null) {
      return 'MEMORY.md';
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? 'MEMORY.md' : trimmed;
  }

  /// Reads a required string from a YAML map.
  static String _requiredString(YamlMap map, String key,
      {required String path}) {
    final value = _optionalString(map, key);
    if (value == null || value.isEmpty) {
      throw ConfigException('Missing required key: $key', path: path);
    }
    return value;
  }

  /// Reads an optional string from a YAML map.
  static String? _optionalString(YamlMap map, String key) {
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
  static List<int> _requiredIntList(YamlMap map, String key,
      {required String path}) {
    final value = map[key];
    if (value == null) {
      throw ConfigException('Missing or invalid integer list key: $key',
          path: path);
    }
    if (value is YamlList) {
      final out = <int>[];
      for (var i = 0; i < value.length; i++) {
        final parsed = _parseIntValue(value[i]);
        if (parsed == null) {
          throw ConfigException('Missing or invalid integer list key: $key',
              path: '$path[$i]');
        }
        out.add(parsed);
      }
      if (out.isEmpty) {
        throw ConfigException('Missing or invalid integer list key: $key',
            path: path);
      }
      return List<int>.unmodifiable(out);
    }

    final parsedSingle = _parseIntValue(value);
    if (parsedSingle == null) {
      throw ConfigException('Missing or invalid integer list key: $key',
          path: path);
    }
    return List<int>.unmodifiable(<int>[parsedSingle]);
  }

  /// Reads an optional integer list from a YAML map.
  static List<int>? _optionalIntList(YamlMap map, String key,
      {required String path}) {
    if (!map.containsKey(key) || map[key] == null) {
      return null;
    }
    return _requiredIntList(map, key, path: path);
  }

  /// Reads an optional integer from a YAML map.
  static int? _optionalInt(YamlMap map, String key, {required String path}) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    final parsed = _parseIntValue(value);
    if (parsed == null) {
      throw ConfigException('Expected an integer for key: $key', path: path);
    }
    return parsed;
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
  static bool? _optionalBool(YamlMap map, String key, {required String path}) {
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
    throw ConfigException('Missing or invalid boolean key: $key', path: path);
  }

  /// Converts a nullable YAML value into a [YamlMap].
  static YamlMap _asMap(Object? value, String path) {
    if (value == null) {
      return YamlMap();
    }
    if (value is YamlMap) {
      return value;
    }
    throw ConfigException('Expected a map value.', path: path);
  }

  /// Parses provider args from either a string or a YAML list.
  static List<String>? _asArgs(Object? value, {required String path}) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return _splitArgs(value, path: path);
    }
    if (value is YamlList) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    throw ConfigException('ai_cli_args must be a string or list.', path: path);
  }

  /// Splits a shell-like argument string into a list.
  static List<String> _splitArgs(String raw, {required String path}) {
    if (raw.trim().isEmpty) {
      return const <String>[];
    }

    final out = <String>[];
    final token = StringBuffer();
    var inSingle = false;
    var inDouble = false;

    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (ch == '\\') {
        if (i + 1 >= raw.length) {
          throw ConfigException('Invalid trailing escape in ai_cli_args.',
              path: path);
        }
        final next = raw[i + 1];
        if (inSingle) {
          token.write(ch);
        } else {
          token.write(next);
          i++;
        }
        continue;
      }
      if (ch == "'" && !inDouble) {
        inSingle = !inSingle;
        continue;
      }
      if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
        continue;
      }
      if ((ch == ' ' || ch == '\t' || ch == '\n') && !inSingle && !inDouble) {
        if (token.isNotEmpty) {
          out.add(token.toString());
          token.clear();
        }
        continue;
      }
      token.write(ch);
    }

    if (inSingle || inDouble) {
      throw ConfigException('Unclosed quote in ai_cli_args.', path: path);
    }
    if (token.isNotEmpty) {
      out.add(token.toString());
    }
    return out
        .where((entry) => entry.trim().isNotEmpty)
        .toList(growable: false);
  }

  /// Parses configured forum topics from a YAML list.
  static List<ConfiguredTelegramTopic>? _asTopics(
    Object? value, {
    required String path,
    required bool strictConfig,
    required bool validateProjectPath,
    required List<int> allowedChatIds,
  }) {
    if (value == null) {
      return null;
    }
    if (value is! YamlList) {
      throw ConfigException('topics must be a list.', path: path);
    }

    final topics = <ConfiguredTelegramTopic>[];
    for (var i = 0; i < value.length; i++) {
      final entry = value[i];
      if (entry is! YamlMap) {
        throw ConfigException('topics[$i] must be a map.', path: '$path[$i]');
      }
      if (strictConfig) {
        _validateKnownKeys(entry, _topicKeys, path: '$path[$i]');
      }
      final chatId = _resolveTopicChatId(entry,
          path: '$path[$i]', allowedChatIds: allowedChatIds);
      final name = _requiredString(entry, 'name', path: '$path[$i].name');
      final projectPathRaw = _requiredString(
        entry,
        'project_path',
        path: '$path[$i].project_path',
      );
      final configuredTelegramCommands = _asTelegramCommands(
        entry['telegram_commands'],
        path: '$path[$i].telegram_commands',
        strictConfig: strictConfig,
      );
      topics.add(
        ConfiguredTelegramTopic(
          chatId: chatId,
          name: name,
          projectPath: _normalizeProjectPath(
            projectPathRaw,
            path: '$path[$i].project_path',
            validateProjectPath: validateProjectPath,
          ),
          additionalSystemPrompt: _normalizeOptionalPrompt(
            _optionalString(entry, 'additional_system_prompt'),
          ),
          memory: _optionalBool(entry, 'memory', path: '$path[$i].memory'),
          memoryFilename: _optionalString(entry, 'memory_filename') == null
              ? null
              : _normalizeMemoryFilename(
                  _optionalString(entry, 'memory_filename')),
          finalResponseOnly: _optionalBool(
            entry,
            'final_response_only',
            path: '$path[$i].final_response_only',
          ),
          telegramCommands: configuredTelegramCommands == null
              ? null
              : _withSystemTelegramCommands(configuredTelegramCommands),
        ),
      );
    }

    if (topics.isEmpty) {
      throw ConfigException(
        'topics must not be empty when provided.',
        path: path,
      );
    }
    return List<ConfiguredTelegramTopic>.unmodifiable(topics);
  }

  static int _resolveTopicChatId(
    YamlMap entry, {
    required String path,
    required List<int> allowedChatIds,
  }) {
    final explicit = _optionalInt(entry, 'chat_id', path: '$path.chat_id');
    if (explicit != null) {
      return explicit;
    }
    if (allowedChatIds.length == 1) {
      return allowedChatIds.single;
    }
    throw ConfigException(
      'topics[].chat_id is required unless exactly one allowed_chat_ids value is configured for the bot.',
      path: '$path.chat_id',
    );
  }

  static String _normalizeProjectPath(
    String rawPath, {
    required String path,
    required bool validateProjectPath,
  }) {
    final projectPath = Directory(rawPath).absolute.path;
    if (validateProjectPath) {
      final projectDir = Directory(projectPath);
      if (!projectDir.existsSync()) {
        throw ConfigException(
          'project_path does not exist: $projectPath',
          path: path,
        );
      }
      try {
        projectDir.listSync(followLinks: false).isNotEmpty;
      } on FileSystemException {
        throw ConfigException(
          'project_path is not readable: $projectPath',
          path: path,
        );
      }
    }
    return projectPath;
  }

  /// Parses the optional `telegram_commands` YAML list.
  static List<ConfiguredTelegramCommand>? _asTelegramCommands(
    Object? value, {
    required String path,
    required bool strictConfig,
  }) {
    if (value == null) {
      return null;
    }
    if (value is! YamlList) {
      throw ConfigException('telegram_commands must be a list.', path: path);
    }

    final commands = <ConfiguredTelegramCommand>[];
    for (var i = 0; i < value.length; i++) {
      final entry = value[i];
      if (entry is! YamlMap) {
        throw ConfigException('telegram_commands[$i] must be a map.',
            path: '$path[$i]');
      }
      if (strictConfig) {
        _validateKnownKeys(
          entry,
          _telegramCommandKeys,
          path: '$path[$i]',
        );
      }
      final command =
          _requiredString(entry, 'command', path: '$path[$i].command');
      final description =
          _requiredString(entry, 'description', path: '$path[$i].description');
      _validateTelegramCommand(command, path: '$path[$i].command');
      commands.add(
        ConfiguredTelegramCommand(command: command, description: description),
      );
    }

    if (commands.isEmpty) {
      throw ConfigException(
        'telegram_commands must not be empty when provided.',
        path: path,
      );
    }
    return List<ConfiguredTelegramCommand>.unmodifiable(commands);
  }

  /// Merges configured commands with built-ins, keeping the first occurrence.
  static List<ConfiguredTelegramCommand> _withSystemTelegramCommands(
    List<ConfiguredTelegramCommand> configuredCommands,
  ) {
    final seen = <String>{};
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
  static void _validateTelegramCommand(String command, {required String path}) {
    final pattern = RegExp(r'^[a-z0-9_]{1,32}$');
    if (!pattern.hasMatch(command)) {
      throw ConfigException(
        'Invalid telegram command "$command". Use 1-32 chars: a-z, 0-9, _.',
        path: path,
      );
    }
  }

  /// Verifies map keys are within [allowedKeys].
  static void _validateKnownKeys(
    YamlMap map,
    Set<String> allowedKeys, {
    required String path,
  }) {
    for (final key in map.keys) {
      final name = key.toString();
      if (!allowedKeys.contains(name)) {
        throw ConfigException('Unknown key "$name".', path: '$path.$name');
      }
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

/// Configured Telegram forum topic that should map to a project path.
class ConfiguredTelegramTopic {
  /// Creates an immutable topic configuration.
  const ConfiguredTelegramTopic({
    required this.chatId,
    required this.name,
    required this.projectPath,
    this.additionalSystemPrompt,
    this.memory,
    this.memoryFilename,
    this.finalResponseOnly,
    this.telegramCommands,
  });

  /// Chat where the forum topic should exist.
  final int chatId;

  /// Forum topic name passed to Telegram when auto-creating it.
  final String name;

  /// Project path used for that topic.
  final String projectPath;

  /// Optional extra system prompt override for this topic.
  final String? additionalSystemPrompt;

  /// Optional memory enable/disable override for this topic.
  final bool? memory;

  /// Optional memory filename override for this topic.
  final String? memoryFilename;

  /// Optional final-response-only override for this topic.
  final bool? finalResponseOnly;

  /// Optional topic-specific commands merged with built-ins.
  final List<ConfiguredTelegramCommand>? telegramCommands;
}
