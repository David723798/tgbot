import 'dart:convert';

/// Formatted Telegram text with both HTML and plain variants.
class TelegramFormattedText {
  /// Creates a formatted text pair.
  const TelegramFormattedText({required this.plain, required this.html});

  /// Original plain text value.
  final String plain;

  /// HTML-rendered text for Telegram's `parse_mode: HTML`.
  final String html;
}

/// Converts markdown-like text into Telegram-safe HTML.
class TelegramTextFormatter {
  /// Formats [text] to HTML while keeping [text] as the fallback plain variant.
  TelegramFormattedText format(String text) {
    if (text.isEmpty) {
      return const TelegramFormattedText(plain: '', html: '');
    }
    final html = _formatBlocks(text);
    return TelegramFormattedText(plain: text, html: html);
  }

  String _formatBlocks(String text) {
    final fence = RegExp(
      r'```[^\n`]*\n?([\s\S]*?)```',
      multiLine: true,
      dotAll: true,
    );
    final out = StringBuffer();
    var cursor = 0;
    for (final match in fence.allMatches(text)) {
      if (match.start > cursor) {
        out.write(_formatInline(text.substring(cursor, match.start)));
      }
      final code = match.group(1) ?? '';
      out.write('<pre><code>${_escapeHtml(code)}</code></pre>');
      cursor = match.end;
    }
    if (cursor < text.length) {
      out.write(_formatInline(text.substring(cursor)));
    }
    return out.toString();
  }

  String _formatInline(String text) {
    if (text.isEmpty) {
      return text;
    }
    final tokens = <String>[];
    var working = text;

    working = _replaceWithTokens(
      working,
      RegExp(r'\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)'),
      (match) =>
          '<a href="${_escapeHtmlAttribute(match.group(2)!)}">${_escapeHtml(match.group(1)!)}</a>',
      tokens,
    );
    working = _replaceWithTokens(
      working,
      RegExp(r'`([^`\n]+)`'),
      (match) => '<code>${_escapeHtml(match.group(1)!)}</code>',
      tokens,
    );
    working = _replaceWithTokens(
      working,
      RegExp(r'\*\*([^*\n][^*\n]*?)\*\*'),
      (match) => '<b>${_escapeHtml(match.group(1)!)}</b>',
      tokens,
    );
    working = _replaceWithTokens(
      working,
      RegExp(r'~~([^~\n][^~\n]*?)~~'),
      (match) => '<s>${_escapeHtml(match.group(1)!)}</s>',
      tokens,
    );
    working = _replaceWithTokens(
      working,
      RegExp(r'(?<!\*)\*([^*\n][^*\n]*?)\*(?!\*)'),
      (match) => '<i>${_escapeHtml(match.group(1)!)}</i>',
      tokens,
    );
    working = _replaceWithTokens(
      working,
      RegExp(r'(?<!\w)_([^_\n]+?)_(?!\w)'),
      (match) => '<i>${_escapeHtml(match.group(1)!)}</i>',
      tokens,
    );

    final escaped = _escapeHtml(working);
    return _restoreTokens(escaped, tokens);
  }

  String _replaceWithTokens(
    String input,
    RegExp pattern,
    String Function(RegExpMatch match) render,
    List<String> tokens,
  ) {
    return input.replaceAllMapped(pattern, (match) {
      final idx = tokens.length;
      tokens.add(render(match as RegExpMatch));
      return _token(idx);
    });
  }

  String _restoreTokens(String input, List<String> tokens) {
    var output = input;
    for (var i = 0; i < tokens.length; i++) {
      output = output.replaceAll(_token(i), tokens[i]);
    }
    return output;
  }

  String _token(int idx) => '@@TGHTML$idx@@';

  String _escapeHtml(String value) {
    if (value.isEmpty) {
      return value;
    }
    return const HtmlEscape(HtmlEscapeMode.element).convert(value);
  }

  String _escapeHtmlAttribute(String value) {
    if (value.isEmpty) {
      return value;
    }
    return const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
  }
}
