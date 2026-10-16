// Open Connect: every device runs a file server (Host) and a client (Peer/BrowserPage).
// Protocol is identical to ../server.js, so the Node server and the apps interoperate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart' as crypt;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:open_filex/open_filex.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'explorer.dart';

const port = 8080;
final navKey = GlobalKey<NavigatorState>();
final host = Host();

String rand(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

// Android: only Wi-Fi / hotspot / ethernet, so mobile-data addresses neither show up nor keep the service alive on a new network
Future<List<String>> localIps() async => (await NetworkInterface.list(type: InternetAddressType.IPv4))
    .where((i) => !Platform.isAndroid || RegExp(r'^(wlan|swlan|ap|eth)', caseSensitive: false).hasMatch(i.name))
    .expand((i) => i.addresses)
    .map((a) => a.address)
    .where((a) => !a.startsWith('127.') && !a.startsWith('169.254.'))
    .toList();

Future<void> copyTree(String from, String to) async {
  if (await FileSystemEntity.isDirectory(from)) {
    await Directory(to).create(recursive: true);
    await for (final e in Directory(from).list(followLinks: false)) {
      await copyTree(e.path, p.join(to, p.basename(e.path)));
    }
  } else {
    await File(from).copy(to);
  }
}

// ---------------------------------------------------------------- server
class Host {
  final roots = <String, String>{};
  final sessions = <String>{};
  final pending = <String, String>{}; // id -> wait | denied | token
  Future<bool> Function(String who)? approve;
  void Function(String name, String from)? received; // a device just sent us a file
  Future<void> _queue = Future.value();

  void addRoot(String path) {
    final r = p.normalize(path);
    var n = p.basename(r).isEmpty ? r.replaceAll(RegExp(r'[:\\/]'), '') : p.basename(r);
    while (roots.containsKey(n)) {
      n += '_';
    }
    roots[n] = r;
  }

  // virtual "name/sub" -> real path; null if unknown or escapes the root
  // ponytail: symlinks inside a shared folder can still point outside it
  String? real(String vp) {
    final parts = vp.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty || !roots.containsKey(parts[0])) return null;
    final root = roots[parts[0]]!;
    final f = p.normalize(p.joinAll([root, ...parts.skip(1)]));
    return p.equals(f, root) || p.isWithin(root, f) ? f : null;
  }

  String? startError; // shown in Settings: a busy port means nobody can connect to this device
  Future<void> start() async {
    try {
      await io.serve(_guard, InternetAddress.anyIPv4, port);
    } catch (e) {
      startError = 'Cannot listen on port $port (another Open Connect already running?). Other devices cannot connect.';
    }
  }

  Future<Response> _guard(Request r) async {
    try {
      return await _handle(r);
    } catch (_) {
      return Response(500);
    }
  }

  Response _json(Object o) => Response.ok(jsonEncode(o), headers: {'content-type': 'application/json'});

  Future<Response> _handle(Request r) async {
    final q = r.url.queryParameters, vp = q['p'] ?? '', path = r.url.path;
    if (path == 'ping') return Response.ok('openconnect:$deviceName');
    if (path == 'request' && r.method == 'POST') {
      if (pending.length > 20) return Response(429);
      final id = rand(8);
      final ip = (r.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? '?';
      pending[id] = 'wait';
      _queue = _queue.then((_) async {
        var ok = false;
        try {
          ok = await (approve?.call('$ip (${r.headers['user-agent'] ?? 'app'})') ?? Future.value(false));
        } catch (_) {} // a failed prompt must deny, not wedge the queue
        if (ok) {
          final t = rand(24);
          sessions.add(t);
          pending[id] = t;
        } else {
          pending[id] = 'denied';
        }
      });
      return Response.ok(id);
    }
    if (path == 'status') {
      final s = pending[q['id']];
      if (s == null) return Response.notFound('');
      if (s == 'wait') return Response.ok('wait');
      pending.remove(q['id']);
      if (s == 'denied') return Response.ok('denied');
      return Response.ok('ok', headers: {'set-cookie': 't=$s; Path=/'});
    }
    // signed update files are public: clients verify the Ed25519 signature, not the transport
    if (path == 'update/manifest') {
      final d = updatesDir();
      final m = File(p.join(d, 'manifest.json')), s = File(p.join(d, 'manifest.sig'));
      if (!m.existsSync() || !s.existsSync()) return Response.notFound('');
      return _json({'manifest': await m.readAsString(), 'sig': (await s.readAsString()).trim()});
    }
    if (path.startsWith('update/blob/')) {
      final sha = path.substring(12);
      final f = File(p.join(updatesDir(), 'blobs', sha));
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) || !f.existsSync()) return Response.notFound('');
      return Response.ok(f.openRead(), headers: {'content-length': '${await f.length()}'});
    }
    final tok = RegExp(r't=([0-9a-f]+)').firstMatch(r.headers['cookie'] ?? '')?.group(1);
    if (!sessions.contains(tok)) return Response(401);

    if (path == 'api/ls') {
      if (vp.isEmpty) return _json(roots.keys.map((n) => {'n': n, 'd': true}).toList());
      final f = real(vp);
      if (f == null) return Response.notFound('');
      final out = <Map>[];
      await for (final e in Directory(f).list(followLinks: false)) {
        try {
          final s = await e.stat();
          out.add({'n': p.basename(e.path), 'd': s.type == FileSystemEntityType.directory, 's': s.size, 'm': s.modified.millisecondsSinceEpoch});
        } catch (_) {}
      }
      return _json(out);
    }
    if (path == 'api/file') {
      final f = real(vp);
      if (f == null) return Response.notFound('');
      final file = File(f), size = await file.length();
      final h = {'accept-ranges': 'bytes', 'content-type': 'application/octet-stream'};
      final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(r.headers['range'] ?? '');
      if (m != null) {
        final a = m[1]!.isEmpty ? max(0, size - int.parse(m[2]!)) : int.parse(m[1]!);
        final b = m[1]!.isEmpty || m[2]!.isEmpty ? size - 1 : min(int.parse(m[2]!), size - 1);
        if (a > b || a >= size) return Response(416, headers: {'content-range': 'bytes */$size'});
        return Response(206,
            body: file.openRead(a, b + 1),
            headers: {...h, 'content-range': 'bytes $a-$b/$size', 'content-length': '${b - a + 1}'});
      }
      return Response.ok(file.openRead(), headers: {...h, 'content-length': '$size'});
    }
    if (path == 'api/up' && r.method == 'POST') {
      final d = real(vp), n = p.basename(q['name'] ?? '');
      if (d == null || n.isEmpty) return Response(400);
      final sink = File(p.join(d, n)).openWrite();
      await sink.addStream(r.read());
      await sink.close();
      received?.call(n, (r.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? '?');
      return Response.ok('');
    }
    if (path == 'api/rm' && r.method == 'POST') {
      final f = real(vp);
      if (f == null || roots.containsValue(f)) return Response(400);
      if (await FileSystemEntity.isDirectory(f)) {
        await Directory(f).delete(recursive: true);
      } else {
        await File(f).delete();
      }
      return Response.ok('');
    }
    // rename: ?to=<new name>   move: ?dest=<virtual folder>
    if (path == 'api/mv' && r.method == 'POST') {
      final f = real(vp);
      if (f == null || roots.containsValue(f)) return Response(400);
      String? to;
      if (q['dest'] != null) {
        final d = real(q['dest']!);
        if (d != null) to = p.join(d, p.basename(f));
      } else if (p.basename(q['to'] ?? '').isNotEmpty) {
        to = p.join(p.dirname(f), p.basename(q['to']!));
      }
      if (to == null || p.equals(to, f) || p.isWithin(f, to)) return Response(400);
      try {
        if (await FileSystemEntity.isDirectory(f)) {
          await Directory(f).rename(to);
        } else {
          await File(f).rename(to);
        }
      } on FileSystemException {
        await copyTree(f, to); // rename fails across drives: copy then delete
        await (await FileSystemEntity.isDirectory(f) ? Directory(f).delete(recursive: true) : File(f).delete());
      }
      return Response.ok('');
    }
    if (path == 'api/cp' && r.method == 'POST') {
      final f = real(vp), d = real(q['dest'] ?? '');
      if (f == null || d == null) return Response(400);
      final to = p.join(d, p.basename(f));
      if (p.equals(to, f) || p.isWithin(f, to)) return Response(400);
      await copyTree(f, to);
      return Response.ok('');
    }
    if (path == 'api/places') {
      // the user's well-known folders, as virtual paths inside the shared roots
      final home = Platform.isAndroid ? '/storage/emulated/0' : (Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '');
      final names = Platform.isAndroid
          ? ['Download', 'DCIM', 'Pictures', 'Documents', 'Music', 'Movies']
          : ['Desktop', 'Downloads', 'Documents', 'Pictures', 'Music', 'Videos'];
      final out = <Map>[];
      if (home.isNotEmpty) {
        for (final n in names) {
          final d = p.join(home, n);
          for (final e in roots.entries) {
            if (p.isWithin(e.value, d) && Directory(d).existsSync()) {
              out.add({'n': n, 'p': '${e.key}/${p.relative(d, from: e.value).replaceAll('\\', '/')}'});
              break;
            }
          }
        }
      }
      return _json(out);
    }
    if (path == 'api/mkdir' && r.method == 'POST') {
      final d = real(vp), n = p.basename(q['name'] ?? '');
      if (d == null || n.isEmpty) return Response(400);
      await Directory(p.join(d, n)).create();
      return Response.ok('');
    }
    return Response.notFound('');
  }
}

// ---------------------------------------------------------------- client
final client = IOClient(HttpClient()
  ..badCertificateCallback = ((_, _, _) => true)
  ..connectionTimeout = const Duration(milliseconds: 900));

class Peer {
  Peer(this.base, this.name);
  final String base, name;
  String token = '';
  Map<String, String> get h => {'cookie': 't=$token'};
  Uri u(String path, [Map<String, String>? q]) => Uri.parse('$base/$path').replace(queryParameters: q);
}

Future<Peer?> ping(String ip) async {
  for (final s in ['http', 'https']) {
    try {
      final r = await client.get(Uri.parse('$s://$ip:$port/ping')).timeout(const Duration(seconds: 2));
      if (r.body.startsWith('openconnect:')) return Peer('$s://$ip:$port', r.body.substring('openconnect:'.length));
    } catch (_) {}
  }
  return null;
}

// probe every host on each local /24
Future<List<Peer>> scan() async {
  final mine = <String>{}, subs = <String>{};
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      if (a.isLoopback || a.address.startsWith('169.254.')) continue;
      mine.add(a.address);
      subs.add(a.address.split('.').take(3).join('.'));
    }
  }
  final r = await Future.wait([
    for (final s in subs)
      for (var i = 1; i < 255; i++)
        if (!mine.contains('$s.$i')) ping('$s.$i')
  ]);
  return r.whereType<Peer>().toList();
}

Future<bool> requestAccess(Peer pr) async {
  final id = (await client.post(pr.u('request'))).body;
  for (var i = 0; i < 80; i++) {
    await Future.delayed(const Duration(milliseconds: 1500));
    final r = await client.get(pr.u('status', {'id': id}));
    if (r.body == 'denied') return false;
    if (r.body == 'ok') {
      pr.token = RegExp(r't=([0-9a-f]+)').firstMatch(r.headers['set-cookie'] ?? '')?.group(1) ?? '';
      return pr.token.isNotEmpty;
    }
  }
  return false;
}

Future<bool> ensureStorage() async {
  if (!Platform.isAndroid) return true;
  return (await Permission.manageExternalStorage.request()).isGranted;
}

String downloadsDir() =>
    Platform.isAndroid ? '/storage/emulated/0/Download' : p.join(Platform.environment['USERPROFILE'] ?? '.', 'Downloads');

// ---------------------------------------------------------------- updates
// Peers serve a signed manifest + content-addressed blobs (see tools/release.js).
// Windows downloads only files whose SHA-256 differs from the installed copy (file-level delta);
// Android downloads the full APK and hands it to the system installer.
// ponytail: only the machine holding %APPDATA%\OpenConnect\updates publishes; no relay between peers.
// ponytail: file-level delta: swap in bsdiff patches if app.so gets too big to resend.
const appBuild = 7, appVersion = '1.5.0';

/// How this device appears to others (shown in their scan). Defaults to the computer name; editable in Settings.
String deviceName = Platform.localHostname;
Future<void> setDeviceName(String n) async {
  deviceName = n.trim().isEmpty ? Platform.localHostname : n.trim();
  await (await SharedPreferences.getInstance()).setString('deviceName', deviceName);
}
const updatePubKeyHex = 'e09bbb753be2c690205df098f4a057ee09b700d1bab748b48869ab0a1e587097';

String updatesDir() => p.join(Platform.environment['APPDATA'] ?? Directory.systemTemp.path, 'OpenConnect', 'updates');

List<int> _unhex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

Future<bool> _verify(String msg, String sigHex) => crypt.Ed25519().verify(utf8.encode(msg),
    signature: crypt.Signature(_unhex(sigHex),
        publicKey: crypt.SimplePublicKey(_unhex(updatePubKeyHex), type: crypt.KeyPairType.ed25519)));

Future<String> _sha(File f) async => (await hash.sha256.bind(f.openRead()).first).toString();

class Update {
  Update(this.base, this.m);
  final String base;
  final Map m;
  int get build => m['build'];
  String get name => m['name'];
  List<Map> get files => ((m['windows']?['files'] ?? []) as List).cast<Map>();
}

// newest signed release for this platform, from this machine or any peer on the LAN
Future<Update?> checkUpdate() async {
  final bases = ['http://127.0.0.1:$port', ...(await scan()).map((x) => x.base)];
  Update? best;
  for (final b in bases) {
    try {
      final r = await client.get(Uri.parse('$b/update/manifest')).timeout(const Duration(seconds: 3));
      if (r.statusCode != 200) continue;
      final j = jsonDecode(r.body), ms = j['manifest'] as String;
      if (!await _verify(ms, j['sig'])) continue;
      final m = jsonDecode(ms) as Map;
      if (Platform.isWindows ? m['windows'] == null : (Platform.isAndroid && m['android'] == null)) continue;
      if (m['build'] > appBuild && (best == null || m['build'] > best.build)) best = Update(b, m);
    } catch (_) {}
  }
  return best;
}

// what must be downloaded: Windows = files that differ from the install dir, Android = the APK
Future<List<Map>> needed(Update u) async {
  if (Platform.isAndroid) return [u.m['android']['apk'] as Map];
  final dir = p.dirname(Platform.resolvedExecutable), out = <Map>[];
  for (final f in u.files) {
    final path = p.join(dir, f['p']);
    if (!p.isWithin(dir, path)) throw 'bad path in manifest: ${f['p']}';
    final l = File(path);
    if (!l.existsSync() || await _sha(l) != f['sha']) out.add(f);
  }
  return out;
}

Future<void> _fetchBlob(Update u, String sha, File dest, void Function(int) onBytes) async {
  await dest.parent.create(recursive: true);
  final res = await client.send(http.Request('GET', Uri.parse('${u.base}/update/blob/$sha')));
  if (res.statusCode != 200) throw 'download failed (${res.statusCode})';
  final sink = dest.openWrite();
  await for (final c in res.stream) {
    sink.add(c);
    onBytes(c.length);
  }
  await sink.close();
  if (await _sha(dest) != sha) {
    await dest.delete();
    throw 'corrupt download (hash mismatch)';
  }
}

// Android: opens the system installer. Windows: stages changed files, then a helper script
// copies them over the install dir after this process exits and relaunches the app.
Future<void> applyUpdate(Update u, List<Map> need, void Function(double) prog) async {
  final total = need.fold<int>(0, (s, f) => s + (f['size'] as int));
  var got = 0;
  void tick(int n) {
    got += n;
    if (total > 0) prog(got / total);
  }

  if (Platform.isAndroid) {
    final apk = File(p.join(Directory.systemTemp.path, 'open-connect-${u.build}.apk'));
    await _fetchBlob(u, need.first['sha'], apk, tick);
    await OpenFilex.open(apk.path, type: 'application/vnd.android.package-archive');
    return;
  }
  final dir = p.dirname(Platform.resolvedExecutable), exe = p.basename(Platform.resolvedExecutable);
  final stage = Directory(p.join(Directory.systemTemp.path, 'open-connect-stage-${u.build}'));
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);
  for (final f in need) {
    await _fetchBlob(u, f['sha'], File(p.join(stage.path, f['p'])), tick);
  }
  final bat = File(p.join(Directory.systemTemp.path, 'open-connect-update.bat'));
  // absolute System32 paths: do not depend on the PATH we were launched with
  const sys = r'%SystemRoot%\System32';
  final log = p.join(Directory.systemTemp.path, 'open-connect-update.log');
  await bat.writeAsString('@echo off\r\n$sys\\timeout.exe /t 2 /nobreak >nul\r\n'
      '$sys\\robocopy.exe "${stage.path}" "$dir" /E /IS /IT /R:15 /W:1 >> "$log" 2>&1\r\n'
      'rmdir /s /q "${stage.path}"\r\nstart "" "${p.join(dir, exe)}"\r\n');
  await Process.start('cmd.exe', ['/c', bat.path], mode: ProcessStartMode.detached);
  exit(0);
}

class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});
  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  String status = 'Version $appVersion (build $appBuild)';
  Update? up;
  List<Map> need = [];
  double? prog;
  bool busy = false;

  int sum(Iterable<Map> l) => l.fold(0, (s, f) => s + (f['size'] as int));

  Future<void> check() async {
    setState(() {
      busy = true;
      status = 'Checking this PC and nearby devices...';
    });
    try {
      final u = await checkUpdate();
      if (!mounted) return;
      if (u == null) return setState(() { busy = false; up = null; status = 'Up to date (version $appVersion, build $appBuild)'; });
      final n = await needed(u);
      setState(() {
        busy = false;
        up = u;
        need = n;
        status = 'Version ${u.name} available. Download ${fmtSize(sum(n))}'
            '${Platform.isAndroid ? '' : ' of ${fmtSize(sum(u.files))} (changed files only)'}';
      });
    } catch (e) {
      if (mounted) setState(() { busy = false; status = 'Update check failed: $e'; });
    }
  }

  Future<void> install() async {
    setState(() { busy = true; prog = 0; });
    try {
      await applyUpdate(up!, need, (v) { if (mounted) setState(() => prog = v); });
      if (mounted) setState(() { busy = false; prog = null; status = 'Installer opened: confirm to finish.'; });
    } catch (e) {
      if (mounted) setState(() { busy = false; prog = null; status = 'Update failed: $e'; });
    }
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Card(
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update_alt),
            title: const Text('Updates'),
            subtitle: Text(status),
            trailing: up == null
                ? TextButton(onPressed: busy ? null : check, child: const Text('Check'))
                : FilledButton(onPressed: busy ? null : install, child: const Text('Update')),
          ),
          if (prog != null || (busy && up == null)) LinearProgressIndicator(value: prog),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- background
// Windows: closing the window hides it to the tray; the server keeps running. Optional autostart.
// Android: a foreground service (with notification) keeps the process, and so the server, alive.
const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

class _Tray with TrayListener, WindowListener {
  void show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() => windowManager.hide();
  @override
  void onTrayIconMouseDown() => show();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem i) => i.key == 'quit' ? exit(0) : show();
}

Future<void> initBackground(List<String> args) async {
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    final t = _Tray();
    windowManager.addListener(t);
    trayManager.addListener(t);
    await trayManager.setIcon('assets/tray.ico');
    await trayManager.setToolTip('Open Connect');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Open Open Connect'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
    windowManager.waitUntilReadyToShow(const WindowOptions(title: 'Open Connect'), () async {
      if (args.contains('--background')) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  } else if (Platform.isAndroid) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'open_connect',
        channelName: 'Open Connect sharing',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    await FlutterForegroundTask.requestNotificationPermission();
    await startShareService();
    _watchNetwork();
  }
}

// Android: the notification stays until the user taps Quit, or the phone has been off this Wi-Fi
// (out of range / another network) for 15 s while the app is not on screen.
@pragma('vm:entry-point')
void taskEntry() => FlutterForegroundTask.setTaskHandler(_QuitHandler());

class _QuitHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'quit') FlutterForegroundTask.stopService().whenComplete(() => exit(0));
  }
}

Set<String> _subnets = {}; // the network the service was started on
String _lastText = '';
var _miss = 0;

Set<String> _nets(List<String> ips) => {for (final i in ips) i.split('.').take(3).join('.')};

String _status(List<String> ips) =>
    '${ips.first}:$port · ${host.sessions.isEmpty ? 'no devices connected yet' : '${host.sessions.length} device(s) connected'}';

Future<void> startShareService() async {
  final ips = await localIps();
  if (ips.isEmpty || await FlutterForegroundTask.isRunningService) return;
  _subnets = _nets(ips);
  _lastText = _status(ips);
  await FlutterForegroundTask.startService(
    serviceId: 256,
    serviceTypes: [ForegroundServiceTypes.specialUse],
    notificationTitle: 'Open Connect is sharing',
    notificationText: _lastText,
    notificationButtons: const [NotificationButton(id: 'quit', text: 'Quit')],
    callback: taskEntry,
  );
}

void _watchNetwork() => Timer.periodic(const Duration(seconds: 5), (_) async {
      final ips = await localIps();
      final onScreen = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      // someone is using the app: whatever network it is on now is the right one
      if (onScreen && ips.isNotEmpty) _subnets = _nets(ips);
      if (!await FlutterForegroundTask.isRunningService) {
        if (onScreen) await startShareService();
        return;
      }
      _miss = onScreen || _nets(ips).any(_subnets.contains) ? 0 : _miss + 1;
      if (_miss >= 3) {
        await FlutterForegroundTask.stopService();
        exit(0); // not in range any more: stop serving, free the process
      }
      if (ips.isEmpty) return;
      final text = _status(ips);
      if (text != _lastText) {
        _lastText = text;
        FlutterForegroundTask.updateService(notificationText: text);
      }
    });

class BackgroundCard extends StatefulWidget {
  const BackgroundCard({super.key});
  @override
  State<BackgroundCard> createState() => _BackgroundCardState();
}

class _BackgroundCardState extends State<BackgroundCard> {
  bool auto = false;
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      Process.run('reg', ['query', _runKey, '/v', 'OpenConnect']).then((r) {
        if (mounted) setState(() => auto = r.exitCode == 0);
      });
    }
  }

  Future<void> setAuto(bool on) async {
    final r = await Process.run(
        'reg',
        on
            ? ['add', _runKey, '/v', 'OpenConnect', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --background', '/f']
            : ['delete', _runKey, '/v', 'OpenConnect', '/f']);
    if (mounted) setState(() => auto = r.exitCode == 0 ? on : auto);
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Card(
      color: cs.surfaceContainerHighest,
      child: Platform.isWindows
          ? SwitchListTile(
              secondary: const Icon(Icons.power_settings_new),
              title: const Text('Start with Windows'),
              subtitle: const Text('Closing the window keeps Open Connect running in the system tray.'),
              value: auto,
              onChanged: setAuto)
          : ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Runs in the background'),
              subtitle: const Text(
                  'A notification keeps sharing alive while you use your phone. It stops when you tap Quit or leave this Wi-Fi. Disable battery optimization for best results.'),
              trailing: TextButton(
                  onPressed: () async {
                    await FlutterForegroundTask.stopService();
                    exit(0);
                  },
                  child: const Text('Quit'))),
    );
  }
}

// ---------------------------------------------------------------- UI
String fmtSize(num b) {
  if (b < 1024) return '${b.toInt()} B';
  if (b < 1048576) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
  return '${(b / 1073741824).toStringAsFixed(2)} GB';
}

IconData fileIcon(String n) {
  switch (p.extension(n).toLowerCase()) {
    case '.jpg': case '.jpeg': case '.png': case '.gif': case '.webp': case '.heic': case '.bmp':
      return Icons.image_outlined;
    case '.mp4': case '.mkv': case '.mov': case '.avi': case '.webm':
      return Icons.movie_outlined;
    case '.mp3': case '.wav': case '.flac': case '.m4a': case '.aac':
      return Icons.audiotrack_outlined;
    case '.pdf': case '.doc': case '.docx': case '.txt': case '.md': case '.xls': case '.xlsx': case '.ppt': case '.pptx':
      return Icons.description_outlined;
    case '.zip': case '.rar': case '.7z': case '.tar': case '.gz':
      return Icons.folder_zip_outlined;
    case '.apk': case '.exe': case '.msi':
      return Icons.apps_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

Color fileColor(String n, ColorScheme cs) {
  switch (p.extension(n).toLowerCase()) {
    case '.jpg': case '.jpeg': case '.png': case '.gif': case '.webp': case '.heic': case '.bmp':
      return const Color(0xFFE91E63);
    case '.mp4': case '.mkv': case '.mov': case '.avi': case '.webm':
      return const Color(0xFF8E44AD);
    case '.mp3': case '.wav': case '.flac': case '.m4a': case '.aac':
      return const Color(0xFFF57C00);
    case '.pdf': case '.doc': case '.docx': case '.txt': case '.md': case '.xls': case '.xlsx': case '.ppt': case '.pptx':
      return const Color(0xFF2563EB);
    case '.zip': case '.rar': case '.7z': case '.tar': case '.gz':
      return const Color(0xFFB8860B);
    case '.apk': case '.exe': case '.msi':
      return const Color(0xFF2E9E5B);
    default:
      return cs.onSurfaceVariant;
  }
}

/// Icon on a soft tinted rounded square (file-type colour), the look of current Material 3 file managers.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, this.color, {super.key, this.size = 40});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext c) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color.withValues(alpha: .15), borderRadius: BorderRadius.circular(size * .32)),
        child: Icon(icon, color: color, size: size * .55),
      );
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (args.contains('--update')) {
    // headless: install the newest signed release (relaunches the app on Windows) and exit
    final log = File(p.join(Directory.systemTemp.path, 'open-connect-update.log'));
    void say(String s) => log.writeAsStringSync('${DateTime.now().toIso8601String()} $s\n', mode: FileMode.append);
    try {
      say('checking (running build $appBuild)');
      final u = await checkUpdate();
      say(u == null ? 'up to date' : 'found build ${u.build} from ${u.base}');
      if (u != null) {
        final n = await needed(u);
        say('downloading ${n.length} changed file(s), ${n.fold<int>(0, (s, f) => s + (f['size'] as int))} bytes');
        await applyUpdate(u, n, (_) {});
      }
    } catch (e) {
      say('failed: $e');
    }
    exit(0);
  }
  try {
    deviceName = (await SharedPreferences.getInstance()).getString('deviceName') ?? deviceName;
  } catch (_) {}
  await initBackground(args);
  host.approve = (who) async {
    // a hidden/minimized/covered window must still surface the prompt
    try {
      if (Platform.isWindows) {
        await windowManager.show();
        await windowManager.restore();
        await windowManager.setAlwaysOnTop(true);
        await windowManager.focus();
      } else if (Platform.isAndroid) {
        FlutterForegroundTask.launchApp();
      }
    } catch (_) {}
    for (var i = 0; navKey.currentContext == null && i < 50; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final ok = await _askApproval(who);
    if (Platform.isWindows) windowManager.setAlwaysOnTop(false).catchError((_) {});
    return ok;
  };
  host.received = (name, from) {
    final c = navKey.currentContext;
    if (c != null) toast(c, 'Received "$name" from $from');
  };
  if (Platform.isAndroid && await Permission.manageExternalStorage.isGranted) host.addRoot('/storage/emulated/0');
  // share every drive on Windows so the whole PC is browsable once a device is approved
  // probed in the background with a timeout: a dead network/card-reader drive must not block startup
  if (Platform.isWindows) {
    for (var i = 65; i <= 90; i++) {
      final d = '${String.fromCharCode(i)}:\\';
      Directory(d).exists().timeout(const Duration(seconds: 3), onTimeout: () => false).then((ok) {
        if (ok) host.addRoot(d);
      });
    }
  }
  try {
    await host.start();
  } catch (_) {} // port busy: still usable as a client
  runApp(MaterialApp(
    navigatorKey: navKey,
    title: 'Open Connect',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: const Home(),
  ));
}

Future<bool> _askApproval(String who) async =>
    await showDialog<bool>(
      context: navKey.currentContext!,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.shield_outlined, size: 32),
        title: const Text('Allow access?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Device', style: Theme.of(c).textTheme.labelMedium),
          SelectableText(who, style: Theme.of(c).textTheme.bodyLarge),
          const SizedBox(height: 12),
          const Text('It will be able to browse, download, upload, rename and delete files in your shared folders.'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Deny')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Allow')),
        ],
      ),
    ) ??
    false;

ThemeData _theme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF2563EB),
      brightness: b,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      listTileTheme: ListTileThemeData(minVerticalPadding: 8, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      chipTheme: const ChipThemeData(shape: StadiumBorder(), side: BorderSide.none),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(0, 44))),
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );

void toast(BuildContext c, String m) {
  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
}

class Page extends StatelessWidget {
  const Page({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext c) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: children),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.actions = const []});
  final IconData icon;
  final String title, body;
  final List<Widget> actions;
  @override
  Widget build(BuildContext c) {
    final t = Theme.of(c), cs = t.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 36, backgroundColor: cs.secondaryContainer, child: Icon(icon, size: 36, color: cs.onSecondaryContainer)),
            const SizedBox(height: 16),
            Text(title, style: t.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body, style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            if (actions.isNotEmpty) ...[const SizedBox(height: 20), Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: actions)],
          ]),
        ),
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  static const _dest = [
    (Icons.folder_open_outlined, Icons.folder_open, 'Explorer'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];
  @override
  Widget build(BuildContext c) {
    final body = IndexedStack(index: tab, children: [ExplorerPage(), SettingsPage()]);
    final wide = MediaQuery.sizeOf(c).width >= 700;
    return Scaffold(
      body: SafeArea(
        child: wide
            ? Row(children: [
                NavigationRail(
                  selectedIndex: tab,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => tab = i),
                  destinations: [for (final d in _dest) NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3))],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ])
            : body,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: [for (final d in _dest) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3)],
            ),
    );
  }
}

class DeviceCard extends StatefulWidget {
  const DeviceCard({super.key});
  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  List<String> ips = [];
  @override
  void initState() {
    super.initState();
    localIps().then((v) => mounted ? setState(() => ips = v) : null);
  }

  @override
  Widget build(BuildContext c) {
    final t = Theme.of(c), cs = t.colorScheme;
    return Column(children: [
      Card(
        color: cs.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Platform.isAndroid ? Icons.phone_android : Icons.computer, color: cs.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(child: Text(deviceName, style: t.textTheme.titleLarge?.copyWith(color: cs.onPrimaryContainer))),
              IconButton(
                tooltip: 'Rename this device',
                icon: Icon(Icons.edit_outlined, color: cs.onPrimaryContainer),
                onPressed: () async {
                  final ctl = TextEditingController(text: deviceName);
                  final n = await showDialog<String>(
                    context: c,
                    builder: (d) => AlertDialog(
                      title: const Text('Device name'),
                      content: TextField(
                          controller: ctl,
                          autofocus: true,
                          maxLength: 40,
                          decoration: InputDecoration(hintText: Platform.localHostname, helperText: 'Shown to other devices when they scan', border: const OutlineInputBorder()),
                          onSubmitted: (v) => Navigator.pop(d, v)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('Save')),
                      ],
                    ),
                  );
                  if (n == null) return;
                  await setDeviceName(n);
                  if (mounted) setState(() {});
                },
              ),
            ]),
            const SizedBox(height: 4),
            Text(host.startError ?? 'Visible to other devices on this network. Tap an address to copy.',
                style: t.textTheme.bodyMedium?.copyWith(color: host.startError == null ? cs.onPrimaryContainer : cs.error)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final ip in ips)
                ActionChip(
                  avatar: const Icon(Icons.copy, size: 16),
                  label: Text('$ip:$port'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: '$ip:$port'));
                    toast(c, 'Copied $ip:$port');
                  },
                ),
              if (ips.isEmpty) const Chip(label: Text('No network connection')),
            ]),
          ]),
        ),
      ),
    ]);
  }
}

// all configuration lives here: shared folders, background behaviour, updates
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext c) {
    final t = Theme.of(c), cs = t.colorScheme;
    return Page(children: [
      Text('Settings', style: t.textTheme.headlineSmall),
      const SizedBox(height: 12),
      const DeviceCard(),
      const SizedBox(height: 16),
      Text('Shared folders', style: t.textTheme.titleMedium),
      const SizedBox(height: 4),
      if (host.roots.isEmpty)
        Card(
          color: cs.surfaceContainerHighest,
          child: const Padding(padding: EdgeInsets.all(16), child: Text('Nothing shared yet. Add a folder so approved devices can see it.')),
        ),
      for (final e in host.roots.entries)
        Card(
          color: cs.surfaceContainerHighest,
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(e.key),
            subtitle: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
                tooltip: 'Stop sharing',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => host.roots.remove(e.key))),
          ),
        ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Share a folder'),
            onPressed: () async {
              final d = await FilePicker.getDirectoryPath();
              if (d != null) setState(() => host.addRoot(d));
            }),
        if (Platform.isAndroid)
          FilledButton.tonalIcon(
              icon: const Icon(Icons.phone_android),
              label: const Text('Share all phone storage'),
              onPressed: () async {
                if (await ensureStorage()) setState(() => host.addRoot('/storage/emulated/0'));
              }),
      ]),
      const SizedBox(height: 24),
      Text('Background', style: t.textTheme.titleMedium),
      const BackgroundCard(),
      const SizedBox(height: 16),
      Text('Updates', style: t.textTheme.titleMedium),
      const UpdateCard(),
      const SizedBox(height: 24),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lock_outline, size: 18, color: cs.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
            child: Text(
                'Every device must be approved here first. Traffic is not encrypted: use trusted Wi-Fi only.',
                style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
      ]),
    ]);
  }
}

