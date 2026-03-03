import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tgbot/src/models/telegram_models.dart';

/// Common bridge instructions injected into all provider prompts.
const String bridgeInstruction = 'SYSTEM FOR TELEGRAM BRIDGE:\n'
    '- If the user asks to send/provide a local file or image through Telegram, you MUST output exactly one line in this format:\n'
    '  TG_ARTIFACT: {"kind":"image|file","path":"<relative_or_absolute_path>","caption":"<optional_caption>"}\n'
    '- Use kind=image for image files and kind=file for non-image files.\n'
    '- JSON must be valid; for Windows paths, use forward slashes or escape backslashes.\n'
    '- The path must point to an existing local file, preferably relative to the current project.\n'
    '- Keep all normal user-facing text separate from the TG_ARTIFACT line.\n'
    '- Do not use Markdown links for artifact delivery when this line is present.\n';

/// Builds optional memory-management instructions for first-turn prompts.
String buildMemoryInstruction(String memoryFilename) {
  return 'First, please read the `$memoryFilename` file.\n'
      'If needed, update the `$memoryFilename` file.\n'
      'Also, make sure the `$memoryFilename` file does not exceed 200 lines in length.';
}

/// Builds the final prompt sent to the provider CLI.
String buildPrompt({
  required String userPrompt,
  required String? additionalSystemPrompt,
  required bool includeAdditionalSystemPrompt,
  required bool includeMemoryInstruction,
  String memoryFilename = 'MEMORY.md',
}) {
  final sections = <String>[
    bridgeInstruction.trimRight(),
  ];
  final extra = additionalSystemPrompt;
  if (includeAdditionalSystemPrompt && extra != null && extra.isNotEmpty) {
    sections.add(
      'ADDITIONAL SYSTEM INSTRUCTIONS FOR THIS BOT:\n'
      '$extra',
    );
  }
  if (includeMemoryInstruction) {
    sections.add(
      'MEMORY INSTRUCTIONS:\n${buildMemoryInstruction(memoryFilename)}',
    );
  }
  sections.add('USER REQUEST:\n$userPrompt');
  return sections.join('\n\n');
}

/// Normalizes prompt arguments for Windows shell-backed invocations.
String normalizePromptForProcessArg(
  String prompt, {
  bool? forceWindows,
}) {
  final shouldNormalize = forceWindows ?? Platform.isWindows;
  if (!shouldNormalize) {
    return prompt;
  }
  // For Windows process args, escape double quotes and normalize newlines.
  // Replace newlines with literal \n (double escaping for cmd.exe safe).
  return prompt
      .replaceAll(r'"', "'") // Escape double quotes
      .replaceAll('\r\n', '\n') // Normalize CRLF to LF
      .replaceAll('\n', r'\n'); // Replace each newline with \n for process arg
}

/// Starts a process, including Windows executable fallbacks.
Future<Process> startProcess({
  required String command,
  required List<String> processArgs,
  required String workingDirectory,
}) async {
  final process = await Process.start(
    command,
    processArgs,
    workingDirectory: workingDirectory,
    runInShell: Platform.isWindows,
  );
  process.stdin.close();
  return process;
}

/// Parsed assistant output after cleanup and artifact extraction.
class ParsedAssistantOutput {
  /// Creates parsed assistant output with text, message list, and artifacts.
  ParsedAssistantOutput({
    required this.text,
    required this.messages,
    required this.artifacts,
  });

  /// Final assistant text fallback.
  final String text;

  /// Cleaned assistant messages in delivery order.
  final List<String> messages;

  /// Artifacts extracted from message payloads.
  final List<ArtifactResponse> artifacts;
}

/// Parses artifact markers and markdown links from assistant messages.
ParsedAssistantOutput parseAssistantMessages(List<String> sourceMessages) {
  final cleanedMessages = <String>[];
  final artifacts = <ArtifactResponse>[];
  for (final message in sourceMessages) {
    final directArtifact = _extractArtifact(message);
    final markerArtifact =
        directArtifact == null ? _extractArtifactMarker(message) : null;
    var cleanedMessage = _stripArtifactJsonLines(_stripArtifactMarker(message));
    _MarkdownArtifactParse? markdownArtifact;
    if (directArtifact == null && markerArtifact == null) {
      markdownArtifact = _extractArtifactFromMarkdown(cleanedMessage);
    }
    final found =
        directArtifact ?? markerArtifact ?? markdownArtifact?.artifact;
    if (found != null) {
      artifacts.add(found);
    }
    cleanedMessage = markdownArtifact?.text ?? cleanedMessage;
    final plain = _cleanupText(cleanedMessage);
    if (plain.isNotEmpty) {
      cleanedMessages.add(plain);
    }
  }

  final text = cleanedMessages.isEmpty ? '' : cleanedMessages.last;
  final plain = text.trim().isEmpty ? 'Done.' : text.trim();
  return ParsedAssistantOutput(
    text: plain,
    messages: cleanedMessages,
    artifacts: artifacts,
  );
}

/// Extracts assistant messages by parsing newline-delimited JSON events.
List<String> extractAssistantMessagesFromJsonLines(
  String output,
  String? Function(Map<String, dynamic> event) extractor,
) {
  final messages = <String>[];
  for (final line in LineSplitter.split(output)) {
    final candidate = line.trim();
    if (!candidate.startsWith('{') || !candidate.endsWith('}')) {
      continue;
    }
    try {
      final parsed = jsonDecode(candidate) as Map<String, dynamic>;
      final text = extractor(parsed);
      if (text == null || text.trim().isEmpty) {
        continue;
      }
      final normalized = text.trim();
      if (messages.isEmpty || messages.last != normalized) {
        messages.add(normalized);
      }
    } catch (_) {
      // Skip malformed JSON lines.
      continue;
    }
  }

  if (messages.isNotEmpty) {
    return messages;
  }

  final fallback = output.trim();
  if (fallback.isEmpty) {
    return const <String>[];
  }
  return <String>[fallback];
}

/// Reads the first non-empty id from JSON lines.
String? extractIdFromJsonLines(
  String output,
  List<String> keys,
) {
  for (final line in LineSplitter.split(output)) {
    final candidate = line.trim();
    if (!candidate.startsWith('{') || !candidate.endsWith('}')) {
      continue;
    }
    try {
      final parsed = jsonDecode(candidate) as Map<String, dynamic>;
      for (final key in keys) {
        final id = _extractStringValue(parsed, key);
        if (id != null && id.isNotEmpty) {
          return id;
        }
      }
    } catch (_) {
      // Skip malformed JSON lines.
      continue;
    }
  }
  return null;
}

/// Returns a text payload from common event fields.
String? extractTextFromCommonEvent(Map<String, dynamic> event) {
  final role = event['role']?.toString();
  if (role != null && role != 'assistant') {
    return null;
  }

  final directText = _extractAnyText(event['text']);
  if (directText != null && directText.isNotEmpty) {
    return directText;
  }

  final messageText = _extractAnyText(event['message']);
  if (messageText != null && messageText.isNotEmpty) {
    return messageText;
  }

  final partText = _extractAnyText(event['part']);
  if (partText != null && partText.isNotEmpty) {
    return partText;
  }

  final partsText = _extractAnyText(event['parts']);
  if (partsText != null && partsText.isNotEmpty) {
    return partsText;
  }

  final dataText = _extractAnyText(event['data']);
  if (dataText != null && dataText.isNotEmpty) {
    return dataText;
  }

  final content = event['content'];
  if (content is List) {
    final parts = <String>[];
    for (final entry in content) {
      if (entry is! Map) {
        continue;
      }
      final mapEntry = Map<String, dynamic>.from(entry);
      final contentRole = mapEntry['role']?.toString();
      if (contentRole != null && contentRole != 'assistant') {
        continue;
      }
      final contentType = mapEntry['type']?.toString();
      if (contentType != null &&
          contentType != 'text' &&
          contentType != 'output_text' &&
          contentType != 'message_delta' &&
          contentType != 'output') {
        continue;
      }
      final text = _extractAnyText(mapEntry['text']) ??
          _extractAnyText(mapEntry['message']) ??
          _extractAnyText(mapEntry['delta']) ??
          _extractAnyText(mapEntry['content']);
      if (text != null && text.isNotEmpty) {
        parts.add(text);
      }
    }
    if (parts.isNotEmpty) {
      return parts.join('\n');
    }
  }

  final deltaText = _extractAnyText(event['delta']);
  if (deltaText != null && deltaText.isNotEmpty) {
    return deltaText;
  }

  return null;
}

/// Recursively extracts text from strings/maps/lists in common output shapes.
String? _extractAnyText(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    for (final key in const <String>['text', 'value', 'content', 'message']) {
      final nested = _extractAnyText(map[key]);
      if (nested != null && nested.isNotEmpty) {
        return nested;
      }
    }
    return null;
  }
  if (value is List) {
    final parts = value
        .map(_extractAnyText)
        .whereType<String>()
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return null;
    }
    return parts.join('\n');
  }
  return null;
}

/// Recursively finds the first non-empty string value for [key] in [map].
String? _extractStringValue(Map<String, dynamic> map, String key) {
  if (map.containsKey(key)) {
    final value = map[key]?.toString();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  for (final value in map.values) {
    if (value is Map) {
      final found = _extractStringValue(Map<String, dynamic>.from(value), key);
      if (found != null && found.isNotEmpty) {
        return found;
      }
    }
  }
  return null;
}

/// Matches local image markdown links in assistant output.
final RegExp _artifactImageMarkdown = RegExp(
  r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)',
);

/// Matches local file markdown links in assistant output.
final RegExp _artifactLinkMarkdown = RegExp(
  r'\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)',
);

/// Matches `TG_ARTIFACT:` marker lines emitted by the model.
final RegExp _artifactMarkerLine = RegExp(
  r'^TG_ARTIFACT:\s*(\{.*\})\s*$',
  multiLine: true,
);

/// File extensions treated as image artifacts when parsing markdown links.
const Set<String> _imageExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
  '.tiff',
  '.svg',
  '.heic',
  '.heif',
};

/// Extracts the first JSON artifact payload from [output], if present.
ArtifactResponse? _extractArtifact(String output) {
  for (final line in LineSplitter.split(output)) {
    final candidate = line.trim();
    if (!candidate.startsWith('{') || !candidate.endsWith('}')) {
      continue;
    }
    final artifact =
        _parseArtifactPayload(candidate, requireTypeArtifact: true);
    if (artifact != null) {
      return artifact;
    }
    try {
      jsonDecode(candidate);
    } catch (_) {
      // Not valid JSON; skip.
      continue;
    }
  }
  return null;
}

/// Removes inline JSON lines whose payload type is `artifact`.
String _stripArtifactJsonLines(String output) {
  final kept = <String>[];
  for (final line in LineSplitter.split(output)) {
    final candidate = line.trim();
    if (!candidate.startsWith('{') || !candidate.endsWith('}')) {
      kept.add(line);
      continue;
    }
    try {
      final parsed = jsonDecode(candidate) as Map<String, dynamic>;
      if (parsed['type'] == 'artifact') {
        continue;
      }
    } catch (_) {
      // Not valid JSON; keep the line.
    }
    kept.add(line);
  }
  return kept.join('\n');
}

/// Extracts the first `TG_ARTIFACT` marker payload from [output].
ArtifactResponse? _extractArtifactMarker(String output) {
  for (final match in _artifactMarkerLine.allMatches(output)) {
    final payload = match.group(1);
    if (payload == null || payload.trim().isEmpty) {
      continue;
    }
    final artifact = _parseArtifactPayload(payload);
    if (artifact != null) {
      return artifact;
    }
  }
  return null;
}

/// Parses artifact JSON payload into an [ArtifactResponse].
ArtifactResponse? _parseArtifactPayload(
  String payload, {
  bool requireTypeArtifact = false,
}) {
  try {
    final parsed = jsonDecode(payload) as Map<String, dynamic>;
    if (requireTypeArtifact && parsed['type']?.toString() != 'artifact') {
      return null;
    }
    final kind = (parsed['kind'] ?? '').toString();
    final path = (parsed['path'] ?? '').toString();
    if ((kind != 'image' && kind != 'file') || path.isEmpty) {
      return null;
    }
    return ArtifactResponse(
      kind: kind,
      path: path,
      caption: parsed['caption']?.toString(),
    );
  } catch (_) {
    // Strict JSON parse failed; try loose regex-based extraction.
    final type = _extractLooseStringField(payload, 'type');
    if (requireTypeArtifact && type != 'artifact') {
      return null;
    }
    final kind = _extractLooseStringField(payload, 'kind');
    final path = _extractLooseStringField(payload, 'path');
    if ((kind != 'image' && kind != 'file') || path == null || path.isEmpty) {
      return null;
    }
    return ArtifactResponse(
      kind: kind!,
      path: path,
      caption: _extractLooseStringField(payload, 'caption'),
    );
  }
}

/// Extracts a quoted string field from loosely formatted JSON text.
String? _extractLooseStringField(String payload, String field) {
  final pattern = RegExp('"$field"\\s*:\\s*"((?:\\\\.|[^"])*)"');
  final match = pattern.firstMatch(payload);
  if (match == null) {
    return null;
  }
  return _decodeLooseJsonString(match.group(1)!);
}

/// Decodes basic escaped characters from an extracted JSON string literal.
String _decodeLooseJsonString(String raw) {
  final out = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final char = raw[i];
    if (char != r'\' || i + 1 >= raw.length) {
      out.write(char);
      continue;
    }
    final next = raw[i + 1];
    if (next == r'\' || next == '"') {
      out.write(next);
      i++;
      continue;
    }
    if (next == '/') {
      out.write('/');
      i++;
      continue;
    }
    out.write(r'\');
    out.write(next);
    i++;
  }
  return out.toString();
}

/// Removes all `TG_ARTIFACT` marker lines from [output].
String _stripArtifactMarker(String output) {
  return output.replaceAll(_artifactMarkerLine, '');
}

/// Parses the first local markdown artifact link from [text], if any.
_MarkdownArtifactParse? _extractArtifactFromMarkdown(String text) {
  final imageMatch = _artifactImageMarkdown.firstMatch(text);
  if (imageMatch != null) {
    final target = _normalizeLinkTarget(imageMatch.group(2) ?? '');
    final path = _tryLocalPath(target);
    if (path != null) {
      final caption = _cleanupText(imageMatch.group(1) ?? '');
      return _MarkdownArtifactParse(
        artifact: ArtifactResponse(
          kind: 'image',
          path: path,
          caption: caption.isEmpty ? null : caption,
        ),
        text: _removeMatch(text, imageMatch).trim(),
      );
    }
  }

  for (final linkMatch in _artifactLinkMarkdown.allMatches(text)) {
    final target = _normalizeLinkTarget(linkMatch.group(2) ?? '');
    final path = _tryLocalPath(target);
    if (path == null) {
      continue;
    }
    final extension = p.extension(path).toLowerCase();
    final kind = _imageExtensions.contains(extension) ? 'image' : 'file';
    final caption = _cleanupText(linkMatch.group(1) ?? '');
    return _MarkdownArtifactParse(
      artifact: ArtifactResponse(
        kind: kind,
        path: path,
        caption: caption.isEmpty ? null : caption,
      ),
      text: _removeMatch(text, linkMatch).trim(),
    );
  }

  return null;
}

/// Normalizes markdown link targets by stripping wrappers and `file://`.
String _normalizeLinkTarget(String raw) {
  var target = raw.trim();
  if (target.startsWith('<') && target.endsWith('>') && target.length >= 2) {
    target = target.substring(1, target.length - 1).trim();
  }
  if (target.startsWith('file://')) {
    target = target.substring('file://'.length);
  }
  return target;
}

/// Returns a candidate local path or `null` for URL/anchor targets.
String? _tryLocalPath(String target) {
  if (target.isEmpty) {
    return null;
  }
  final lowered = target.toLowerCase();
  if (lowered.startsWith('http://') ||
      lowered.startsWith('https://') ||
      lowered.startsWith('mailto:') ||
      lowered.startsWith('tel:') ||
      lowered.startsWith('#')) {
    return null;
  }
  return target;
}

/// Removes a single regex [match] range from [text].
String _removeMatch(String text, Match match) {
  return text.replaceRange(match.start, match.end, '');
}

/// Trims trailing line whitespace and outer blank lines.
String _cleanupText(String value) {
  final lines =
      value.split('\n').map((line) => line.trimRight()).toList(growable: false);
  final cleaned = lines.join('\n').trim();
  return cleaned;
}

/// Parsed markdown artifact and remaining text after link removal.
class _MarkdownArtifactParse {
  /// Creates a markdown artifact parse result.
  _MarkdownArtifactParse({required this.artifact, required this.text});

  /// Artifact discovered in markdown.
  final ArtifactResponse artifact;

  /// Remaining message text after stripping the artifact link.
  final String text;
}
