void main() {
  print('''
tgbot <command> [options]

Commands:
  start      Start the Telegram-AI CLI bridge
  init       Generate a starter tgbot.yaml config file
  validate   Validate a config file without starting
  upgrade    Upgrade tgbot to the latest version

Flags:
  -h, --help       Print usage help
  -v, --version    Print the version
''');
}
