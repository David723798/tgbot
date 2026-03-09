import 'dart:convert';
import 'dart:io';

/// Persistent local registry for forum topic ids created by the bot.
class TopicRegistry {
  /// Creates a registry backed by [path].
  TopicRegistry({String path = '.tgbot-topic-registry.json'}) : _path = path;

  final String _path;
  Map<String, dynamic>? _cache;

  /// Returns the stored topic id for the given bot/chat/name tuple.
  int? lookup({
    required String botName,
    required int chatId,
    required String topicName,
  }) {
    final raw =
        _load()[_key(botName: botName, chatId: chatId, topicName: topicName)];
    return raw is int ? raw : int.tryParse(raw?.toString() ?? '');
  }

  /// Stores the resolved topic id for the given bot/chat/name tuple.
  Future<void> store({
    required String botName,
    required int chatId,
    required String topicName,
    required int topicId,
  }) async {
    final cache = _load();
    cache[_key(botName: botName, chatId: chatId, topicName: topicName)] =
        topicId;
    final file = File(_path);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(cache),
    );
  }

  Map<String, dynamic> _load() {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }

    final file = File(_path);
    if (!file.existsSync()) {
      return _cache = <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return _cache = decoded;
      }
    } catch (_) {
      // Invalid registry content falls back to a fresh registry.
    }
    return _cache = <String, dynamic>{};
  }

  String _key({
    required String botName,
    required int chatId,
    required String topicName,
  }) {
    return '$botName::$chatId::$topicName';
  }
}
