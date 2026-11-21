import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'shell_scripts.dart';

class RemoteExecutor {
  static Future<String> run(
    SSHClient client,
    String script, {
    String? sudoPassword,
  }) async {
    final session = await client.execute(
      ShellScripts.transport(script, sudoPassword: sudoPassword),
    );
    final outputs = await Future.wait([
      session.stdout.toList(),
      session.stderr.toList(),
    ]);
    await session.done;
    final code = session.exitCode;
    session.close();
    if (code != 0) throw StateError('Remote command failed (exit $code)');
    return utf8.decode(
      outputs.expand((chunks) => chunks.expand((chunk) => chunk)).toList(),
      allowMalformed: true,
    );
  }
}
