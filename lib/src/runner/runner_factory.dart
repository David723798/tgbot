import 'package:tgbot/src/runner/codex_runner.dart';
import 'package:tgbot/src/config.dart';
import 'package:tgbot/src/runner/claude_runner.dart';
import 'package:tgbot/src/runner/cursor_runner.dart';
import 'package:tgbot/src/runner/gemini_runner.dart';
import 'package:tgbot/src/runner/opencode_runner.dart';

/// Builds a provider-specific runner from [config].
AiCliRunner createRunner(AppConfig config) {
  final projectPath = config.projectPath;
  if (projectPath == null) {
    throw StateError('No default project_path configured for this bot.');
  }
  return createRunnerForProjectPath(config, projectPath);
}

/// Builds a provider-specific runner from [config] for [projectPath].
AiCliRunner createRunnerForProjectPath(AppConfig config, String projectPath) {
  switch (config.provider) {
    case AiProvider.codex:
      return CodexRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
        memory: config.memory,
        memoryFilename: config.memoryFilename,
      );
    case AiProvider.cursor:
      return CursorRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
        memory: config.memory,
        memoryFilename: config.memoryFilename,
      );
    case AiProvider.opencode:
      return OpenCodeRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
        memory: config.memory,
        memoryFilename: config.memoryFilename,
      );
    case AiProvider.gemini:
      return GeminiRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
        memory: config.memory,
        memoryFilename: config.memoryFilename,
      );
    case AiProvider.claude:
      return ClaudeRunner(
        command: config.aiCliCmd,
        args: config.aiCliArgs,
        projectPath: projectPath,
        timeout: config.aiCliTimeout,
        additionalSystemPrompt: config.additionalSystemPrompt,
        memory: config.memory,
        memoryFilename: config.memoryFilename,
      );
  }
}
