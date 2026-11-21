/// Источник строки в живом терминале.
enum TerminalLineKind {
  /// Отправленная на сервер команда (выводится с префиксом `$`).
  command,

  /// Обычный вывод команды.
  stdout,

  /// Поток ошибок команды.
  stderr,

  /// Служебное сообщение самого приложения (подключение, код возврата).
  info,
}

/// Одна строка живого терминала: что отправили и что ответил сервер.
class TerminalLine {
  final String text;
  final TerminalLineKind kind;
  final DateTime timestamp;

  TerminalLine({required this.text, required this.kind, DateTime? timestamp})
    : timestamp = timestamp ?? DateTime.now();

  /// Строка в виде, пригодном для копирования в буфер обмена.
  /// Команды помечаются `$`, stderr — `!`, чтобы при вставке
  /// в тикет было видно, где была ошибка.
  String toPlainText() {
    switch (kind) {
      case TerminalLineKind.command:
        return '\$ $text';
      case TerminalLineKind.stderr:
        return '! $text';
      case TerminalLineKind.info:
        return '# $text';
      case TerminalLineKind.stdout:
        return text;
    }
  }
}
