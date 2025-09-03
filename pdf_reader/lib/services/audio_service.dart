import 'package:audioplayers/audioplayers.dart';
import 'dart:async';

class AudioService {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController = StreamController<Duration>.broadcast();
  final StreamController<PlayerState> _stateController = StreamController<PlayerState>.broadcast();

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<PlayerState> get stateStream => _stateController.stream;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  PlayerState _state = PlayerState.stopped;

  Duration get position => _position;
  Duration get duration => _duration;
  PlayerState get state => _state;

  AudioService() {
    _audioPlayer.onDurationChanged.listen((d) {
      _duration = d;
      _durationController.add(d);
    });

    _audioPlayer.onPositionChanged.listen((p) {
      _position = p;
      _positionController.add(p);
    });

    _audioPlayer.onPlayerStateChanged.listen((s) {
      _state = s;
      _stateController.add(s);
    });
  }

  Future<void> play(Source source) async {
    await _audioPlayer.play(source);
  }

  Future<void> pause() async {
    await _audioPlayer.pause();
  }

  Future<void> resume() async {
    await _audioPlayer.resume();
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
  }

  Future<void> seek(Duration position) async {
    await _audioPlayer.seek(position);
  }

  Future<void> togglePlayPause() async {
    if (_state == PlayerState.playing) {
      await pause();
    } else {
      await resume();
    }
  }

  void dispose() {
    _audioPlayer.dispose();
    _positionController.close();
    _durationController.close();
    _stateController.close();
  }
}