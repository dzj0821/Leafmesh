/// Installed by the Flutter entrypoint. Keeping filesystem logic independent of
/// Flutter also lets recovery and path-safety tests run in a plain Dart VM.
class NativeBridge {
  const NativeBridge();
  static Future<dynamic> Function(String method, Map<String, dynamic>? values)?
  handler;
  Future<T?> invokeMethod<T>(
    String method, [
    Map<String, dynamic>? values,
  ]) async {
    final invoke = handler;
    if (invoke == null) throw UnsupportedError('此平台尚未初始化原生存储');
    return await invoke(method, values) as T?;
  }
}
