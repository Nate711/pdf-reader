import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

class AudioPlayerControls extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final PlayerState state;
  final VoidCallback? onTogglePlayPause;
  final ValueChanged<double>? onSeek;

  const AudioPlayerControls({
    super.key,
    required this.position,
    required this.duration,
    required this.state,
    this.onTogglePlayPause,
    this.onSeek,
  });

  String _formatTime(Duration d) {
    final totalSecs = d.inSeconds;
    final m = (totalSecs ~/ 60).toString().padLeft(1, '0');
    final s = (totalSecs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: state == PlayerState.playing ? 'Pause' : 'Play',
          onPressed: (duration > Duration.zero) ? onTogglePlayPause : null,
          icon: Icon(
            state == PlayerState.playing ? Icons.pause : Icons.play_arrow,
          ),
        ),
        Expanded(
          child: Slider(
            value: position.inMilliseconds
                .clamp(0, duration.inMilliseconds)
                .toDouble(),
            min: 0,
            max: (duration.inMilliseconds == 0
                    ? 1
                    : duration.inMilliseconds)
                .toDouble(),
            onChanged: (duration > Duration.zero && onSeek != null)
                ? (v) => onSeek!(v / 1000.0)
                : null,
          ),
        ),
        SizedBox(
          width: 110,
          child: Text(
            '${_formatTime(position)} / ${_formatTime(duration)}',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}