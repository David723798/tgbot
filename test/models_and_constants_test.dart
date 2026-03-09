import 'package:test/test.dart';
import 'package:tgbot/src/default_config_template.dart';
import 'package:tgbot/src/models/telegram_models.dart';
import 'package:tgbot/src/version.dart';

void main() {
  test('Telegram models parse JSON payloads', () {
    final update = TelegramUpdate.fromJson(<String, dynamic>{
      'update_id': 5,
      'message': <String, dynamic>{
        'chat': <String, dynamic>{'id': 99},
        'from': <String, dynamic>{'id': 42},
        'text': 'hello',
      },
    });

    expect(update.updateId, 5);
    expect(update.message!.chatId, 99);
    expect(update.message!.fromUserId, 42);
    expect(update.message!.messageThreadId, isNull);
    expect(update.message!.text, 'hello');

    final systemMessage = TelegramMessage.fromJson(<String, dynamic>{
      'chat': <String, dynamic>{'id': 10},
      'message_thread_id': 88,
      'text': null,
    });
    expect(systemMessage.fromUserId, 0);
    expect(systemMessage.messageThreadId, 88);
    expect(systemMessage.text, isNull);
  });

  test('ArtifactResponse stores payload fields', () {
    final artifact = ArtifactResponse(
      kind: 'image',
      path: 'images/chart.png',
      caption: 'Chart',
    );

    expect(artifact.kind, 'image');
    expect(artifact.path, 'images/chart.png');
    expect(artifact.caption, 'Chart');
  });

  test('TelegramForumTopic parses JSON payloads', () {
    final topic = TelegramForumTopic.fromJson(<String, dynamic>{
      'message_thread_id': 123,
      'name': 'Backend',
    });

    expect(topic.messageThreadId, 123);
    expect(topic.name, 'Backend');
  });

  test('default config template and version are exposed', () {
    expect(defaultConfigTemplate, contains('telegram_bot_token'));
    expect(defaultConfigTemplate, contains('allowed_user_ids'));
    expect(version, '0.2.5');
  });
}
