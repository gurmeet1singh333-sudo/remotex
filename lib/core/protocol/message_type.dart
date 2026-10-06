import 'authorization_scope.dart';

enum MessageType {
  hello('hello', AuthorizationScope.session, 2048),
  ping('ping', AuthorizationScope.session, 2048),
  pong('pong', AuthorizationScope.session, 2048),
  disconnect('disconnect', AuthorizationScope.session, 2048),
  sessionReady('session_ready', AuthorizationScope.session, 2048),
  sessionError('session_error', AuthorizationScope.session, 2048),
  mouseMove('mouse_move', AuthorizationScope.mouseControl, 2048),
  mouseButton('mouse_button', AuthorizationScope.mouseControl, 2048),
  mouseScroll('mouse_scroll', AuthorizationScope.mouseControl, 2048),
  keyboardKey('keyboard_key', AuthorizationScope.keyboardControl, 2048),
  authorizationUpdate('authorization_update', AuthorizationScope.session, 2048),
  screenStart('screen_start', AuthorizationScope.session, 2048),
  screenStop('screen_stop', AuthorizationScope.session, 2048),
  screenFrame('screen_frame', AuthorizationScope.screenView, 8192),
  cursorPosition('cursor_position', AuthorizationScope.screenView, 2048),
  clipboardRequest('clipboard_request', AuthorizationScope.clipboard, 2048),
  clipboardData('clipboard_data', AuthorizationScope.clipboard, 8192),
  fileRequest('file_request', AuthorizationScope.fileTransfer, 2048),
  fileChunk('file_chunk', AuthorizationScope.fileTransfer, 8192),
  fileComplete('file_complete', AuthorizationScope.fileTransfer, 2048),
  fileCancel('file_cancel', AuthorizationScope.fileTransfer, 2048);

  const MessageType(
    this.wireName,
    this.requiredScope,
    this.maximumPayloadBytes,
  );

  final String wireName;
  final AuthorizationScope requiredScope;
  final int maximumPayloadBytes;

  static MessageType? fromWireName(Object? value) {
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }

  bool get isRequest => const {
    MessageType.hello,
    MessageType.ping,
    MessageType.screenStart,
    MessageType.screenStop,
    MessageType.clipboardRequest,
    MessageType.fileRequest,
  }.contains(this);

  bool get isResponse => const {
    MessageType.pong,
    MessageType.sessionReady,
    MessageType.sessionError,
    MessageType.clipboardData,
    MessageType.fileChunk,
    MessageType.fileComplete,
  }.contains(this);
}
