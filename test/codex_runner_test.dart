import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tgbot/src/runner/codex_runner.dart';

void main() {
  group('CodexRunner.runPrompt', () {
    test('streams assistant messages, extracts markers, and keeps thread ids',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
echo '{"type":"thread.started","thread_id":"thread-123"}'
echo '{"type":"assistant_message","role":"assistant","content":[{"type":"text","text":"Hello"}]}'
echo '{"type":"assistant_message","role":"assistant","content":[{"type":"text","text":"Hello"}]}'
printf '%s\n' '{"type":"assistant_message","role":"assistant","content":[{"type":"output_text","text":"TG_ARTIFACT: {\\"kind\\":\\"image\\",\\"path\\":\\"images/pic.png\\",\\"caption\\":\\"Caption\\"}\\n\\nBody"}]}'
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final streamed = <String>[];
      final result = await runner.runPrompt(
        prompt: 'show image',
        onAssistantMessage: streamed.add,
      );

      expect(streamed, hasLength(2));
      expect(streamed.first, 'Hello');
      expect(streamed.last, contains('TG_ARTIFACT:'));
      expect(result.threadId, 'thread-123');
      expect(result.messages, <String>['Hello', 'Body']);
      expect(result.text, 'Body');
      expect(result.artifacts, hasLength(1));
      expect(result.artifacts.single.kind, 'image');
      expect(result.artifacts.single.path, 'images/pic.png');
      expect(result.artifacts.single.caption, 'Caption');
      expect(result.artifact, same(result.artifacts.first));
    });

    test('falls back to plain stdout when no assistant json is present',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
printf '%s' 'plain fallback output'
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'hello');

      expect(result.messages, <String>['plain fallback output']);
      expect(result.text, 'plain fallback output');
      expect(result.artifact, isNull);
      expect(result.threadId, isNull);
    });

    test('extracts standalone artifact json and markdown artifacts', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
cat <<'EOF'
Summary line
{"type":"artifact","kind":"file","path":"docs/report.pdf","caption":"Report"}
EOF
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
        additionalSystemPrompt: 'extra rules',
      );

      final result = await runner.runPrompt(
        prompt: 'send file',
        threadId: 'thread-existing',
      );

      expect(result.threadId, 'thread-existing');
      expect(result.messages, <String>['Summary line']);
      expect(result.artifacts.single.kind, 'file');
      expect(result.artifacts.single.path, 'docs/report.pdf');
      expect(result.artifacts.single.caption, 'Report');
    });

    test('extracts loose marker payloads and markdown links', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
cat <<'EOF'
TG_ARTIFACT: {"kind":"file","path":"C:\\temp\\note.txt","caption":"Doc\/caption"}

See [report](docs/output.txt) and [site](https://example.com).
EOF
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'artifacts');

      expect(
        result.messages,
        <String>[
          'See [report](docs/output.txt) and [site](https://example.com).'
        ],
      );
      expect(result.artifacts, hasLength(1));
      expect(result.artifacts.single.kind, 'file');
      expect(result.artifacts.single.path, r'C:\temp\note.txt');
      expect(result.artifacts.single.caption, 'Doc/caption');
    });

    test('extracts markdown image artifacts and normalizes prompt wrapping',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
last_arg=""
for arg in "$@"; do
  last_arg="$arg"
done
printf '%s\n' "$last_arg"
printf '%s\n' 'Image: ![ Chart ](<images/chart.PNG>)'
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
        additionalSystemPrompt: 'follow policy',
      );

      final result = await runner.runPrompt(prompt: 'draw chart');

      expect(result.messages.first, contains('SYSTEM FOR TELEGRAM BRIDGE'));
      expect(result.messages.first,
          contains('ADDITIONAL SYSTEM INSTRUCTIONS FOR THIS BOT'));
      expect(result.messages.first, contains('USER REQUEST:\ndraw chart'));
      expect(result.artifacts.single.kind, 'image');
      expect(result.artifacts.single.path, 'images/chart.PNG');
      expect(result.artifacts.single.caption, 'Chart');
    });

    test(
        'parses additional assistant event shapes and ignores non-assistant items',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
cat <<'EOF'
{"type":"item.completed","item":{"role":"assistant","content":[{"type":"text","text":{"value":"Nested"}}]}}
{"type":"item.completed","item":{"role":"user","text":"Skip me"}}
{"type":"event","message":{"role":"assistant","text":"From message"}}
{"type":"assistant_message","role":"user","text":"Ignored"}
{"type":"assistant_message","role":"assistant","content":[{"type":"tool_call","text":"skip"},{"type":"text","text":"Allowed"}]}
{"type":"assistant_message","role":"assistant","text":"Direct text"}
EOF
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'events');

      expect(
        result.messages,
        <String>['Nested', 'From message', 'Allowed', 'Direct text'],
      );
    });

    test(
        'extracts malformed standalone artifacts and link-only markdown artifacts',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
cat <<'EOF'
Summary
{"type":"artifact","kind":"file","path":"C:\\temp\\note.txt","caption":"Doc\/caption",}
{"type":"note","text":"keep me"}
See ![remote](https://example.com/pic.png) and [local file](docs/out.txt)
EOF
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'more artifacts');

      expect(
        result.messages,
        <String>[
          'Summary\n{"type":"artifact","kind":"file","path":"C:\\\\temp\\\\note.txt","caption":"Doc\\/caption",}\n{"type":"note","text":"keep me"}\nSee ![remote](https://example.com/pic.png) and [local file](docs/out.txt)',
        ],
      );
      expect(result.artifacts.single.path, r'C:\temp\note.txt');
      expect(result.artifacts.single.caption, 'Doc/caption');
    });

    test('returns done when codex emits only an artifact marker', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
printf '%s\n' 'TG_ARTIFACT: {"kind":"image","path":"images/only.png"}'
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'artifact only');

      expect(result.messages, isEmpty);
      expect(result.text, 'Done.');
      expect(result.artifacts.single.path, 'images/only.png');
    });

    test('preserves non-artifact json lines and handles unknown loose escapes',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
cat <<'EOF'
{"type":"note","text":"keep me"}
TG_ARTIFACT: {"kind":"file","path":"C:\zdir\q.txt","caption":"Caption"}
EOF
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'json and escapes');

      expect(result.messages, <String>['{"type":"note","text":"keep me"}']);
      expect(result.artifacts.single.path, r'C:\zdir\q.txt');
      expect(result.artifacts.single.caption, 'Caption');
    });

    test('extracts local markdown links after skipping remote images',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
printf '%s\n' 'See ![remote](https://example.com/image.png) and [local doc](docs/out.txt)'
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'markdown links');

      expect(
        result.messages,
        <String>['See ![remote](https://example.com/image.png) and'],
      );
      expect(result.artifacts.single.kind, 'file');
      expect(result.artifacts.single.path, 'docs/out.txt');
      expect(result.artifacts.single.caption, 'local doc');
    });

    test('throws ProcessException for non-zero exits', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
echo 'bad stderr' >&2
exit 7
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      expect(
        () => runner.runPrompt(prompt: 'fail'),
        throwsA(
          isA<ProcessException>()
              .having((error) => error.errorCode, 'errorCode', 7)
              .having(
                  (error) => error.message, 'message', contains('bad stderr')),
        ),
      );
    });

    test('throws CodexCancelledException when the process is stopped',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
trap 'exit 143' TERM
while true; do
  sleep 1
done
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 5),
      );

      late Future<void> Function() cancel;
      final future = runner.runPrompt(
        prompt: 'cancel me',
        onCancelReady: (value) {
          cancel = value;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await cancel();

      await expectLater(future, throwsA(isA<CodexCancelledException>()));
    });

    test('throws TimeoutException when codex exceeds timeout', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-codex-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        '''
sleep 2
''',
      );
      final runner = CodexRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(milliseconds: 50),
      );

      expect(
        () => runner.runPrompt(prompt: 'slow'),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}

Future<File> _writeScript(Directory dir, String body) async {
  final file = File(
      p.join(dir.path, 'script-${DateTime.now().microsecondsSinceEpoch}.sh'));
  file.writeAsStringSync(body);
  return file;
}
