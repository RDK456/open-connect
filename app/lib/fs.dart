// One filesystem interface so the Explorer UI works the same on this device and on remote devices.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'main.dart';

class Entry {
  Entry(this.name, this.isDir, this.size, this.modified);
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}

abstract class Fs {
  String get label;
  String join(String dir, String name);
  String parent(String path); // '' = top level (drives / shared roots)
  Future<List<Entry>> ls(String path);
  Future<void> mkdir(String dir, String name);
  Future<void> rename(String path, String newName);
  Future<void> delete(String path);
  Future<void> copy(String path, String destDir);
  Future<void> move(String path, String destDir);
  Future<void> download(String path, File dest, void Function(int) onBytes);
  Future<void> upload(String dir, File src, String name, void Function(int) onBytes);
  bool sameDevice(Fs o);
}

class LocalFs extends Fs {
  List<String>? _roots;

  @override
  String get label => '${Platform.localHostname} (this device)';
  @override
  String join(String dir, String name) => dir.isEmpty ? name : p.join(dir, name);
  @override
  String parent(String path) {
    if (path.isEmpty) return '';
    final up = p.dirname(path);
    return p.equals(up, path) ? '' : up;
  }

  Future<List<String>> roots() async {
    if (_roots != null) return _roots!;
    if (Platform.isWindows) {
      // dead network / card-reader drives must not hang the listing
      final found = await Future.wait([
        for (var i = 65; i <= 90; i++)
          Directory('${String.fromCharCode(i)}:\\').exists().timeout(const Duration(seconds: 2), onTimeout: () => false)
      ]);
      return _roots = [for (var i = 0; i < 26; i++) if (found[i]) '${String.fromCharCode(65 + i)}:\\'];
    }
    return _roots = Platform.isAndroid ? ['/storage/emulated/0'] : ['/'];
  }

  @override
  Future<List<Entry>> ls(String path) async {
    if (path.isEmpty) {
      await ensureStorage();
      return [for (final r in await roots()) Entry(r, true, 0, null)];
    }
    final out = <Entry>[];
    await for (final e in Directory(path).list(followLinks: false)) {
      try {
        final s = await e.stat();
        out.add(Entry(p.basename(e.path), s.type == FileSystemEntityType.directory, s.size, s.modified));
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<void> mkdir(String dir, String name) => Directory(p.join(dir, name)).create();
  @override
  Future<void> rename(String path, String newName) => _mv(path, p.join(p.dirname(path), newName));
  @override
  Future<void> delete(String path) async {
    if (await FileSystemEntity.isDirectory(path)) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
  }

  @override
  Future<void> copy(String path, String destDir) => copyTree(path, p.join(destDir, p.basename(path)));
  @override
  Future<void> move(String path, String destDir) => _mv(path, p.join(destDir, p.basename(path)));

  Future<void> _mv(String from, String to) async {
    if (p.equals(from, to) || p.isWithin(from, to)) throw 'Cannot move a folder into itself';
    try {
      if (await FileSystemEntity.isDirectory(from)) {
        await Directory(from).rename(to);
      } else {
        await File(from).rename(to);
      }
    } on FileSystemException {
      await copyTree(from, to); // across drives
      await delete(from);
    }
  }

  @override
  Future<void> download(String path, File dest, void Function(int) onBytes) async {
    await dest.parent.create(recursive: true);
    await File(path).copy(dest.path);
    onBytes(await dest.length());
  }

  @override
  Future<void> upload(String dir, File src, String name, void Function(int) onBytes) async {
    await src.copy(p.join(dir, name));
    onBytes(await src.length());
  }

  @override
  bool sameDevice(Fs o) => o is LocalFs;
}

class RemoteFs extends Fs {
  RemoteFs(this.peer);
  final Peer peer;

  @override
  String get label => peer.name;
  @override
  String join(String dir, String name) => dir.isEmpty ? name : '$dir/$name';
  @override
  String parent(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

  Future<http.Response> _post(String ep, Map<String, String> q) async {
    final r = await client.post(peer.u(ep, q), headers: peer.h);
    if (r.statusCode != 200) throw 'Request failed (${r.statusCode})';
    return r;
  }

  @override
  Future<List<Entry>> ls(String path) async {
    final r = await client.get(peer.u('api/ls', {'p': path}), headers: peer.h);
    if (r.statusCode == 401) throw 'Access expired: reconnect to ${peer.name}';
    if (r.statusCode != 200) throw 'Cannot open this folder (${r.statusCode})';
    return [
      for (final e in jsonDecode(r.body) as List)
        Entry(e['n'], e['d'] == true, (e['s'] ?? 0) as int,
            e['m'] == null ? null : DateTime.fromMillisecondsSinceEpoch(e['m'] as int))
    ];
  }

  @override
  Future<void> mkdir(String dir, String name) => _post('api/mkdir', {'p': dir, 'name': name});
  @override
  Future<void> rename(String path, String newName) => _post('api/mv', {'p': path, 'to': newName});
  @override
  Future<void> delete(String path) => _post('api/rm', {'p': path});
  @override
  Future<void> copy(String path, String destDir) => _post('api/cp', {'p': path, 'dest': destDir});
  @override
  Future<void> move(String path, String destDir) => _post('api/mv', {'p': path, 'dest': destDir});

  @override
  Future<void> download(String path, File dest, void Function(int) onBytes) async {
    await dest.parent.create(recursive: true);
    final res = await client.send(http.Request('GET', peer.u('api/file', {'p': path}))..headers.addAll(peer.h));
    if (res.statusCode != 200) throw 'Download failed (${res.statusCode})';
    final sink = dest.openWrite();
    await for (final c in res.stream) {
      sink.add(c);
      onBytes(c.length);
    }
    await sink.close();
  }

  @override
  Future<void> upload(String dir, File src, String name, void Function(int) onBytes) async {
    final len = await src.length();
    final req = http.StreamedRequest('POST', peer.u('api/up', {'p': dir, 'name': name}))
      ..headers.addAll(peer.h)
      ..contentLength = len;
    src.openRead().pipe(req.sink);
    final res = await client.send(req);
    if (res.statusCode != 200) throw 'Upload failed (${res.statusCode})';
    onBytes(len);
  }

  @override
  bool sameDevice(Fs o) => o is RemoteFs && o.peer.base == peer.base;
}

/// Copy or move [e] (inside [srcDir] of [src]) into [destDir] of [dst]; works across devices.
/// ponytail: existing files with the same name are overwritten without asking.
Future<void> transfer(Fs src, String srcDir, Entry e, Fs dst, String destDir,
    {required bool move, required void Function(int) onBytes}) async {
  final path = src.join(srcDir, e.name);
  if (src.sameDevice(dst)) {
    move ? await src.move(path, destDir) : await src.copy(path, destDir);
    return;
  }
  await _xfer(src, srcDir, e, dst, destDir, onBytes);
  if (move) await src.delete(path);
}

Future<void> _xfer(Fs src, String srcDir, Entry e, Fs dst, String destDir, void Function(int) onBytes) async {
  final path = src.join(srcDir, e.name);
  if (e.isDir) {
    await dst.mkdir(destDir, e.name);
    for (final c in await src.ls(path)) {
      await _xfer(src, path, c, dst, dst.join(destDir, e.name), onBytes);
    }
  } else if (src is LocalFs) {
    await dst.upload(destDir, File(path), e.name, onBytes);
  } else if (dst is LocalFs) {
    await src.download(path, File(p.join(destDir, e.name)), onBytes);
  } else {
    final tmp = File(p.join(Directory.systemTemp.path, 'lf-relay-${rand(6)}'));
    try {
      await src.download(path, tmp, (_) {});
      await dst.upload(destDir, tmp, e.name, onBytes);
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  }
}
