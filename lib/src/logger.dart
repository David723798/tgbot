import 'dart:convert';
import 'dart:io';

import 'package:tgbot/src/config.dart';

/// Structured runtime logger used by the bridge app.
class AppLogger {
  AppLogger({
    required this.botName,
    required this.provider,
    required this.level,
    required this.format,
  });

  final String botName;
  final AiProvider provider;
  final LogLevel level;
  final LogFormat format;

  void debug(String message, {Map<String, Object?> fields = const {}}) {
    _log(LogLevel.debug, message, fields: fields);
  }

  void info(String message, {Map<String, Object?> fields = const {}}) {
    _log(LogLevel.info, message, fields: fields);
  }

  void warn(String message, {Map<String, Object?> fields = const {}}) {
    _log(LogLevel.warn, message, fields: fields);
  }

  void error(String message, {Map<String, Object?> fields = const {}}) {
    _log(LogLevel.error, message, fields: fields);
  }

  bool _enabled(LogLevel eventLevel) => eventLevel.index >= level.index;

  void _log(
    LogLevel eventLevel,
    String message, {
    Map<String, Object?> fields = const {},
  }) {
    if (!_enabled(eventLevel)) {
      return;
    }

    final payload = <String, Object?>{
      'bot': botName,
      'provider': provider.name,
      'level': eventLevel.name,
      'message': message,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      ...fields,
    };

    if (format == LogFormat.json) {
      stderr.writeln(jsonEncode(payload));
      return;
    }

    final fieldText =
        fields.entries.map((entry) => '${entry.key}=${entry.value}').join(' ');
    final suffix = fieldText.isEmpty ? '' : ' $fieldText';
    stderr.writeln(
      '[${payload['timestamp']}] [${eventLevel.name}] '
      '[${provider.name}] [$botName] $message$suffix',
    );
  }
}
