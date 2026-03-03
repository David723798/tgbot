import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tgbot/src/runner/cursor_runner.dart';

void main() {
  group('CursorRunner.buildProcessArgs', () {
    test('uses print mode with stream-json output format', () {
      final runner = CursorRunner(
        command: 'cursor-agent',
        args: const <String>['--model', 'claude-4-sonnet'],
        projectPath: '.',
        timeout: const Duration(seconds: 5),
      );

      final processArgs = runner.buildProcessArgs(
        wrappedPrompt: 'hello',
        threadId: null,
      );

      expect(
        processArgs,
        <String>[
          '--model',
          'claude-4-sonnet',
          '--trust',
          '--print',
          '--output-format',
          'stream-json',
          'hello',
        ],
      );
    });

    test('does not add --trust when --yolo is already provided', () {
      final runner = CursorRunner(
        command: 'cursor-agent',
        args: const <String>['--yolo'],
        projectPath: '.',
        timeout: const Duration(seconds: 5),
      );

      final processArgs = runner.buildProcessArgs(
        wrappedPrompt: 'hello',
        threadId: null,
      );

      expect(processArgs.where((arg) => arg == '--trust'), isEmpty);
      expect(processArgs, <String>[
        '--yolo',
        '--print',
        '--output-format',
        'stream-json',
        'hello'
      ]);
    });

    test('uses --resume when thread id is present', () {
      final runner = CursorRunner(
        command: 'cursor-agent',
        args: const <String>[],
        projectPath: '.',
        timeout: const Duration(seconds: 5),
      );

      final processArgs = runner.buildProcessArgs(
        wrappedPrompt: 'continue',
        threadId: 'thread-123',
      );

      expect(
        processArgs,
        <String>[
          '--trust',
          '--print',
          '--output-format',
          'stream-json',
          '--resume',
          'thread-123',
          'continue',
        ],
      );
    });
  });

  group('CursorRunner.runPrompt', () {
    test('ignores user events that echo the wrapped prompt', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgbot-cursor-');
      addTearDown(() => tempDir.delete(recursive: true));

      final script = await _writeScript(
        tempDir,
        r'''
if [ "$1" = "--trust" ]; then
  shift
fi
if [ "$1" != "--print" ] || [ "$2" != "--output-format" ] || [ "$3" != "stream-json" ]; then
  echo 'wrong args' >&2
  exit 6
fi
echo '{"type":"user","message":{"role":"user","content":"SYSTEM FOR TELEGRAM BRIDGE:\n... USER REQUEST:\nwho are you?"}}'
echo '{"type":"assistant","message":{"role":"assistant","content":"你好，我係助理。"}}'
echo '{"type":"result","result":"你好，我係助理。"}'
''',
      );
      final runner = CursorRunner(
        command: '/bin/sh',
        args: <String>[script.path],
        projectPath: tempDir.path,
        timeout: const Duration(seconds: 1),
      );

      final result = await runner.runPrompt(prompt: 'who are you?');

      expect(result.messages, <String>['你好，我係助理。']);
      expect(result.text, '你好，我係助理。');
    });
  });
}

Future<File> _writeScript(Directory dir, String body) async {
  final file = File(
      p.join(dir.path, 'script-${DateTime.now().microsecondsSinceEpoch}.sh'));
  file.writeAsStringSync(body);
  return file;
}
