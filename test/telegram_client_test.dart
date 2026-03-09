import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tgbot/src/telegram/telegram_client.dart';

void main() {
  group('TelegramClient json requests', () {
    test('getUpdates parses response payloads', () async {
      late Uri requestUri;
      late Map<String, dynamic> body;
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          requestUri = request.url;
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'result': <Map<String, dynamic>>[
                <String, dynamic>{
                  'update_id': 9,
                  'message': <String, dynamic>{
                    'chat': <String, dynamic>{'id': 3},
                    'from': <String, dynamic>{'id': 7},
                    'text': 'hi',
                  },
                },
              ],
            }),
            200,
          );
        }),
      );

      final updates = await client.getUpdates(offset: 12, timeoutSec: 30);

      expect(requestUri.path, '/botTOKEN/getUpdates');
      expect(body['offset'], 12);
      expect(body['timeout'], 30);
      expect(body['allowed_updates'], <String>['message']);
      expect(updates.single.message!.text, 'hi');
    });

    test('setMyCommands and sendChatAction serialize payloads', () async {
      final requests = <Map<String, dynamic>>[];
      final paths = <String>[];
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          paths.add(request.url.path);
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
              jsonEncode(<String, dynamic>{'ok': true, 'result': true}), 200);
        }),
      );

      await client.setMyCommands(
        <TelegramBotCommand>[
          TelegramBotCommand(command: 'fix', description: 'Fix issue'),
        ],
      );
      await client.sendChatAction(
        chatId: 5,
        action: 'typing',
        messageThreadId: 77,
      );

      expect(paths,
          <String>['/botTOKEN/setMyCommands', '/botTOKEN/sendChatAction']);
      expect(requests.first['commands'][0]['command'], 'fix');
      expect(requests.first['commands'][0]['description'], 'Fix issue');
      expect(requests.last, <String, dynamic>{
        'chat_id': 5,
        'action': 'typing',
        'message_thread_id': 77,
      });
    });

    test('createForumTopic serializes payloads and parses result', () async {
      late String path;
      late Map<String, dynamic> body;
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          path = request.url.path;
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': true,
              'result': <String, dynamic>{
                'message_thread_id': 12345,
                'name': 'Backend',
              },
            }),
            200,
          );
        }),
      );

      final topic = await client.createForumTopic(
        chatId: -100123,
        name: 'Backend',
      );

      expect(path, '/botTOKEN/createForumTopic');
      expect(body, <String, dynamic>{'chat_id': -100123, 'name': 'Backend'});
      expect(topic.messageThreadId, 12345);
      expect(topic.name, 'Backend');
    });

    test('sendMessage chunks long text and skips blanks', () async {
      final sent = <Map<String, dynamic>>[];
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
              jsonEncode(<String, dynamic>{'ok': true, 'result': true}), 200);
        }),
      );

      final text = '${'a' * 3895}\nrest ${'b' * 20}';
      await client.sendMessage(chatId: 1, text: text);
      await client.sendMessage(chatId: 1, text: '   ');

      expect(sent, hasLength(2));
      expect(sent[0]['parse_mode'], 'HTML');
      expect(sent[1]['parse_mode'], 'HTML');
      expect(sent[0]['text'].toString().length, lessThanOrEqualTo(4000));
      expect(sent[0]['text'], endsWith('\n'));
      expect(sent[1]['text'], contains('rest'));
    });

    test('sendMessage prefers splitting on spaces when no newline is available',
        () async {
      final sent = <Map<String, dynamic>>[];
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
              jsonEncode(<String, dynamic>{'ok': true, 'result': true}), 200);
        }),
      );

      final text = '${'a' * 3895} rest ${'b' * 20}';
      await client.sendMessage(chatId: 1, text: text);

      expect(sent, hasLength(2));
      expect(sent.first['parse_mode'], 'HTML');
      expect(sent.first['text'], endsWith(' '));
      expect(sent.first['text'], contains('rest '));
    });

    test('sendMessage formats markdown-like content as Telegram HTML',
        () async {
      late Map<String, dynamic> body;
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'result': true}),
            200,
          );
        }),
      );

      await client.sendMessage(
        chatId: 1,
        text:
            '```dart\nfinal x = 1 < 2;\n```\nUse `code` with **bold**, *it*, _it2_, ~~strike~~ and [site](https://example.com).',
      );

      final html = body['text'] as String;
      expect(body['parse_mode'], 'HTML');
      expect(html, contains('<pre><code>'));
      expect(html, contains('&lt;'));
      expect(html, contains('<code>code</code>'));
      expect(html, contains('<b>bold</b>'));
      expect(html, contains('<i>it</i>'));
      expect(html, contains('<i>it2</i>'));
      expect(html, contains('<s>strike</s>'));
      expect(html, contains('<a href="https://example.com">site</a>'));
    });

    test('sendMessage keeps local-file markdown links as text', () async {
      late Map<String, dynamic> body;
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'result': true}),
            200,
          );
        }),
      );

      await client.sendMessage(
        chatId: 1,
        text:
            'See [report](file:///tmp/report.txt) and [ok](https://example.com).',
      );

      final html = body['text'] as String;
      expect(html, contains('[report](file:///tmp/report.txt)'));
      expect(html, contains('<a href="https://example.com">ok</a>'));
    });

    test('sendMessage retries parse entity errors as plain text', () async {
      final sent = <Map<String, dynamic>>[];
      var attempts = 0;
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          attempts++;
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          sent.add(payload);
          if (attempts == 1) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': false,
                'description': "Bad Request: can't parse entities",
              }),
              400,
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'ok': true, 'result': true}),
            200,
          );
        }),
      );

      await client.sendMessage(chatId: 1, text: '**bold**');

      expect(sent, hasLength(2));
      expect(sent[0]['parse_mode'], 'HTML');
      expect(sent[1].containsKey('parse_mode'), isFalse);
      expect(sent[1]['text'], '**bold**');
    });

    test('retries 429 responses and honors retry_after when present', () async {
      final completer = Completer<void>();
      var attempts = 0;
      final client = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          attempts++;
          if (attempts == 1) {
            completer.complete();
            return http.Response(
              jsonEncode(<String, dynamic>{
                'ok': false,
                'parameters': <String, dynamic>{'retry_after': 1},
              }),
              429,
            );
          }
          return http.Response(
              jsonEncode(<String, dynamic>{'ok': true, 'result': true}), 200);
        }),
      );

      await client.sendChatAction(chatId: 1, action: 'typing');

      await completer.future.timeout(const Duration(seconds: 1));
      expect(attempts, 2);
    });

    test('uses default retry delay and throws for terminal errors', () async {
      var attempts = 0;
      final retryingClient = TelegramClient(
        'TOKEN',
        client: MockClient((request) async {
          attempts++;
          if (attempts <= 3) {
            return http.Response(
              jsonEncode(<String, dynamic>{'ok': false}),
              429,
            );
          }
          return http.Response(
              jsonEncode(<String, dynamic>{'ok': true, 'result': true}), 200);
        }),
      );

      await retryingClient.sendChatAction(chatId: 1, action: 'typing');
      expect(attempts, 4);

      final failingClient = TelegramClient(
        'TOKEN',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(<String, dynamic>{'ok': false, 'description': 'bad'}),
            500,
          ),
        ),
      );

      expect(
        () => failingClient.sendChatAction(chatId: 1, action: 'typing'),
        throwsA(isA<HttpException>()),
      );
    });

    test('error messages do not expose the bot token', () async {
      final client = TelegramClient(
        'SECRET-TOKEN-123',
        client: MockClient((request) async {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'description': 'Unauthorized',
            }),
            401,
          );
        }),
      );

      expect(
        () => client.sendChatAction(chatId: 1, action: 'typing'),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            isNot(contains('SECRET-TOKEN-123')),
          ),
        ),
      );
    });

    test('transport errors do not expose the bot token', () async {
      final client = TelegramClient(
        'SECRET-TOKEN-456',
        client: MockClient((request) async {
          throw Exception(
            'Connection failed to https://api.telegram.org/botSECRET-TOKEN-456/sendChatAction',
          );
        }),
      );

      expect(
        () => client.sendChatAction(chatId: 1, action: 'typing'),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            isNot(contains('SECRET-TOKEN-456')),
          ),
        ),
      );
    });

    test('dispose closes the underlying http client', () {
      final inner = _ClosableClient();
      final client = TelegramClient('TOKEN', client: inner);

      client.dispose();

      expect(inner.closed, isTrue);
    });
  });

  group('TelegramClient multipart requests', () {
    test('sendPhoto and sendDocument upload fields and captions', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-telegram-');
      addTearDown(() => tempDir.delete(recursive: true));

      final photo = File('${tempDir.path}/photo.png')
        ..writeAsStringSync('image');
      final document = File('${tempDir.path}/report.txt')
        ..writeAsStringSync('doc');
      final requests = <_CapturedMultipartRequest>[];
      final overrides = _MultipartHttpOverrides(
        <_QueuedResponse>[
          _QueuedResponse(200, '{"ok":true,"result":true}'),
          _QueuedResponse(200, '{"ok":true,"result":true}'),
        ],
        requests,
      );

      await HttpOverrides.runZoned(() async {
        final client = TelegramClient('TOKEN');
        await client.sendPhoto(
            chatId: 1, filePath: photo.path, caption: 'Photo');
        await client.sendDocument(
            chatId: 2, filePath: document.path, caption: 'Doc');
      }, createHttpClient: overrides.createHttpClient);

      expect(requests, hasLength(2));
      expect(requests[0].uri.path, '/botTOKEN/sendPhoto');
      expect(requests[0].body, contains('name="chat_id"'));
      expect(requests[0].body, contains('1'));
      expect(requests[0].body, contains('name="caption"'));
      expect(requests[0].body, contains('Photo'));
      expect(requests[0].body, contains('name="parse_mode"'));
      expect(requests[0].body, contains('HTML'));
      expect(requests[0].body, contains('name="photo"'));
      expect(requests[1].uri.path, '/botTOKEN/sendDocument');
      expect(requests[1].body, contains('name="document"'));
      expect(requests[1].body, contains('Doc'));
      expect(requests[1].body, contains('name="parse_mode"'));
    });

    test('multipart requests retry 429 responses', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-telegram-');
      addTearDown(() => tempDir.delete(recursive: true));

      final photo = File('${tempDir.path}/photo.png')
        ..writeAsStringSync('image');
      final requests = <_CapturedMultipartRequest>[];
      final responses = <_QueuedResponse>[
        _QueuedResponse(429, '{"ok":false,"parameters":{"retry_after":1}}'),
        _QueuedResponse(200, '{"ok":true,"result":true}'),
      ];

      await HttpOverrides.runZoned(() async {
        final client = TelegramClient('TOKEN');
        await client.sendPhoto(chatId: 1, filePath: photo.path);
      },
          createHttpClient:
              _MultipartHttpOverrides(responses, requests).createHttpClient);

      expect(requests, hasLength(2));
    });

    test('multipart caption parse errors retry with plain caption', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-telegram-');
      addTearDown(() => tempDir.delete(recursive: true));

      final photo = File('${tempDir.path}/photo.png')
        ..writeAsStringSync('image');
      final requests = <_CapturedMultipartRequest>[];
      final responses = <_QueuedResponse>[
        _QueuedResponse(
          400,
          '{"ok":false,"description":"Bad Request: can\'t parse entities"}',
        ),
        _QueuedResponse(200, '{"ok":true,"result":true}'),
      ];

      await HttpOverrides.runZoned(() async {
        final client = TelegramClient('TOKEN');
        await client.sendPhoto(
          chatId: 1,
          filePath: photo.path,
          caption: '**Photo**',
        );
      },
          createHttpClient:
              _MultipartHttpOverrides(responses, requests).createHttpClient);

      expect(requests, hasLength(2));
      expect(requests.first.body, contains('name="parse_mode"'));
      expect(requests.first.body, contains('HTML'));
      expect(requests.last.body, isNot(contains('name="parse_mode"')));
      expect(requests.last.body, contains('**Photo**'));
    });
  });
}

class _ClosableClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnimplementedError('send should not be called');
  }

  @override
  void close() {
    closed = true;
  }
}

class _MultipartHttpOverrides extends HttpOverrides {
  _MultipartHttpOverrides(this._responses, this._requests);

  final List<_QueuedResponse> _responses;
  final List<_CapturedMultipartRequest> _requests;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _FakeHttpClient(_responses, _requests);
  }
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._responses, this._requests);

  final List<_QueuedResponse> _responses;
  final List<_CapturedMultipartRequest> _requests;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _FakeHttpClientRequest(
      method: method,
      url: url,
      response: _responses.removeAt(0),
      requests: _requests,
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest({
    required this.method,
    required this.url,
    required _QueuedResponse response,
    required List<_CapturedMultipartRequest> requests,
  })  : _response = response,
        _requests = requests;

  @override
  final String method;
  final Uri url;
  final _QueuedResponse _response;
  final List<_CapturedMultipartRequest> _requests;
  final _headers = _FakeHttpHeaders();
  final _body = BytesBuilder();

  @override
  final Encoding encoding = utf8;

  @override
  HttpHeaders get headers => _headers;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = -1;

  @override
  bool persistentConnection = true;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.add(chunk);
    }
  }

  @override
  void write(Object? obj) {
    _body.add(encoding.encode(obj.toString()));
  }

  @override
  Future<HttpClientResponse> close() async {
    _requests.add(
      _CapturedMultipartRequest(
        method: method,
        uri: url,
        body: utf8.decode(_body.takeBytes()),
      ),
    );
    return _FakeHttpClientResponse(_response.statusCode, _response.body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this._body);

  @override
  final int statusCode;

  final String _body;
  final _headers = _FakeHttpHeaders();

  @override
  int get contentLength => utf8.encode(_body).length;

  @override
  HttpHeaders get headers => _headers;

  @override
  bool get persistentConnection => true;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];

  @override
  String get reasonPhrase => '';

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(_body)])
        .listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = <String>[value.toString()];
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QueuedResponse {
  _QueuedResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

class _CapturedMultipartRequest {
  _CapturedMultipartRequest({
    required this.method,
    required this.uri,
    required this.body,
  });

  final String method;
  final Uri uri;
  final String body;
}
