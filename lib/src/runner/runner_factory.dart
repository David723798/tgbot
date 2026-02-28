import 'package:tgbot/src/runner/codex_runner.dart';
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/runner/claude_runner.dart';
import 'package:tgbot/src/runner/gemini_runner.dart';
import 'package:tgbot/src/runner/opencode_runner.dart';

/// Builds a provider-specific runner from [config].
AiCliRunner createRunner(AppConfig config) {
  switch (config.provider) {
    case AiProvider.codex:
      return CodexRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: config.projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
      );
    case AiProvider.opencode:
      return OpenCodeRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: config.projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
      );
    case AiProvider.gemini:
      return GeminiRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: config.projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
      );
    case AiProvider.claude:
      return ClaudeRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: config.projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
      );
  }
}
