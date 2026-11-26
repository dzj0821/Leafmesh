import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:leafmesh/core/api.dart';

Future<void> main(List<String> args) async {
  final fixture = jsonDecode(await File(args.single).readAsString()) as Map;
  final api = CoreApi(fixture['port'] as int, fixture['key'] as String);
  var count = 0;
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    count++;
    stdout.writeln('PASS $name');
  }
  try {
    final status = await api.get('system/status');
    check(status['myID'] == fixture['localID'], 'authenticated local API returns the correct device');
    final remote = fixture['remoteID'] as String;
    await api.pair(remote, 'Test peer');
    final devices = await api.list('config/devices');
    final device = devices.firstWhere((item) => item['deviceID'] == remote) as Map;
    check(device['introducer'] == false && device['autoAcceptFolders'] == false,
      'pairing does not grant introducer or automatic folder acceptance');
    var duplicate = false;
    try { await api.pair(remote, 'Again'); } on StateError { duplicate = true; }
    check(duplicate, 'duplicate pairing is rejected');
    final invalid = remote.substring(0, remote.length - 1) + (remote.endsWith('A') ? 'B' : 'A');
    var badChecksum = false;
    try { await api.pair(invalid, 'Invalid checksum'); } on CoreApiException { badChecksum = true; }
    check(badChecksum, 'the real core validates Device ID check digits');
    final after = await api.list('config/devices');
    check(!after.any((item) => item['deviceID'] == invalid), 'invalid identity was not added');
    final unauthorized = CoreApi(fixture['port'] as int, 'incorrect-test-key');
    var denied = false;
    try { await unauthorized.get('system/status'); } on CoreApiException catch (error) { denied = error.status == 401 || error.status == 403; }
    unauthorized.close();
    check(denied, 'local management API rejects an incorrect key');
    final subscription = api.events().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final cancellation = Stopwatch()..start();
    await subscription.cancel().timeout(const Duration(seconds: 2));
    check(cancellation.elapsed < const Duration(seconds: 2), 'event long-poll cancellation does not block shutdown');
    check((await api.get('system/ping'))['ping'] == 'pong', 'cancelling event polling leaves management requests usable');
    final done = Completer<void>();
    api.events().listen((_) {}, onDone: () => done.complete());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    api.close();
    await done.future.timeout(const Duration(seconds: 3));
    check(done.isCompleted, 'closing the API stops active event polling');
    var closed = false;
    try { await api.get('system/status'); } on StateError { closed = true; }
    check(closed, 'closed clients do not continue making requests');
    stdout.writeln('API checks: $count passed.');
  } finally { api.close(); }
}
