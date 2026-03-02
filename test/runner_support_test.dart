import 'dart:convert';

import 'package:test/test.dart';
import 'package:tgbot/src/runner/runner_support.dart';

void main() {
  group('normalizePromptForProcessArg', () {
    test('keeps prompt unchanged when not running on windows', () {
      const prompt = 'line one\nline two';

      final normalized =
          normalizePromptForProcessArg(prompt, forceWindows: false);

      expect(normalized, prompt);
    });

    test('escapes newlines when running on windows', () {
      const prompt = 'line one\r\nline two\nline three';

      final normalized =
          normalizePromptForProcessArg(prompt, forceWindows: true);

      expect(normalized, r'line one\nline two\nline three');
    });
  });

  group('buildPrompt', () {
    test('includes bridge instruction and user prompt', () {
      final result = buildPrompt(
        userPrompt: 'Fix the bug',
        additionalSystemPrompt: null,
        includeAdditionalSystemPrompt: true,
        includeMemoryInstruction: false,
      );

      expect(result, contains(bridgeInstruction));
      expect(result, contains('USER REQUEST:'));
      expect(result, contains('Fix the bug'));
      expect(result, isNot(contains('ADDITIONAL SYSTEM INSTRUCTIONS')));
    });

    test('includes additional system prompt when provided', () {
      final result = buildPrompt(
        userPrompt: 'Fix the bug',
        additionalSystemPrompt: 'Be brief.',
        includeAdditionalSystemPrompt: true,
        includeMemoryInstruction: false,
      );

      expect(result, contains(bridgeInstruction));
      expect(result, contains('ADDITIONAL SYSTEM INSTRUCTIONS'));
      expect(result, contains('Be brief.'));
      expect(result, contains('Fix the bug'));
    });

    test('treats empty additional system prompt as absent', () {
      final result = buildPrompt(
        userPrompt: 'Hello',
        additionalSystemPrompt: '',
        includeAdditionalSystemPrompt: true,
        includeMemoryInstruction: false,
      );

      expect(result, isNot(contains('ADDITIONAL SYSTEM INSTRUCTIONS')));
    });

    test('skips additional system prompt after first session question', () {
      final result = buildPrompt(
        userPrompt: 'Follow up',
        additionalSystemPrompt: 'Be brief.',
        includeAdditionalSystemPrompt: false,
        includeMemoryInstruction: false,
      );

      expect(result, isNot(contains('ADDITIONAL SYSTEM INSTRUCTIONS')));
      expect(result, contains('USER REQUEST:\nFollow up'));
    });

    test('includes memory instructions when enabled', () {
      final result = buildPrompt(
        userPrompt: 'First question',
        additionalSystemPrompt: null,
        includeAdditionalSystemPrompt: false,
        includeMemoryInstruction: true,
      );

      expect(result, contains('MEMORY INSTRUCTIONS:'));
      expect(result, contains('`MEMORY.md`'));
      expect(result, contains('USER REQUEST:\nFirst question'));
    });

    test('uses custom memory filename when provided', () {
      final result = buildPrompt(
        userPrompt: 'First question',
        additionalSystemPrompt: null,
        includeAdditionalSystemPrompt: false,
        includeMemoryInstruction: true,
        memoryFilename: 'TEAM_MEMORY.md',
      );

      expect(result, contains('MEMORY INSTRUCTIONS:'));
      expect(result, contains('`TEAM_MEMORY.md`'));
      expect(result, contains('USER REQUEST:\nFirst question'));
    });
  });

  group('parseAssistantMessages', () {
    test('returns Done for empty input', () {
      final result = parseAssistantMessages(<String>[]);

      expect(result.text, 'Done.');
      expect(result.messages, isEmpty);
      expect(result.artifacts, isEmpty);
    });

    test('returns plain text message unchanged', () {
      final result = parseAssistantMessages(<String>['Hello world']);

      expect(result.text, 'Hello world');
      expect(result.messages, <String>['Hello world']);
      expect(result.artifacts, isEmpty);
    });

    test('extracts TG_ARTIFACT marker', () {
      final result = parseAssistantMessages(<String>[
        'Here is the image.\n'
            'TG_ARTIFACT: {"kind":"image","path":"out/plot.png","caption":"Chart"}',
      ]);

      expect(result.artifacts, hasLength(1));
      expect(result.artifacts.first.kind, 'image');
      expect(result.artifacts.first.path, 'out/plot.png');
      expect(result.artifacts.first.caption, 'Chart');
      expect(result.messages.first, isNot(contains('TG_ARTIFACT')));
    });

    test('extracts artifact from standalone JSON line', () {
      final result = parseAssistantMessages(<String>[
        '{"type":"artifact","kind":"file","path":"report.txt"}',
      ]);

      expect(result.artifacts, hasLength(1));
      expect(result.artifacts.first.kind, 'file');
      expect(result.artifacts.first.path, 'report.txt');
    });

    test('extracts image artifact from markdown link', () {
      final result = parseAssistantMessages(<String>[
        'Check this out:\n![Chart](artifacts/chart.png)',
      ]);

      expect(result.artifacts, hasLength(1));
      expect(result.artifacts.first.kind, 'image');
      expect(result.artifacts.first.path, 'artifacts/chart.png');
    });

    test('extracts file artifact from markdown link by extension', () {
      final result = parseAssistantMessages(<String>[
        'See the report: [Report](output/report.txt)',
      ]);

      expect(result.artifacts, hasLength(1));
      expect(result.artifacts.first.kind, 'file');
      expect(result.artifacts.first.path, 'output/report.txt');
    });

    test('does not extract http links as artifacts', () {
      final result = parseAssistantMessages(<String>[
        'See [docs](https://example.com/docs)',
      ]);

      expect(result.artifacts, isEmpty);
    });

    test('strips whitespace-only messages', () {
      final result = parseAssistantMessages(<String>['  \n  ', 'Hello']);

      expect(result.messages, <String>['Hello']);
      expect(result.text, 'Hello');
    });

    test('handles multiple messages', () {
      final result = parseAssistantMessages(<String>[
        'First message',
        'Second message',
      ]);

      expect(result.messages, hasLength(2));
      expect(result.text, 'Second message');
    });
  });

  group('extractAssistantMessagesFromJsonLines', () {
    test('extracts text from valid JSON lines', () {
      final output = <String>[
        jsonEncode(<String, dynamic>{'text': 'Hello'}),
        jsonEncode(<String, dynamic>{'text': 'World'}),
      ].join('\n');

      String? extractor(Map<String, dynamic> event) =>
          event['text']?.toString();

      final result = extractAssistantMessagesFromJsonLines(output, extractor);

      expect(result, <String>['Hello', 'World']);
    });

    test('skips malformed JSON lines', () {
      final output = '{"text":"Hello"}\nnot json\n{"text":"World"}';

      String? extractor(Map<String, dynamic> event) =>
          event['text']?.toString();

      final result = extractAssistantMessagesFromJsonLines(output, extractor);

      expect(result, <String>['Hello', 'World']);
    });

    test('deduplicates adjacent identical messages', () {
      final output = <String>[
        jsonEncode(<String, dynamic>{'text': 'Hello'}),
        jsonEncode(<String, dynamic>{'text': 'Hello'}),
        jsonEncode(<String, dynamic>{'text': 'World'}),
      ].join('\n');

      String? extractor(Map<String, dynamic> event) =>
          event['text']?.toString();

      final result = extractAssistantMessagesFromJsonLines(output, extractor);

      expect(result, <String>['Hello', 'World']);
    });

    test('falls back to raw text when no JSON found', () {
      const output = 'Plain text output';

      String? extractor(Map<String, dynamic> event) =>
          event['text']?.toString();

      final result = extractAssistantMessagesFromJsonLines(output, extractor);

      expect(result, <String>['Plain text output']);
    });

    test('returns empty list for empty output', () {
      String? extractor(Map<String, dynamic> event) =>
          event['text']?.toString();

      final result = extractAssistantMessagesFromJsonLines('', extractor);

      expect(result, isEmpty);
    });

    test('skips lines where extractor returns null', () {
      final output = <String>[
        jsonEncode(<String, dynamic>{'role': 'system', 'text': 'skip'}),
        jsonEncode(<String, dynamic>{'role': 'assistant', 'text': 'keep'}),
      ].join('\n');

      String? extractor(Map<String, dynamic> event) {
        if (event['role'] != 'assistant') return null;
        return event['text']?.toString();
      }

      final result = extractAssistantMessagesFromJsonLines(output, extractor);

      expect(result, <String>['keep']);
    });
  });

  group('extractIdFromJsonLines', () {
    test('extracts id from matching key', () {
      final output = jsonEncode(<String, dynamic>{
        'session_id': 'abc-123',
      });

      final result = extractIdFromJsonLines(
        output,
        const <String>['session_id', 'thread_id'],
      );

      expect(result, 'abc-123');
    });

    test('finds id in nested JSON objects', () {
      final output = jsonEncode(<String, dynamic>{
        'data': <String, dynamic>{'thread_id': 'nested-456'},
      });

      final result = extractIdFromJsonLines(
        output,
        const <String>['thread_id'],
      );

      expect(result, 'nested-456');
    });

    test('returns null when no matching key found', () {
      final output = jsonEncode(<String, dynamic>{
        'unrelated': 'value',
      });

      final result = extractIdFromJsonLines(
        output,
        const <String>['session_id'],
      );

      expect(result, isNull);
    });

    test('returns first match from multiple lines', () {
      final output = <String>[
        jsonEncode(<String, dynamic>{'session_id': 'first'}),
        jsonEncode(<String, dynamic>{'session_id': 'second'}),
      ].join('\n');

      final result = extractIdFromJsonLines(
        output,
        const <String>['session_id'],
      );

      expect(result, 'first');
    });

    test('skips empty id values', () {
      final output = <String>[
        jsonEncode(<String, dynamic>{'session_id': ''}),
        jsonEncode(<String, dynamic>{'session_id': 'valid'}),
      ].join('\n');

      final result = extractIdFromJsonLines(
        output,
        const <String>['session_id'],
      );

      expect(result, 'valid');
    });
  });

  group('extractTextFromCommonEvent', () {
    test('extracts direct text field', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'text': 'Hello world',
      });

      expect(result, 'Hello world');
    });

    test('extracts message field', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'message': 'Hello',
      });

      expect(result, 'Hello');
    });

    test('extracts from nested message map', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'message': <String, dynamic>{'text': 'Nested'},
      });

      expect(result, 'Nested');
    });

    test('extracts from content list', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'First'},
          <String, dynamic>{'type': 'text', 'text': 'Second'},
        ],
      });

      expect(result, 'First\nSecond');
    });

    test('filters non-assistant roles from content list entries', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'text': 'skip'},
          <String, dynamic>{'role': 'assistant', 'text': 'keep'},
        ],
      });

      expect(result, 'keep');
    });

    test('filters non-text content types', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'tool_use', 'text': 'skip'},
          <String, dynamic>{'type': 'text', 'text': 'keep'},
        ],
      });

      expect(result, 'keep');
    });

    test('rejects non-assistant role at top level', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'role': 'user',
        'text': 'Should not be extracted',
      });

      expect(result, isNull);
    });

    test('extracts delta field', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'delta': 'Incremental',
      });

      expect(result, 'Incremental');
    });

    test('extracts part field', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'part': 'A part',
      });

      expect(result, 'A part');
    });

    test('extracts data field', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'data': 'Some data',
      });

      expect(result, 'Some data');
    });

    test('returns null for empty event', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{});

      expect(result, isNull);
    });

    test('returns null for whitespace-only text', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'text': '   ',
      });

      expect(result, isNull);
    });

    test('extracts text from nested value map', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'text': <String, dynamic>{'value': 'Deep value'},
      });

      expect(result, 'Deep value');
    });

    test('extracts text from list value', () {
      final result = extractTextFromCommonEvent(<String, dynamic>{
        'text': <String>['First', 'Second'],
      });

      expect(result, 'First\nSecond');
    });
  });
}
