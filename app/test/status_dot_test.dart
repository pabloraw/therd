import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:therd/src/ui/theme.dart';

Widget _dot(ViewStatus s, {bool still = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: still),
  child: Center(child: StatusDot(s)),
);

void main() {
  testWidgets('al aparecer no se anima', (tester) async {
    await tester.pumpWidget(_dot(ViewStatus.blocked));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('al cambiar de estado se anima y acaba en reposo', (
    tester,
  ) async {
    await tester.pumpWidget(_dot(ViewStatus.read));
    await tester.pumpWidget(_dot(ViewStatus.blocked));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('con las animaciones del sistema desactivadas, salta', (
    tester,
  ) async {
    await tester.pumpWidget(_dot(ViewStatus.read, still: true));
    await tester.pumpWidget(_dot(ViewStatus.blocked, still: true));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
