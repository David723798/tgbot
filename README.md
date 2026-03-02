# tgbot

`tgbot` is a Dart CLI that connects a Telegram bot to AI CLIs (`codex`, `opencode`, `gemini`, `claude`). It long-polls Telegram, forwards authorized messages into the configured provider CLI, keeps a per-chat thread ID in memory, and sends streamed text plus local file/image artifacts back to Telegram.

## Install

```bash
dart pub global activate tgbot
```

If Dart's global bin directory is not already on your `PATH`, add it first so `tgbot` is runnable from the shell.

## Requirements

- Dart SDK
- One supported provider CLI installed and available on `PATH` (`codex`, `opencode`, `gemini`, or `claude`), unless overridden with `ai_cli_cmd`
- A Telegram bot token from `@BotFather`
- Your Telegram numeric user ID

Provider CLI references:

- [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
- [OpenCode CLI](https://opencode.ai/docs/cli/)
- [Gemini CLI](https://google-gemini.github.io/gemini-cli/docs/cli/configuration/)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/cli-reference)

## Quick Start

Create a starter config:

```bash
tgbot init
```

You can also start from the checked-in example: [`tgbot.yaml.example`](tgbot.yaml.example).

Edit `tgbot.yaml`:

```yaml
bots:
  - name: my-bot
    telegram_bot_token: "YOUR_TELEGRAM_BOT_TOKEN"
    allowed_user_ids:
      - 123456789
    project_path: /absolute/path/to/project
```

Validate it:

```bash
tgbot validate
```

Start the bridge:

```bash
tgbot start
```

Then open your bot in Telegram and send it a message.

## CLI

```text
tgbot <command> [options]
```

| Command | Description |
|---|---|
| `start` | Start all bots declared in the config file |
| `init` | Generate a starter `tgbot.yaml` |
| `validate` | Parse and validate a config file without starting bots |
| `upgrade` | Reinstall the latest published `tgbot` with Dart |

Global flags:

| Flag | Description |
|---|---|
| `-h`, `--help` | Print usage help |
| `-v`, `--version` | Print the version |

Examples:

```bash
tgbot start
tgbot start -c custom.yaml

tgbot init
tgbot init -o other.yaml

tgbot validate
tgbot validate -c custom.yaml

tgbot upgrade
```

## Telegram Setup

### Bot token

1. Open Telegram and find `@BotFather`.
2. Run `/newbot`.
3. Follow the prompts.
4. Copy the token into `telegram_bot_token`.

### User ID

1. Open Telegram and find `@userinfobot`.
2. Send it any message.
3. Copy the numeric ID into `allowed_user_ids`.

Only that user can interact with the configured bot.

## Configuration

`tgbot` loads one YAML file, defaulting to `tgbot.yaml`.

Top-level keys:

- `bots` (required): non-empty list of bot definitions
- `defaults` (optional): shared values inherited by each bot

### Minimal config

```yaml
bots:
  - name: my-bot
    telegram_bot_token: "YOUR_TELEGRAM_BOT_TOKEN"
    allowed_user_ids:
      - 123456789
    project_path: /absolute/path/to/project
```

### Config with shared defaults

```yaml
defaults:
  project_path: /absolute/path/to/default/project
  provider: codex
  ai_cli_cmd: codex
  ai_cli_args:
    - --model
    - gpt-5
  poll_timeout_sec: 60
  ai_cli_timeout_sec: 1000

bots:
  - name: repo-a
    telegram_bot_token: "TOKEN_A"
    allowed_user_ids:
      - 123456789

  - name: repo-b
    telegram_bot_token: "TOKEN_B"
    allowed_user_ids:
      - 123456789
    project_path: /absolute/path/to/repo-b
    additional_system_prompt: |
      Keep answers brief and focus on production issues.
```

### Bot fields

| Key | Required | Notes |
|---|---|---|
| `name` | Yes | Used in logs and status messages |
| `telegram_bot_token` | Yes | Telegram Bot API token |
| `allowed_user_ids` | Yes | Telegram user IDs allowed to use the bot |
| `project_path` | Yes | Absolute working directory used for the selected provider CLI; may be inherited from `defaults` |
| `provider` | No | Provider name: `codex`, `opencode`, `gemini`, or `claude`; default `codex` |
| `ai_cli_cmd` | No | Executable to run for the selected provider, defaults by provider (`codex`, `opencode`, `gemini`, `claude`) |
| `ai_cli_args` | No | Extra args passed to the provider CLI; accepts a YAML list or whitespace-delimited string |
| `poll_timeout_sec` | No | Telegram long-poll timeout in seconds, default `60` |
| `ai_cli_timeout_sec` | No | Per-request provider timeout in seconds, default `1000` |
| `additional_system_prompt` | No | Extra system instructions prepended before each user request |
| `final_response_only` | No | When `true`, suppresses streamed partial messages and sends only the final assistant response, default `false` |
| `telegram_commands` | No | Extra Telegram slash commands registered for this bot |
| `log_level` | No | Runtime log level: `debug`, `info`, `warn`, `error`; default `info` |
| `log_format` | No | Runtime log format: `text` or `json`; default `text` |
| `strict_config` | No | When `true`, unknown keys are rejected during config parsing; default `false` |
| `validate_project_path` | No | When `true`, `project_path` must exist and be readable at startup; default `false` |

Notes:

- `defaults` applies only when a bot omits that key.
- Every bot must end up with an effective `project_path`.
- `telegram_commands` must be a non-empty list when provided.
- Command names must match `^[a-z0-9_]{1,32}$`.
- Built-in `/start`, `/new`, `/stop`, and `/restart` commands are always present unless you override them in `telegram_commands`.
- `project_path` is normalized to an absolute path at startup.
- In `strict_config: true`, unknown keys in `root`, `defaults`, `bots[*]`, and `telegram_commands[*]` fail fast.
- `ai_cli_args` string values support shell-like quoting (single quotes, double quotes, and escapes).

## Custom Telegram Commands

You can register Telegram slash commands that map to prompt templates:

```yaml
bots:
  - name: my-bot
    telegram_bot_token: "YOUR_TELEGRAM_BOT_TOKEN"
    allowed_user_ids:
      - 123456789
    project_path: /absolute/path/to/project
    telegram_commands:
      - command: review
        description: Review the current branch and list bugs first.
      - command: fix
        description: Fix this issue: {args}
```

Behavior:

- Telegram shows these commands via `setMyCommands`.
- If `description` contains `{args}`, text after the command replaces that placeholder.
- Otherwise command arguments are appended to the description with a blank line.

Examples:

- `/review` becomes `Review the current branch and list bugs first.`
- `/fix login race` becomes `Fix this issue: login race`

## Runtime Behavior

- One polling loop runs per configured bot.
- Only messages from IDs in `allowed_user_ids` are processed.
- Messages are processed serially per chat so responses stay ordered.
- `/start` returns a short help message plus the registered command list.
- `/new` clears the in-memory thread/session id for that Telegram chat.
- `/stop` terminates the active provider CLI process for that Telegram chat, if one is running.
- `/restart` reloads the same YAML config file used at startup and restarts all bots in this process.
- `/restart` is allowed only if the sender ID is listed in `allowed_user_ids` for every configured bot.
- `/restart` uses rollback semantics: if reload/startup fails, existing bots keep running.
- If a run is already in progress for a chat, new prompts wait in that chat's queue until the active run finishes or is stopped.
- Any other text message is forwarded to the configured provider CLI.
- The current thread/session id is stored per chat and reused until `/new` or process restart.
- `tgbot start` handles `SIGINT`/`SIGTERM` and shuts down polling, active runs, and HTTP clients gracefully.

Provider invocation patterns:

```text
codex ...args exec --skip-git-repo-check --json <prompt>
opencode ...args run --format json <prompt>
gemini ...args --prompt <prompt> --output-format json
claude ...args --verbose --print --output-format stream-json <prompt>
```

Resume behavior:

```text
codex ...args exec resume --skip-git-repo-check --json <thread_id> <prompt>
opencode ...args run --session <thread_id> --format json <prompt>
gemini ...args --resume <thread_id> --prompt <prompt> --output-format json
claude ...args --verbose --print --output-format stream-json --resume <thread_id> <prompt>
```

Notes:
- `gemini`, `opencode`, and `claude` session ids are captured from provider output when available.

## Streaming and Replies

By default, `tgbot` reads provider output incrementally when streaming JSON is available and forwards assistant messages to Telegram as they arrive. It also:

- keeps Telegram's typing indicator active while the provider CLI is running
- avoids re-sending duplicate streamed messages
- chunks long Telegram messages at newline or word boundaries
- falls back to reconstructed assistant messages if only final JSON output is available

If `final_response_only: true` is set for a bot, streamed partial replies are not sent and only the final assistant response is delivered.

## File and Image Delivery

`tgbot` can send local artifacts back through Telegram during the same reply flow.

Preferred mechanism:

```text
TG_ARTIFACT: {"kind":"image","path":"artifacts/plot.png","caption":"Latest chart"}
```

Supported artifact detection:

- `TG_ARTIFACT: {...}` marker lines
- standalone JSON artifact objects in provider output
- local Markdown image/link syntax when no explicit artifact marker is present

Rules:

- image files are uploaded with `sendPhoto`
- non-image files are uploaded with `sendDocument`
- relative paths are resolved from `project_path`
- artifact paths must stay inside `project_path`
- missing files and path traversal are rejected

## Error Handling

- Telegram API calls retry up to 3 times on HTTP `429`
- Telegram `retry_after` values are respected
- empty outgoing messages are skipped
- Provider CLI failures and timeouts are reported back to the Telegram chat
- bot tokens are never logged

## Project Layout

- `bin/tgbot.dart`: CLI entry point and subcommands
- `lib/tgbot.dart`: public package exports
- `lib/src/app.dart`: bridge runtime and message routing
- `lib/src/config.dart`: YAML parsing and validation
- `lib/src/runner/base_runner.dart`: shared runner orchestration (process lifecycle, streaming, cancellation)
- `lib/src/runner/ai_cli_runner.dart`: provider runner interface and result types
- `lib/src/runner/runner_factory.dart`: factory that builds provider-specific runners from config
- `lib/src/runner/codex_runner.dart`: Codex provider
- `lib/src/runner/claude_runner.dart`: Claude provider
- `lib/src/runner/gemini_runner.dart`: Gemini provider
- `lib/src/runner/opencode_runner.dart`: OpenCode provider
- `lib/src/runner/runner_support.dart`: prompt building, artifact parsing, and shared extraction utilities
- `lib/src/telegram/telegram_client.dart`: Telegram Bot API client
- `lib/src/session/session_store.dart`: in-memory per-chat thread state
- `lib/src/models/telegram_models.dart`: Telegram API models
- `example/main.dart`: package example
- `test/`: unit tests
- `.github/workflows/ci.yml`: CI pipeline

## Development

Run the standard Dart checks locally:

```bash
dart analyze
dart test
```

A GitHub Actions CI pipeline runs `dart analyze --fatal-infos` and `dart test` on every push and pull request to `main`.

## License

MIT. See [LICENSE](LICENSE).
