import 'dart:async';

import 'package:therd/src/core/connection_config.dart';
import 'package:therd/src/data/therd_client.dart';
import 'package:therd_protocol/protocol.dart';

/// Cliente falso: guarda lo enviado y permite emitir mensajes del servidor.
class FakeClient implements TherdClient {
  final sent = <ClientMessage>[];
  final _messages = StreamController<ServerMessage>.broadcast();
  final _link = StreamController<LinkStatus>.broadcast();
  LinkStatus _current = const LinkStatus(LinkState.disconnected);
  int connects = 0;
  String? probeResult;

  @override
  Stream<ServerMessage> get messages => _messages.stream;

  @override
  Stream<LinkStatus> get link => _link.stream;

  @override
  LinkStatus get current => _current;

  void emit(ServerMessage m) => _messages.add(m);

  void setLink(LinkStatus s) {
    _current = s;
    _link.add(s);
  }

  @override
  void connect(ConnectionConfig config) {
    connects++;
    setLink(const LinkStatus(LinkState.connected));
  }

  ConnectionConfig? updated;

  @override
  void updateConfig(ConnectionConfig config) => updated = config;

  @override
  void disconnect() => setLink(const LinkStatus(LinkState.disconnected));

  @override
  void send(ClientMessage message) => sent.add(message);

  @override
  Future<String?> probe(ConnectionConfig config) async => probeResult;

  @override
  void dispose() {}

  List<T> sentOf<T extends ClientMessage>() => sent.whereType<T>().toList();
}

DateTime t(int n) => DateTime.utc(2026, 1, 1, 0, 0, n);

UserPromptItem userItem(
  int seq,
  String text, {
  String? id,
  String sid = 's1',
}) => UserPromptItem(
  id: id ?? 'u$seq',
  sessionId: sid,
  seq: seq,
  timestamp: t(seq),
  text: text,
);

AssistantTextItem asstItem(
  int seq,
  String text, {
  String? id,
  String sid = 's1',
}) => AssistantTextItem(
  id: id ?? 'a$seq',
  sessionId: sid,
  seq: seq,
  timestamp: t(seq),
  text: text,
);

Pending permissionPending({
  String id = 'r1',
  String sid = 's1',
  List<Map<String, dynamic>> suggestions = const [],
  String tool = 'Bash',
  Map<String, dynamic> input = const {'command': 'git push origin main'},
}) => Pending(
  requestId: id,
  sessionId: sid,
  kind: PendingKind.permission,
  toolName: tool,
  toolInput: input,
  suggestions: suggestions,
  createdAt: t(1),
);
