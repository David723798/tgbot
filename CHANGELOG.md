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
