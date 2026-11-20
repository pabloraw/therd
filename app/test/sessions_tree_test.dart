import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/data/app_state.dart';
import 'package:therd/src/ui/sessions_screen.dart';
import 'package:therd/src/ui/theme.dart';
import 'package:therd_protocol/protocol.dart';

SessionInfo ses(
  String id,
  String? ws, {
  int seq = 0,
  SessionStatus st = SessionStatus.idle,
}) => SessionInfo(
  sessionId: id,
  workspaceId: ws,
  title: id,
  lastSeq: seq,
  status: st,
);

void main() {
  test('worktrees anidados bajo su checkout y sin workspaces vacíos', () {
    const ws = [
      WorkspaceInfo(workspaceId: 'w2', number: 2, label: 'app', branch: 'main'),
      WorkspaceInfo(workspaceId: 'w1', number: 1, label: 'home'),
      WorkspaceInfo(
        workspaceId: 'w9',
        number: 9,
        label: 'Umbrales',
        isLinkedWorktree: true,
        parentWorkspaceId: 'w2',
      ),
      WorkspaceInfo(workspaceId: 'w5', number: 5, label: 'vacío'),
    ];
    final tree = buildTree(ws, [
      ses('a', 'w2'),
      ses('b', 'w9'),
      ses('c', 'w1'),
      ses('x', 'w?'),
    ]);
    expect([for (final n in tree) n.workspace?.label], ['home', 'app', null]);
    expect(tree[1].children.single.workspace!.label, 'Umbrales');
    expect(tree.last.sessions.single.sessionId, 'x');
  });

  test('sin leer: lo nuevo para el móvil cuenta como leído y luego avanza', () {
    var s = reduce(
      const AppState(),
      HelloMessage(sessions: [ses('a', 'w', seq: 10)]),
    );
    expect(s.isUnread(s.session('a')!), isFalse);
    s = reduce(
      s,
      const StatusMessage(
        sessionId: 'a',
        status: SessionStatus.working,
        lastSeq: 12,
      ),
    );
    s = reduce(
      s,
      const StatusMessage(
        sessionId: 'a',
        status: SessionStatus.idle,
        lastSeq: 15,
      ),
    );
    final a = s.session('a')!;
    expect(s.isUnread(a), isTrue);
    expect(viewStatus(a.status, unread: true), ViewStatus.unread);
    // Si el daemon reinicia y el seq baja, lo visto baja con él.
    s = reduce(s, SessionsMessage(sessions: [ses('a', 'w', seq: 3)]));
    expect(s.seen['a'], 3);
  });

  test('sin leer: lo visto en el PC también cuenta', () {
    var s = reduce(
      const AppState(),
      HelloMessage(sessions: [ses('a', 'w', seq: 10)]),
    );
    s = reduce(
      s,
      const StatusMessage(
        sessionId: 'a',
        status: SessionStatus.idle,
        lastSeq: 15,
      ),
    );
    expect(s.isUnread(s.session('a')!), isTrue);
    s = reduce(s, const SeenMessage(sessionId: 'a', seq: 14));
    expect(s.isUnread(s.session('a')!), isTrue);
    s = reduce(s, const SeenMessage(sessionId: 'a', seq: 15));
    expect(s.isUnread(s.session('a')!), isFalse);
    // Un aviso viejo no hace retroceder.
    s = reduce(s, const SeenMessage(sessionId: 'a', seq: 3));
    expect(s.session('a')!.seenSeq, 15);
  });

  test('pendiente o bloqueado gana a todo', () {
    expect(
      viewStatus(SessionStatus.idle, unread: true, hasPending: true),
      ViewStatus.blocked,
    );
    expect(viewStatus(SessionStatus.idle), ViewStatus.read);
  });
}
