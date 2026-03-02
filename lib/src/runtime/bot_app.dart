import 'package:tgbot/src/config.dart';

/// Runtime contract implemented by long-lived bot app workers.
abstract class BotApp {
  AppConfig get config;

  Future<void> run();

  Future<void> stop();
}
