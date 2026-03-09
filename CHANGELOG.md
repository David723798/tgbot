## 0.2.5

- Add `topics` config support so bots can create Telegram forum topics by name and persist the returned `message_thread_id` locally.
- Allow topic-level overrides for `telegram_commands`, `additional_system_prompt`, `memory`, `memory_filename`, and `final_response_only`.
- Change the default `final_response_only` behavior to `true`.
- Allow omitting bot-level `project_path` when `topics` are configured; unmatched chats/topics now return a configuration error instead of guessing a workspace.
- Track queued runs and session/thread IDs per chat topic instead of only per chat.
- Reply back into the originating Telegram topic by preserving `message_thread_id` for text, typing, and artifact uploads.

## 0.2.4

- Add `allowed_chat_ids` config support so bots can authorize and respond in Telegram groups/supergroups by chat ID.
- Allow message processing when either sender is in `allowed_user_ids` or chat is in `allowed_chat_ids`.
- Update config templates/README with group chat ID setup guidance.

## 0.2.3

- Fix Windows prompt argument normalization.

## 0.2.2

- Fix Windows prompt argument normalization by escaping double quotes in addition to CRLF/newline normalization.

## 0.2.1

- Fix Windows startup crash by skipping unsupported `SIGTERM` signal registration on Windows while keeping `SIGINT` (`Ctrl+C`) graceful shutdown behavior.

## 0.2.0

- Add Cursor provider support (`provider: cursor`) with default command `cursor-agent`.
- Add `CursorRunner` and wire it through config parsing, runner factory, and provider labeling.
- Fix Cursor invocation to use `--print --output-format stream-json` (instead of unsupported `--json`).
- Fix Cursor output handling to ignore `user` events so wrapped system prompts are not echoed to Telegram.
- Add automatic Cursor workspace trust for non-interactive runs by injecting `--trust` unless `--trust`, `--yolo`, or `-f` is already set.
- Update docs/templates for Cursor provider and invocation patterns.
- Add/extend tests for Cursor config defaults, runner wiring, argument building, and prompt-leak regression coverage.

## 0.1.9

- Initial release.
