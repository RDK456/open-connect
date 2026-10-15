// In-app video player: the folder's videos form a playlist (next/previous, auto-advance),
// played from disk or streamed from another device.
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const videoExts = {'.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.m4v', '.flv', '.3gp', '.ts', '.mpg', '.mpeg'};

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.items, required this.index});
  final List<(String, Media)> items; // (file name, source) in folder order
  final int index;
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final player = Player();
  late final controller = VideoController(player);
  late String title = widget.items[widget.index].$1;
  String? error; // last playback error, shown over the video

  @override
  void initState() {
    super.initState();
    player.open(Playlist([for (final i in widget.items) i.$2], index: widget.index));
    player.stream.error.listen((e) {
      if (mounted) setState(() => error = e);
    });
    player.stream.playlist.listen((pl) {
      if (mounted && pl.index < widget.items.length) setState(() => title = widget.items[pl.index].$1);
    });
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(title, overflow: TextOverflow.ellipsis)),
        body: Stack(children: [
          Video(controller: controller),
          if (error != null)
            Positioned(left: 16, right: 16, bottom: 96, child: Text(error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center)),
        ]),
      );
}
