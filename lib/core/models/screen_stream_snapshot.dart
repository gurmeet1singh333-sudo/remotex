import 'screen_frame.dart';
import 'remote_cursor_position.dart';
import 'screen_stream_state.dart';

class ScreenStreamSnapshot {
  const ScreenStreamSnapshot({
    required this.state,
    this.frame,
    this.cursor,
    this.dimensions,
    this.framesPerSecond = 0,
    this.error,
  });

  final ScreenStreamState state;
  final ScreenFrame? frame;
  final RemoteCursorPosition? cursor;
  final String? dimensions;
  final double framesPerSecond;
  final String? error;
}
