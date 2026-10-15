// File-explorer UI: locations sidebar, back/forward/up, address bar, sortable details view,
// icon grid, multi-select, context menu, cut/copy/paste (also between devices), new folder, search.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import 'fs.dart';
import 'main.dart';

class Clip {
  Clip(this.fs, this.dir, this.items, this.cut);
  final Fs fs;
  final String dir;
  final List<Entry> items;
  final bool cut;
}

Clip? _clip; // app-wide so you can copy on one device and paste on another

String _two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime? d) => d == null ? '' : '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
const _risky = {'.exe', '.msi', '.bat', '.cmd', '.ps1', '.scr', '.vbs', '.js', '.apk', '.lnk'};

class ExplorerPage extends StatefulWidget {
  const ExplorerPage({super.key});
  @override
  State<ExplorerPage> createState() => _ExplorerPageState();
}

class _ExplorerPageState extends State<ExplorerPage> {
  final scaffold = GlobalKey<ScaffoldState>();
  final local = LocalFs();
  final remotes = <String, RemoteFs>{};
  final found = <Peer>[];
  late Fs fs;
  String path = '';
  final back = <(Fs, String)>[], fwd = <(Fs, String)>[];
  List<Entry>? items;
  String? error;
  bool loading = false, scanning = false, grid = false, editing = false, wide = false;
  Set<String> sel = {};
  int? anchor;
  String sortCol = 'name', filter = '';
  bool asc = true;
  String? busy;
  int done = 0;
  List<String> drives = [];
  final quick = <(String, IconData, String)>[];
  final searchCtl = TextEditingController(), addrCtl = TextEditingController();
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    fs = local;
    _load();
    local.roots().then((r) => mounted ? setState(() => drives = r) : null);
    final home = Platform.isAndroid ? '/storage/emulated/0' : (Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '');
    if (home.isNotEmpty) {
      final names = Platform.isAndroid
          ? [('Download', Icons.download_outlined), ('DCIM', Icons.photo_camera_outlined), ('Pictures', Icons.image_outlined), ('Documents', Icons.description_outlined), ('Music', Icons.music_note_outlined), ('Movies', Icons.movie_outlined)]
          : [('Desktop', Icons.desktop_windows_outlined), ('Downloads', Icons.download_outlined), ('Documents', Icons.description_outlined), ('Pictures', Icons.image_outlined), ('Music', Icons.music_note_outlined), ('Videos', Icons.movie_outlined)];
      for (final n in names) {
        final d = p.join(home, n.$1);
        if (Directory(d).existsSync()) quick.add((n.$1, n.$2, d));
      }
    }
    doScan();
  }

  @override
  void dispose() {
    searchCtl.dispose();
    addrCtl.dispose();
    focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- navigation
  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final l = await fs.ls(path);
      if (mounted) setState(() { items = l; loading = false; });
    } catch (e) {
      if (mounted) setState(() { items = []; loading = false; error = '$e'; });
    }
  }

  Future<void> go(Fs f, String pth, {bool record = true}) async {
    if (record) {
      back.add((fs, path));
      fwd.clear();
    }
    setState(() {
      fs = f;
      path = pth;
      sel = {};
      anchor = null;
      filter = '';
      editing = false;
      items = null;
      searchCtl.clear();
    });
    await _load();
  }

  void goBack() {
    if (back.isEmpty) return;
    fwd.add((fs, path));
    final (f, pp) = back.removeLast();
    go(f, pp, record: false);
  }

  void goFwd() {
    if (fwd.isEmpty) return;
    back.add((fs, path));
    final (f, pp) = fwd.removeLast();
    go(f, pp, record: false);
  }

  void goUp() {
    if (path.isNotEmpty) go(fs, fs.parent(path));
  }

  Future<void> doScan() async {
    setState(() => scanning = true);
    final r = await scan();
    if (!mounted) return;
    setState(() {
      for (final pr in r) {
        if (!found.any((x) => x.base == pr.base)) found.add(pr);
      }
      scanning = false;
    });
  }

  Future<void> connect(Peer pr) async {
    var r = remotes[pr.base];
    if (r == null) {
      setState(() { busy = 'Waiting for approval on ${pr.name}...'; done = 0; });
      var ok = false;
      try {
        ok = await requestAccess(pr);
      } catch (_) {}
      if (!mounted) return;
      setState(() => busy = null);
      if (!ok) return toast(context, 'Access denied, timed out or unreachable');
      r = remotes[pr.base] = RemoteFs(pr);
    }
    await go(r, '');
  }

  Future<void> byIp() async {
    final ip = await askText('Connect by IP', '', 'Connect', hint: '192.168.1.20');
    if (ip == null || ip.trim().isEmpty) return;
    final pr = await ping(ip.trim());
    if (!mounted) return;
    if (pr == null) return toast(context, 'No Open Connect device at ${ip.trim()}');
    if (!found.any((x) => x.base == pr.base)) setState(() => found.add(pr));
    await connect(pr);
  }

  // ---------------------------------------------------------------- dialogs / helpers
  Future<String?> askText(String title, String initial, String action, {String? hint}) {
    final ctl = TextEditingController(text: initial);
    ctl.selection = TextSelection(baseOffset: 0, extentOffset: initial.contains('.') ? initial.lastIndexOf('.') : initial.length);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()), onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: Text(action)),
        ],
      ),
    );
  }

  Future<bool> confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> run(String label, Future<void> Function(void Function(int) bytes) body) async {
    setState(() { busy = label; done = 0; });
    try {
      await body((n) {
        done += n;
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
    if (mounted) setState(() => busy = null);
  }

  List<Entry> get selected => (items ?? []).where((e) => sel.contains(e.name)).toList();
  bool get canWrite => path.isNotEmpty;

  List<Entry> get view {
    final l = (items ?? []).where((e) => filter.isEmpty || e.name.toLowerCase().contains(filter)).toList();
    l.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final r = switch (sortCol) {
        'date' => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
        'type' => p.extension(a.name).compareTo(p.extension(b.name)),
        'size' => a.size.compareTo(b.size),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return asc ? r : -r;
    });
    return l;
  }

  String typeOf(Entry e) {
    if (path.isEmpty) return 'Drive';
    if (e.isDir) return 'File folder';
    final x = p.extension(e.name);
    return x.isEmpty ? 'File' : '${x.substring(1).toUpperCase()} file';
  }

  // ---------------------------------------------------------------- actions
  Future<void> openEntry(Entry e) async {
    if (e.isDir) return go(fs, fs.join(path, e.name));
    final src = fs.join(path, e.name), ext = p.extension(e.name).toLowerCase();
    if (fs is RemoteFs && _risky.contains(ext) && !await confirm('Run a file from another device?', '"${e.name}" came from ${fs.label}. Only open programs you trust.', 'Open anyway')) return;
    File f;
    if (fs is LocalFs) {
      f = File(src);
    } else {
      f = File(p.join(Directory.systemTemp.path, 'open-connect-open', e.name));
      await run('Opening ${e.name}', (b) => fs.download(src, f, b));
    }
    if (!f.existsSync()) return;
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [f.path], mode: ProcessStartMode.detached);
    } else {
      await OpenFilex.open(f.path);
    }
  }

  void copyCut(bool cut) {
    if (sel.isEmpty || !canWrite) return;
    setState(() => _clip = Clip(fs, path, selected, cut));
    toast(context, '${sel.length} item${sel.length == 1 ? '' : 's'} ${cut ? 'cut' : 'copied'}');
  }

  Future<void> paste() async {
    final c = _clip;
    if (c == null || !canWrite) return;
    await run('${c.cut ? 'Moving' : 'Copying'} ${c.items.length} item(s)...', (b) async {
      for (final e in c.items) {
        await transfer(c.fs, c.dir, e, fs, path, move: c.cut, onBytes: b);
      }
    });
    if (c.cut) _clip = null;
    await _load();
  }

  Future<void> delete() async {
    if (sel.isEmpty || !canWrite) return;
    final n = sel.length;
    if (!await confirm('Delete $n item${n == 1 ? '' : 's'}?', 'This permanently deletes ${n == 1 ? '"${sel.first}"' : 'the selected items'} from ${fs.label}. There is no Recycle Bin.', 'Delete')) return;
    final victims = selected;
    await run('Deleting...', (b) async {
      for (final e in victims) {
        await fs.delete(fs.join(path, e.name));
      }
    });
    sel = {};
    await _load();
  }

  Future<void> rename() async {
    if (sel.length != 1 || !canWrite) return;
    final old = sel.first;
    final n = await askText('Rename', old, 'Rename');
    if (n == null || n.isEmpty || n == old) return;
    if (n.contains('/') || n.contains('\\')) return toast(context, 'Name cannot contain / or \\');
    await run('Renaming...', (b) => fs.rename(fs.join(path, old), n));
    sel = {n};
    await _load();
  }

  Future<void> newFolder() async {
    if (!canWrite) return;
    final n = await askText('New folder', 'New folder', 'Create');
    if (n == null || n.trim().isEmpty) return;
    await run('Creating folder...', (b) => fs.mkdir(path, n.trim()));
    sel = {n.trim()};
    await _load();
  }

  Future<void> addFiles() async {
    if (!canWrite) return;
    final pick = await FilePicker.pickFiles();
    if (pick.isEmpty) return;
    await run('Uploading ${pick.length} file(s)...', (b) async {
      for (final f in pick.where((f) => f.path != null)) {
        await fs.upload(path, File(f.path!), f.name, b);
      }
    });
    await _load();
  }

  // copy to this device's Downloads folder (works for files and folders)
  Future<void> saveToDownloads() async {
    if (sel.isEmpty || fs is LocalFs) return;
    if (!await ensureStorage()) return toast(context, 'Storage permission needed');
    final dl = downloadsDir(), items = selected;
    await run('Saving to Downloads...', (b) async {
      for (final e in items) {
        await transfer(fs, path, e, local, dl, move: false, onBytes: b);
      }
    });
    if (mounted) toast(context, 'Saved to $dl');
  }

  // ---------------------------------------------------------------- selection
  void tapEntry(Entry e, int i) {
    focus.requestFocus();
    if (Platform.isAndroid) {
      sel.isNotEmpty ? toggle(e, i) : openEntry(e);
      return;
    }
    final kb = HardwareKeyboard.instance;
    setState(() {
      if (kb.isControlPressed) {
        sel = {...sel};
        sel.contains(e.name) ? sel.remove(e.name) : sel.add(e.name);
        anchor = i;
      } else if (kb.isShiftPressed && anchor != null) {
        final l = view, a = min(anchor!, i), b = max(anchor!, i);
        sel = {for (var k = a; k <= b; k++) l[k].name};
      } else {
        sel = {e.name};
        anchor = i;
      }
    });
  }

  void toggle(Entry e, int i) => setState(() {
        sel = {...sel};
        sel.contains(e.name) ? sel.remove(e.name) : sel.add(e.name);
        anchor = i;
      });

  void selectAll() => setState(() => sel = {for (final e in view) e.name});

  // ---------------------------------------------------------------- context menu
  Future<void> menuAt(Offset pos, {Entry? e}) async {
    PopupMenuItem<String> mi(String v, IconData ic, String t, {bool on = true}) =>
        PopupMenuItem(value: v, enabled: on, child: Row(children: [Icon(ic, size: 20), const SizedBox(width: 12), Text(t)]));
    final hasSel = sel.isNotEmpty && canWrite;
    final entries = <PopupMenuEntry<String>>[
      if (e != null) ...[
        mi('open', Icons.open_in_new, 'Open'),
        if (fs is RemoteFs) mi('save', Icons.download_outlined, 'Save to Downloads'),
        const PopupMenuDivider(),
        mi('cut', Icons.content_cut, 'Cut', on: hasSel),
        mi('copy', Icons.content_copy, 'Copy', on: hasSel),
      ],
      mi('paste', Icons.content_paste, 'Paste', on: _clip != null && canWrite),
      if (e != null) ...[
        mi('rename', Icons.drive_file_rename_outline, 'Rename', on: sel.length == 1 && canWrite),
        mi('delete', Icons.delete_outline, 'Delete', on: hasSel),
      ] else ...[
        const PopupMenuDivider(),
        mi('newfolder', Icons.create_new_folder_outlined, 'New folder', on: canWrite),
        mi('refresh', Icons.refresh, 'Refresh'),
      ],
    ];
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(Rect.fromLTWH(pos.dx, pos.dy, 0, 0), Offset.zero & MediaQuery.sizeOf(context)),
      items: entries,
    );
    switch (v) {
      case 'open':
        if (e != null) openEntry(e);
      case 'save':
        saveToDownloads();
      case 'cut':
        copyCut(true);
      case 'copy':
        copyCut(false);
      case 'paste':
        paste();
      case 'rename':
        rename();
      case 'delete':
        delete();
      case 'newfolder':
        newFolder();
      case 'refresh':
        _load();
    }
  }

  // ---------------------------------------------------------------- build
  @override
  Widget build(BuildContext c) {
    wide = MediaQuery.sizeOf(c).width >= 800;
    final cs = Theme.of(c).colorScheme;
    final body = Column(children: [
      toolbar(c),
      commandBar(c),
      const Divider(height: 1),
      Expanded(child: content(c)),
      statusBar(c),
    ]);
    return PopScope(
      canPop: !(Platform.isAndroid && (path.isNotEmpty || back.isNotEmpty)),
      onPopInvokedWithResult: (did, _) {
        if (!did) path.isNotEmpty ? goUp() : goBack();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.backspace): goUp,
          const SingleActivator(LogicalKeyboardKey.f5): _load,
          const SingleActivator(LogicalKeyboardKey.f2): rename,
          const SingleActivator(LogicalKeyboardKey.delete): delete,
          const SingleActivator(LogicalKeyboardKey.enter): () {
            final s = selected;
            if (s.length == 1) openEntry(s.first);
          },
          const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => sel = {}),
          const SingleActivator(LogicalKeyboardKey.keyA, control: true): selectAll,
          const SingleActivator(LogicalKeyboardKey.keyC, control: true): () => copyCut(false),
          const SingleActivator(LogicalKeyboardKey.keyX, control: true): () => copyCut(true),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): paste,
          const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): newFolder,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): goBack,
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): goFwd,
        },
        child: Focus(
          focusNode: focus,
          autofocus: true,
          child: Scaffold(
            key: scaffold,
            backgroundColor: cs.surface,
            drawer: wide ? null : Drawer(child: sidebar(c, drawer: true)),
            body: wide
                ? Row(children: [SizedBox(width: 250, child: sidebar(c)), const VerticalDivider(width: 1), Expanded(child: body)])
                : body,
          ),
        ),
      ),
    );
  }

  Widget sidebar(BuildContext c, {bool drawer = false}) {
    final t = Theme.of(c), cs = t.colorScheme;
    void nav(Fs f, String pp) {
      if (drawer) Navigator.pop(c);
      go(f, pp);
    }

    Widget hdr(String s) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(s, style: t.textTheme.labelLarge?.copyWith(color: cs.primary)));
    bool at(Fs f, String pp) => identical(fs, f) && path == pp;
    return Material(
      color: cs.surfaceContainerLow,
      child: SafeArea(
        child: ListView(children: [
          if (quick.isNotEmpty) hdr('Quick access'),
          for (final q in quick)
            ListTile(dense: true, leading: Icon(q.$2), title: Text(q.$1), selected: at(local, q.$3), onTap: () => nav(local, q.$3)),
          hdr('This device'),
          ListTile(
              dense: true,
              leading: Icon(Platform.isAndroid ? Icons.phone_android : Icons.computer),
              title: Text(Platform.isAndroid ? 'This phone' : 'This PC'),
              selected: at(local, ''),
              onTap: () => nav(local, '')),
          for (final d in drives) ListTile(dense: true, leading: const Icon(Icons.storage_outlined), title: Text(d), selected: at(local, d), onTap: () => nav(local, d)),
          hdr('Network'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 8, children: [
              ActionChip(
                  avatar: scanning ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.radar, size: 18),
                  label: Text(scanning ? 'Scanning' : 'Scan'),
                  onPressed: scanning ? null : doScan),
              ActionChip(avatar: const Icon(Icons.edit_location_alt_outlined, size: 18), label: const Text('By IP'), onPressed: byIp),
            ]),
          ),
          if (found.isEmpty && !scanning)
            Padding(padding: const EdgeInsets.all(16), child: Text('No devices found. Open Open Connect on another device on this Wi-Fi.', style: t.textTheme.bodySmall)),
          for (final pr in found)
            ListTile(
              dense: true,
              leading: Icon(remotes.containsKey(pr.base) ? Icons.lan : Icons.lan_outlined),
              title: Text(pr.name),
              subtitle: Text(pr.base.replaceFirst(RegExp(r'^https?://'), '')),
              selected: fs is RemoteFs && (fs as RemoteFs).peer.base == pr.base,
              onTap: () {
                if (drawer) Navigator.pop(c);
                connect(pr);
              },
            ),
        ]),
      ),
    );
  }

  List<(String, String)> crumbs() {
    final out = <(String, String)>[];
    var cur = path;
    while (cur.isNotEmpty) {
      final n = p.basename(cur);
      out.insert(0, (n.isEmpty ? cur : n, cur));
      cur = fs.parent(cur);
    }
    out.insert(0, (fs is LocalFs ? (Platform.isAndroid ? 'This phone' : 'This PC') : fs.label, ''));
    return out;
  }

  Widget toolbar(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
      child: Row(children: [
        if (!wide) IconButton(tooltip: 'Locations', icon: const Icon(Icons.menu), onPressed: () => scaffold.currentState?.openDrawer()),
        IconButton(tooltip: 'Back (Alt+Left)', icon: const Icon(Icons.arrow_back), onPressed: back.isEmpty ? null : goBack),
        IconButton(tooltip: 'Forward (Alt+Right)', icon: const Icon(Icons.arrow_forward), onPressed: fwd.isEmpty ? null : goFwd),
        IconButton(tooltip: 'Up (Backspace)', icon: const Icon(Icons.arrow_upward), onPressed: path.isEmpty ? null : goUp),
        IconButton(tooltip: 'Refresh (F5)', icon: const Icon(Icons.refresh), onPressed: _load),
        Expanded(
          child: Container(
            height: 40,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
            child: editing
                ? TextField(
                    controller: addrCtl,
                    autofocus: true,
                    decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.only(top: 10)),
                    onSubmitted: (v) async {
                      try {
                        await fs.ls(v.trim());
                        go(fs, v.trim());
                      } catch (_) {
                        if (mounted) toast(context, 'Cannot find "${v.trim()}"');
                      }
                    })
                : Row(children: [
                    Expanded(
                      child: ListView(scrollDirection: Axis.horizontal, children: [
                        for (final (i, cr) in crumbs().indexed) ...[
                          if (i > 0) const Icon(Icons.chevron_right, size: 18),
                          TextButton(
                              style: TextButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 8)),
                              onPressed: () => go(fs, cr.$2),
                              child: Text(cr.$1)),
                        ]
                      ]),
                    ),
                  ]),
          ),
        ),
        IconButton(
            tooltip: editing ? 'Close address bar' : 'Edit path',
            icon: Icon(editing ? Icons.close : Icons.edit_outlined),
            onPressed: () => setState(() {
                  editing = !editing;
                  addrCtl.text = path;
                })),
        SizedBox(
          width: wide ? 200 : 120,
          height: 40,
          child: TextField(
            controller: searchCtl,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onChanged: (v) => setState(() => filter = v.toLowerCase()),
          ),
        ),
      ]),
    );
  }

  Widget commandBar(BuildContext c) {
    final s = sel.isNotEmpty && canWrite;
    Widget ib(IconData i, String tip, VoidCallback? f) => IconButton(tooltip: tip, icon: Icon(i), onPressed: f);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        TextButton.icon(icon: const Icon(Icons.create_new_folder_outlined), label: const Text('New folder'), onPressed: canWrite ? newFolder : null),
        TextButton.icon(icon: const Icon(Icons.upload_file), label: const Text('Add files'), onPressed: canWrite ? addFiles : null),
        const SizedBox(height: 24, child: VerticalDivider()),
        ib(Icons.content_cut, 'Cut (Ctrl+X)', s ? () => copyCut(true) : null),
        ib(Icons.content_copy, 'Copy (Ctrl+C)', s ? () => copyCut(false) : null),
        ib(Icons.content_paste, _clip == null ? 'Paste (Ctrl+V)' : 'Paste ${_clip!.items.length} item(s) (Ctrl+V)', _clip != null && canWrite ? paste : null),
        ib(Icons.drive_file_rename_outline, 'Rename (F2)', sel.length == 1 && canWrite ? rename : null),
        ib(Icons.delete_outline, 'Delete (Del)', s ? delete : null),
        if (fs is RemoteFs) ib(Icons.download_outlined, 'Save to Downloads', sel.isNotEmpty ? saveToDownloads : null),
        const SizedBox(height: 24, child: VerticalDivider()),
        PopupMenuButton<String>(
          tooltip: 'Sort',
          icon: const Icon(Icons.sort),
          onSelected: (v) => setState(() {
            if (v == 'asc') {
              asc = !asc;
            } else {
              sortCol = v;
            }
          }),
          itemBuilder: (_) => [
            for (final (k, l) in [('name', 'Name'), ('date', 'Date modified'), ('type', 'Type'), ('size', 'Size')]) CheckedPopupMenuItem(value: k, checked: sortCol == k, child: Text(l)),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(value: 'asc', checked: asc, child: const Text('Ascending')),
          ],
        ),
        ib(grid ? Icons.view_list : Icons.grid_view, grid ? 'Details view' : 'Icon view', () => setState(() => grid = !grid)),
      ]),
    );
  }

  Widget content(BuildContext c) {
    if (loading && items == null) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return EmptyState(
          icon: Icons.error_outline,
          title: 'Cannot open this location',
          body: error!,
          actions: [
            FilledButton.icon(icon: const Icon(Icons.refresh), label: const Text('Try again'), onPressed: _load),
            if (path.isNotEmpty) OutlinedButton.icon(icon: const Icon(Icons.arrow_upward), label: const Text('Go up'), onPressed: goUp),
          ]);
    }
    final l = view;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => setState(() => sel = {}),
      onSecondaryTapDown: (d) => menuAt(d.globalPosition),
      onLongPressStart: Platform.isAndroid ? (d) => menuAt(d.globalPosition) : null,
      child: l.isEmpty
          ? EmptyState(
              icon: Icons.folder_open,
              title: filter.isEmpty ? 'This folder is empty' : 'No matches',
              body: filter.isEmpty ? (canWrite ? 'Use "Add files" or paste items here.' : 'Nothing to show here.') : 'Nothing in this folder matches "$filter".')
          : grid
              ? gridView(c, l)
              : detailsView(c, l),
    );
  }

  Widget header(BuildContext c, String label, String col, {double? width, TextAlign align = TextAlign.left}) {
    final on = sortCol == col;
    final child = InkWell(
      onTap: () => setState(() {
        if (on) {
          asc = !asc;
        } else {
          sortCol = col;
          asc = true;
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
          Text(label, style: Theme.of(c).textTheme.labelLarge),
          if (on) Icon(asc ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 18),
        ]),
      ),
    );
    return width == null ? Expanded(child: child) : SizedBox(width: width, child: child);
  }

  Widget detailsView(BuildContext c, List<Entry> l) => LayoutBuilder(builder: (c, box) {
        final full = box.maxWidth >= 640;
        return Column(children: [
          if (full)
            Padding(
              padding: const EdgeInsets.only(left: 48, right: 12),
              child: Row(children: [
                header(c, 'Name', 'name'),
                header(c, 'Date modified', 'date', width: 170),
                header(c, 'Type', 'type', width: 110),
                header(c, 'Size', 'size', width: 80, align: TextAlign.right),
              ]),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: l.length,
              itemExtent: full ? 40 : 60,
              itemBuilder: (_, i) => row(c, l[i], i, full),
            ),
          ),
        ]);
      });

  bool isCut(Entry e) => _clip != null && _clip!.cut && identical(_clip!.fs, fs) && _clip!.dir == path && _clip!.items.any((x) => x.name == e.name);

  Widget leadingIcon(Entry e, ColorScheme cs) => Icon(
        path.isEmpty ? Icons.storage : (e.isDir ? Icons.folder : fileIcon(e.name)),
        color: e.isDir ? cs.primary : cs.onSurfaceVariant,
        size: 24,
      );

  Widget row(BuildContext c, Entry e, int i, bool full) {
    final cs = Theme.of(c).colorScheme, s = sel.contains(e.name);
    final size = e.isDir ? '' : fmtSize(e.size);
    return Opacity(
      opacity: isCut(e) ? .5 : 1,
      child: Material(
        color: s ? cs.secondaryContainer : Colors.transparent,
        child: InkWell(
          onTap: () => tapEntry(e, i),
          onDoubleTap: Platform.isAndroid ? null : () => openEntry(e),
          onLongPress: Platform.isAndroid ? () => toggle(e, i) : null,
          onSecondaryTapDown: (d) {
            if (!sel.contains(e.name)) setState(() => sel = {e.name});
            menuAt(d.globalPosition, e: e);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              if (Platform.isAndroid && sel.isNotEmpty) Checkbox(value: s, onChanged: (_) => toggle(e, i)) else leadingIcon(e, cs),
              const SizedBox(width: 12),
              if (full) ...[
                Expanded(child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                SizedBox(width: 170, child: Text(fmtDate(e.modified), style: TextStyle(color: cs.onSurfaceVariant))),
                SizedBox(width: 110, child: Text(typeOf(e), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant))),
                SizedBox(width: 80, child: Text(size, textAlign: TextAlign.right, style: TextStyle(color: cs.onSurfaceVariant))),
              ] else
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text([e.isDir ? '' : size, fmtDate(e.modified)].where((x) => x.isNotEmpty).join('  ·  '),
                        style: Theme.of(c).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget gridView(BuildContext c, List<Entry> l) {
    final cs = Theme.of(c).colorScheme;
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 112, mainAxisExtent: 104),
      itemCount: l.length,
      itemBuilder: (_, i) {
        final e = l[i], s = sel.contains(e.name);
        return Opacity(
          opacity: isCut(e) ? .5 : 1,
          child: Material(
            color: s ? cs.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => tapEntry(e, i),
              onDoubleTap: Platform.isAndroid ? null : () => openEntry(e),
              onLongPress: Platform.isAndroid ? () => toggle(e, i) : null,
              onSecondaryTapDown: (d) {
                if (!sel.contains(e.name)) setState(() => sel = {e.name});
                menuAt(d.globalPosition, e: e);
              },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(children: [
                  Icon(path.isEmpty ? Icons.storage : (e.isDir ? Icons.folder : fileIcon(e.name)), size: 44, color: e.isDir ? cs.primary : cs.onSurfaceVariant),
                  const SizedBox(height: 6),
                  Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: Theme.of(c).textTheme.bodySmall),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget statusBar(BuildContext c) {
    final cs = Theme.of(c).colorScheme, l = view;
    final selSize = selected.fold<int>(0, (a, e) => a + e.size);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (busy != null) const LinearProgressIndicator(),
      Container(
        width: double.infinity,
        color: cs.surfaceContainerLow,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(
          busy != null
              ? '$busy${done > 0 ? '  ${fmtSize(done)}' : ''}'
              : '${l.length} item${l.length == 1 ? '' : 's'}${sel.isNotEmpty ? '  ·  ${sel.length} selected${selSize > 0 ? ' (${fmtSize(selSize)})' : ''}' : ''}',
          style: Theme.of(c).textTheme.bodySmall,
        ),
      ),
    ]);
  }
}
