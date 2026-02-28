import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tgbot/src/runner/claude_runner.dart';

void main() {
  group('ClaudeRunner.runPrompt', () {
    test('uses --resume and extracts session id from stream-json', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-claude-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
if [ "$1" = "--verbose" ] && [ "$2" = "--print" ] && [ "$3" = "--output-format" ] && [ "$4" = "stream-json" ] && [ "$5" = "--resume" ] && [ "$6" = "thread-1" ]; then
  :
else
  echo 'wrong args' >&2
  exit 6
fi
echo '{"session_id":"session-22"}'
echo '{"role":"assistant","text":"hello"}'
''',
      );
      final runner = ClaudeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(
        prompt: 'hello',
        threadId: 'thread-1',
      );

      expect(result.messages, <String>['hello']);
      expect(result.threadId, 'session-22');
    });

    test('falls back to existing thread when stream has no session id',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-claude-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
echo '{"role":"assistant","content":[{"type":"text","text":"done"}]}'
''',
      );
      final runner = ClaudeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(
        prompt: 'hello',
        threadId: 'keep-me',
      );

      expect(result.messages, <String>['done']);
      expect(result.threadId, 'keep-me');
    });

    test('keeps the final assistant message as result.text', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-claude-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
echo '{"role":"assistant","text":"draft"}'
echo '{"role":"assistant","text":"final answer"}'
''',
      );
      final runner = ClaudeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'hello');

      expect(result.messages, <String>['draft', 'final answer']);
      expect(result.text, 'final answer');
    });
  });
}

Future<File> _writeScript(Directory dir, String body) async {
  final file = File(
      p.join(dir.path, 'script-${DateTime.now().microsecondsSinceEpoch}.sh'));
  file.writeAsStringSync(body);
  return file;
}
