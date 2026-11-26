import 'dart:io';
void main() {
  for (final command in ['git', r'D:\Program Files\Git\cmd\git.exe']) {
    try {
      final result = Process.runSync(command, ['--version']);
      stdout.writeln('$command: ${result.exitCode} ${result.stdout} ${result.stderr}');
    } catch (error) { stdout.writeln('$command: $error'); }
  }
}
