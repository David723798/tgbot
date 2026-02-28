import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tgbot/src/runner/gemini_runner.dart';

void main() {
  group('GeminiRunner.runPrompt', () {
    test('parses json output and extracts artifact markers', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-gemini-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
cat <<'EOF_JSON'
{"session_id":"gem-1","response":{"text":"TG_ARTIFACT: {\\"kind\\":\\"image\\",\\"path\\":\\"images/p.png\\"}\\n\\nfinal"}}
EOF_JSON
''',
      );
      final runner = GeminiRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'send image');

      expect(result.messages, <String>['final']);
      expect(result.text, 'final');
      expect(result.artifacts.single.kind, 'image');
      expect(result.artifacts.single.path, 'images/p.png');
      expect(result.threadId, 'gem-1');
    });

    test('uses --resume when thread id is provided', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-gemini-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
if [ "$1" = "--resume" ] && [ "$2" = "gem-prev" ] && [ "$3" = "--prompt" ] && [ "$5" = "--output-format" ] && [ "$6" = "json" ]; then
  echo '{"session_id":"gem-prev","response":{"text":"ok"}}'
  exit 0
fi
exit 9
''',
      );
      final runner = GeminiRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result =
          await runner.runPrompt(prompt: 'resume', threadId: 'gem-prev');

      expect(result.text, 'ok');
      expect(result.threadId, 'gem-prev');
    });

    test('falls back to plain output when json parsing fails', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-gemini-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
printf '%s' 'plain fallback'
''',
      );
      final runner = GeminiRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'plain');

      expect(result.messages, <String>['plain fallback']);
      expect(result.text, 'plain fallback');
    });

    test('keeps the final assistant message as result.text', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-gemini-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
cat <<'EOF_JSON'
{"response":{"content":[{"text":"draft"},{"text":"final answer"}]}}
EOF_JSON
''',
      );
      final runner = GeminiRunner(
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
