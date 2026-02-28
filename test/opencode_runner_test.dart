import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tgbot/src/runner/opencode_runner.dart';

void main() {
  group('OpenCodeRunner.runPrompt', () {
    test('streams json messages, extracts artifacts, and keeps conversation id',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
echo '{"conversation_id":"conv-77"}'
echo '{"role":"assistant","text":"hello"}'
printf '%s\n' '{"role":"assistant","text":"TG_ARTIFACT: {\\"kind\\":\\"file\\",\\"path\\":\\"docs/a.txt\\"}\\n\\nDone"}'
''',
      );
      final runner = OpenCodeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final streamed = <String>[];
      final result = await runner.runPrompt(
        prompt: 'send file',
        onAssistantMessage: streamed.add,
      );

      expect(streamed, hasLength(2));
      expect(streamed.first, 'hello');
      expect(streamed.last, contains('TG_ARTIFACT:'));
      expect(result.messages, <String>['hello', 'Done']);
      expect(result.threadId, 'conv-77');
      expect(result.artifacts.single.path, 'docs/a.txt');
    });

    test('uses --session when thread id is provided', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
if [ "$1" = "run" ] && [ "$2" = "--session" ] && [ "$3" = "conv-1" ] && [ "$4" = "--format" ] && [ "$5" = "json" ]; then
  echo '{"role":"assistant","text":"ok"}'
  exit 0
fi
exit 5
''',
      );
      final runner = OpenCodeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result =
          await runner.runPrompt(prompt: 'resume', threadId: 'conv-1');

      expect(result.text, 'ok');
      expect(result.threadId, 'conv-1');
    });

    test('passes configured args through to command', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
if [ "$1" = "--yolo" ] && [ "$2" = "run" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
  echo '{"role":"assistant","text":"ok"}'
  exit 0
fi
exit 12
''',
      );
      final runner = OpenCodeRunner(
        command: '/bin/sh',
        args: <String>[script.path, '--yolo'],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'hello');

      expect(result.text, 'ok');
    });

    test('falls back to plain stdout when no json message exists', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
printf '%s' 'plain output'
''',
      );
      final runner = OpenCodeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'fallback');

      expect(result.messages, <String>['plain output']);
      expect(result.text, 'plain output');
    });

    test('parses json response from stderr stream', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
printf '%s\n' '{"conversation_id":"conv-stderr"}' 1>&2
printf '%s\n' '{"role":"assistant","text":"from-stderr"}' 1>&2
''',
      );
      final runner = OpenCodeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final streamed = <String>[];
      final result = await runner.runPrompt(
        prompt: 'hello',
        onAssistantMessage: streamed.add,
      );

      expect(streamed, <String>['from-stderr']);
      expect(result.messages, <String>['from-stderr']);
      expect(result.text, 'from-stderr');
      expect(result.threadId, 'conv-stderr');
    });

    test('handles multi-event json stream with part.text and sessionID',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
printf '%s\n' '{"type":"step_start","sessionID":"ses_123","part":{"type":"step-start"}}'
printf '%s\n' '{"type":"text","sessionID":"ses_123","part":{"type":"text","text":"1+1 = 2"}}'
printf '%s\n' '{"type":"step_finish","sessionID":"ses_123","part":{"type":"step-finish","reason":"stop"}}'
''',
      );
      final runner = OpenCodeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final streamed = <String>[];
      final result = await runner.runPrompt(
        prompt: '1+1?',
        onAssistantMessage: streamed.add,
      );

      expect(streamed, <String>['1+1 = 2']);
      expect(result.messages, <String>['1+1 = 2']);
      expect(result.text, '1+1 = 2');
      expect(result.threadId, 'ses_123');
    });

    test('closes stdin so command does not hang waiting for input', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
cat >/dev/null
echo '{"role":"assistant","text":"stdin-closed"}'
''',
      );
      final runner = OpenCodeRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'hello');

      expect(result.text, 'stdin-closed');
    });

    test('keeps the final assistant message as result.text', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-opencode-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
echo '{"role":"assistant","text":"draft"}'
echo '{"role":"assistant","text":"final answer"}'
''',
      );
      final runner = OpenCodeRunner(
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
