import 'package:flutter/services.dart';

/// Háptica de therd: pocos golpes y siempre con significado, para que cada
/// uno se reconozca en la mano sin mirar.
///
/// En Android van por `performHapticFeedback`, así que respetan el ajuste de
/// vibración táctil del sistema.
abstract final class Haptics {
  /// Algo sale del móvil hacia Claude: enviar, aprobar, contestar.
  static void send() => HapticFeedback.mediumImpact();

  /// Un no o un alto: denegar, rechazar un plan, Stop.
  static void stop() => HapticFeedback.heavyImpact();

  /// Cambio de selección: filtros, opciones de una pregunta, micro.
  static void select() => HapticFeedback.selectionClick();

  /// Claude pide algo con el chat abierto: llega un permiso, pregunta o plan.
  static void attention() => HapticFeedback.heavyImpact();

  /// Claude termina su turno con el chat abierto.
  static void done() => HapticFeedback.lightImpact();
}
