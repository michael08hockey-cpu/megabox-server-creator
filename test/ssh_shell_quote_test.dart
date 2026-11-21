import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';

/// Пароль подставляется в команду `sudo -S`, поэтому любые кавычки
/// в нём должны быть экранированы — иначе команда разваливается
/// и sudo получает мусор вместо пароля.
void main() {
  test('обычный пароль просто оборачивается в кавычки', () {
    expect(SSHService.shellQuote('secret123'), "'secret123'");
  });

  test('одинарная кавычка экранируется по схеме \'\\\'\'', () {
    // O'Brien -> 'O'\''Brien'
    expect(SSHService.shellQuote("O'Brien"), "'O'\\''Brien'");
  });

  test('несколько кавычек экранируются все', () {
    expect(SSHService.shellQuote("a'b'c"), "'a'\\''b'\\''c'");
  });

  test('спецсимволы shell остаются внутри кавычек без изменений', () {
    // Внутри одинарных кавычек bash не раскрывает $, ` и ;,
    // поэтому их экранировать не нужно.
    for (final raw in <String>[
      r'p$ass',
      'p`ass`',
      'pass;rm -rf /',
      'pa ss',
      r'pass\n',
      'pass&&whoami',
      r'pass|tee /tmp/x',
    ]) {
      expect(SSHService.shellQuote(raw), "'$raw'");
    }
  });

  test('пустой пароль даёт пустую строку в кавычках', () {
    // Нужно для sudo без пароля (NOPASSWD): аргумент должен остаться,
    // иначе printf склеится с пайпом.
    expect(SSHService.shellQuote(''), "''");
  });

  test('bash разбирает результат обратно в исходный пароль', () {
    // Честная проверка вместо подсчёта кавычек: повторяем правила
    // разбора bash (одинарные кавычки + escape вне кавычек)
    // и убеждаемся, что до sudo доходит ровно исходный пароль.
    String bashUnquote(String input) {
      final out = StringBuffer();
      var inSingle = false;
      var i = 0;
      while (i < input.length) {
        final ch = input[i];
        if (inSingle) {
          if (ch == "'") {
            inSingle = false;
          } else {
            out.write(ch);
          }
          i++;
        } else if (ch == "'") {
          inSingle = true;
          i++;
        } else if (ch == r'\' && i + 1 < input.length) {
          out.write(input[i + 1]);
          i += 2;
        } else {
          out.write(ch);
          i++;
        }
      }
      expect(inSingle, isFalse, reason: 'незакрытая кавычка в "$input"');
      return out.toString();
    }

    for (final raw in <String>[
      'plain',
      '',
      "O'Brien",
      "a'b'c",
      "''",
      r'p$ass',
      'pass;rm -rf /',
      'pa ss',
      'pass&&whoami',
    ]) {
      expect(
        bashUnquote(SSHService.shellQuote(raw)),
        raw,
        reason: 'пароль "$raw" должен дойти без искажений',
      );
    }
  });
}
