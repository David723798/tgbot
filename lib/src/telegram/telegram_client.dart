import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tgbot/src/models/telegram_models.dart';
import 'package:tgbot/src/telegram/telegram_text_formatter.dart';

/// Thin Telegram Bot API client with simple retry behavior.
class TelegramClient {
  /// Creates a Telegram client for a single bot token.
  TelegramClient(this.token, {http.Client? client})
      : _client = client ?? http.Client();

  /// Telegram Bot API token.
  final String token;

  /// Shared HTTP client used for requests.
  final http.Client _client;
  final TelegramTextFormatter _formatter = TelegramTextFormatter();

  /// Builds the API endpoint URI for a Telegram method.
  Uri _uri(String method) =>
      Uri.parse('https://api.telegram.org/bot$token/$method');

  /// Retrieves new message updates via Telegram long polling.
  Future<List<TelegramUpdate>> getUpdates({
    required int offset,
    required int timeoutSec,
  }) async {
    // Decoded JSON response from Telegram.
    final body = await _postWithRetry(
      'getUpdates',
      jsonEncode(<String, dynamic>{
        'offset': offset,
        'timeout': timeoutSec,
        'allowed_updates': <String>['message'],
      }),
    );
    // Raw updates array returned by Telegram.
    final results = body['result'] as List<dynamic>;
    return results
        .map((dynamic e) => TelegramUpdate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Registers the slash commands shown by Telegram clients.
  Future<void> setMyCommands(List<TelegramBotCommand> commands) async {
    await _postWithRetry(
      'setMyCommands',
      jsonEncode(<String, dynamic>{
        'commands': commands
            .map(
              (command) => <String, String>{
                'command': command.command,
                'description': command.description,
              },
            )
            .toList(),
      }),
    );
  }

  /// Sends a text message, splitting long responses into safe chunks.
  Future<void> sendMessage({required int chatId, required String text}) async {
    if (text.trim().isEmpty) return;
    for (final chunk in _buildFormattedChunks(text, _plainChunkLimit)) {
      final htmlPayload = <String, dynamic>{
        'chat_id': chatId,
        'text': chunk.html,
        'parse_mode': 'HTML',
      };
      try {
        await _postWithRetry('sendMessage', jsonEncode(htmlPayload));
      } on HttpException catch (error) {
        if (!_isEntityParseError(error)) {
          rethrow;
        }
        await _postWithRetry(
          'sendMessage',
          jsonEncode(<String, dynamic>{'chat_id': chatId, 'text': chunk.plain}),
        );
      }
    }
  }

  /// Sends a transient chat action such as `typing`.
  Future<void> sendChatAction({
    required int chatId,
    required String action,
  }) async {
    await _postWithRetry(
      'sendChatAction',
      jsonEncode(<String, dynamic>{'chat_id': chatId, 'action': action}),
    );
  }

  /// Uploads an image file as a Telegram photo.
  Future<void> sendPhoto({
    required int chatId,
    required String filePath,
    String? caption,
  }) async {
    final formattedCaption = _formatCaption(caption);
    try {
      await _multipartWithRetry('sendPhoto', () async {
        // Multipart request for the photo upload.
        final req = http.MultipartRequest('POST', _uri('sendPhoto'))
          ..fields['chat_id'] = '$chatId';
        if (formattedCaption != null) {
          req.fields['caption'] = formattedCaption.html;
          req.fields['parse_mode'] = 'HTML';
        }
        req.files.add(await http.MultipartFile.fromPath('photo', filePath));
        return req;
      });
    } on HttpException catch (error) {
      if (formattedCaption == null || !_isEntityParseError(error)) {
        rethrow;
      }
      await _multipartWithRetry('sendPhoto', () async {
        final req = http.MultipartRequest('POST', _uri('sendPhoto'))
          ..fields['chat_id'] = '$chatId'
          ..fields['caption'] = formattedCaption.plain;
        req.files.add(await http.MultipartFile.fromPath('photo', filePath));
        return req;
      });
    }
  }

  /// Uploads a generic file as a Telegram document.
  Future<void> sendDocument({
    required int chatId,
    required String filePath,
    String? caption,
  }) async {
    final formattedCaption = _formatCaption(caption);
    try {
      await _multipartWithRetry('sendDocument', () async {
        // Multipart request for the document upload.
        final req = http.MultipartRequest('POST', _uri('sendDocument'))
          ..fields['chat_id'] = '$chatId';
        if (formattedCaption != null) {
          req.fields['caption'] = formattedCaption.html;
          req.fields['parse_mode'] = 'HTML';
        }
        req.files.add(await http.MultipartFile.fromPath('document', filePath));
        return req;
      });
    } on HttpException catch (error) {
      if (formattedCaption == null || !_isEntityParseError(error)) {
        rethrow;
      }
      await _multipartWithRetry('sendDocument', () async {
        final req = http.MultipartRequest('POST', _uri('sendDocument'))
          ..fields['chat_id'] = '$chatId'
          ..fields['caption'] = formattedCaption.plain;
        req.files.add(await http.MultipartFile.fromPath('document', filePath));
        return req;
      });
    }
  }

  /// Closes the underlying HTTP client.
  void dispose() {
    _client.close();
  }

  /// Splits long text into Telegram-sized chunks.
  List<String> _chunk(String text, int maxLen) {
    if (text.length <= maxLen) return <String>[text];
    // Output chunks built from the source text.
    final parts = <String>[];
    // Start offset for the next chunk.
    var start = 0;
    while (start < text.length) {
      if (start + maxLen >= text.length) {
        parts.add(text.substring(start));
        break;
      }
      // Tentative end index before trying cleaner split points.
      var end = start + maxLen;
      // Try to split at a newline first, then a space, to avoid mid-word cuts.
      // Last newline before the tentative boundary.
      final newlineIdx = text.lastIndexOf('\n', end);
      if (newlineIdx > start) {
        end = newlineIdx + 1;
      } else {
        // Last space before the tentative boundary.
        final spaceIdx = text.lastIndexOf(' ', end);
        if (spaceIdx > start) {
          end = spaceIdx + 1;
        }
      }
      parts.add(text.substring(start, end));
      start = end;
    }
    return parts;
  }

  /// Returns plain/html chunk pairs bounded to Telegram limits.
  List<_FormattedChunk> _buildFormattedChunks(String text, int maxPlainLen) {
    final out = <_FormattedChunk>[];
    final queue = ListQueue<String>.from(_chunk(text, maxPlainLen));
    while (queue.isNotEmpty) {
      final plain = queue.removeFirst();
      if (plain.isEmpty) {
        continue;
      }
      final formatted = _formatter.format(plain);
      if (formatted.html.length <= _messageMaxLen) {
        out.add(_FormattedChunk(plain: formatted.plain, html: formatted.html));
        continue;
      }
      if (plain.length <= 1) {
        out.add(_FormattedChunk(plain: formatted.plain, html: formatted.html));
        continue;
      }
      final nextChunks = _chunk(plain, (plain.length / 2).floor());
      if (nextChunks.length <= 1) {
        out.add(_FormattedChunk(plain: formatted.plain, html: formatted.html));
        continue;
      }
      for (var i = nextChunks.length - 1; i >= 0; i--) {
        queue.addFirst(nextChunks[i]);
      }
    }
    return out;
  }

  TelegramFormattedText? _formatCaption(String? caption) {
    if (caption == null || caption.isEmpty) {
      return null;
    }
    return _formatter.format(caption);
  }

  bool _isEntityParseError(HttpException error) {
    final text = error.message.toLowerCase();
    return text.contains('parse entities');
  }

  /// Maximum retries after a Telegram rate-limit response.
  static const int _maxRetries = 3;
  static const int _messageMaxLen = 4000;
  static const int _plainChunkLimit = 3900;

  /// Sends a JSON POST request with retry support for HTTP 429.
  Future<Map<String, dynamic>> _postWithRetry(
    String method,
    String encodedBody,
  ) async {
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      // HTTP response for the current attempt.
      final http.Response response;
      try {
        response = await _client.post(
          _uri(method),
          headers: <String, String>{'content-type': 'application/json'},
          body: encodedBody,
        );
      } on Exception catch (e) {
        // Mask token in transport-level errors that may include the URL.
        throw HttpException(_maskToken(e.toString()));
      }
      // Decoded JSON body from Telegram.
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 429 && attempt < _maxRetries) {
        await _delayForRetry(body);
        continue;
      }
      _expectOk(response.statusCode, body, method);
      return body;
    }
    // Unreachable, but satisfies the type system.
    // coverage:ignore-start
    throw StateError('Exhausted retries for $method');
    // coverage:ignore-end
  }

  /// Sends a multipart request with retry support for HTTP 429.
  Future<void> _multipartWithRetry(
    String method,
    Future<http.MultipartRequest> Function() buildRequest,
  ) async {
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      // Fresh request object rebuilt for each retry.
      final req = await buildRequest();
      // Streaming response returned by Telegram.
      final http.StreamedResponse streamed;
      try {
        streamed = await req.send();
      } on Exception catch (e) {
        // Mask token in transport-level errors that may include the URL.
        throw HttpException(_maskToken(e.toString()));
      }
      // Full response body text.
      final bodyText = await streamed.stream.bytesToString();
      // Decoded JSON body from Telegram.
      final body = jsonDecode(bodyText) as Map<String, dynamic>;
      if (streamed.statusCode == 429 && attempt < _maxRetries) {
        await _delayForRetry(body);
        continue;
      }
      _expectOk(streamed.statusCode, body, method);
      return;
    }
  }

  /// Sleeps for Telegram's requested backoff period after rate limiting.
  Future<void> _delayForRetry(Map<String, dynamic> body) async {
    // Default retry delay when Telegram omits `retry_after`.
    var delaySec = 1;
    // Optional error parameters object returned by Telegram.
    final params = body['parameters'];
    if (params is Map<String, dynamic>) {
      // Retry delay requested by Telegram.
      final retryAfter = params['retry_after'];
      if (retryAfter is int && retryAfter > 0) {
        delaySec = retryAfter;
      }
    }
    await Future<void>.delayed(Duration(seconds: delaySec));
  }

  /// Replaces the bot token with a placeholder in [value].
  String _maskToken(String value) {
    if (token.isEmpty) return value;
    return value.replaceAll(token, '***');
  }

  /// Throws when Telegram reports an error response.
  void _expectOk(int statusCode, Map<String, dynamic> body, String method) {
    // Telegram's success flag in the response body.
    final ok = body['ok'] == true;
    if (statusCode >= 400 || !ok) {
      throw HttpException(
        'Telegram $method failed: status=$statusCode body=${_maskToken('$body')}',
      );
    }
  }
}

class _FormattedChunk {
  _FormattedChunk({required this.plain, required this.html});

  final String plain;
  final String html;
}

/// Telegram command descriptor sent to `setMyCommands`.
class TelegramBotCommand {
  /// Creates a Telegram bot command object.
  TelegramBotCommand({required this.command, required this.description});

  /// Command name without the leading slash.
  final String command;

  /// Human-readable command description.
  final String description;
}
