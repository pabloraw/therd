import 'package:therd_protocol/protocol.dart';

/// Evento de hook de Claude Code (cuerpo POST) más la cabecera de pane.
class HookEvent {
  HookEvent({
    required this.name,
    required this.sessionId,
    this.transcriptPath,
    this.cwd,
    this.permissionMode,
    this.paneId,
    this.toolName,
    this.toolInput = const {},
    this.toolUseId,
    this.agentId,
    this.raw = const {},
  });

  factory HookEvent.fromJson(Map<String, dynamic> j, {String? paneId}) =>
      HookEvent(
        name: j['hook_event_name'] as String? ?? '',
        sessionId: j['session_id'] as String? ?? '',
        transcriptPath: j['transcript_path'] as String?,
        cwd: j['cwd'] as String?,
        permissionMode: j['permission_mode'] as String?,
        paneId: (paneId == null || paneId.isEmpty) ? null : paneId,
        toolName: j['tool_name'] as String?,
        toolInput: asMap(j['tool_input']),
        toolUseId: j['tool_use_id'] as String?,
        agentId: j['agent_id'] as String?,
        raw: j,
      );

  final String name;
  final String sessionId;
  final String? transcriptPath;
  final String? cwd;
  final String? permissionMode;
  final String? paneId;
  final String? toolName;
  final Map<String, dynamic> toolInput;
  final String? toolUseId;

  /// Presente cuando el evento viene de un subagente.
  final String? agentId;
  final Map<String, dynamic> raw;

  bool get isSubagent => agentId != null && agentId!.isNotEmpty;

  /// ¿Es un evento que puede retenerse esperando a la app?
  bool get isHoldable =>
      sessionId.isNotEmpty &&
      ((name == 'PermissionRequest' && toolName != 'AskUserQuestion') ||
          (name == 'PreToolUse' && toolName == 'AskUserQuestion'));
}
