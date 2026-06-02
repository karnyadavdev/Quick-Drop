import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/main.dart';

void main() {
  testWidgets('Dashboard smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const QuickDropApp());
    expect(find.text('Quick Drop'), findsOneWidget);
  });
}
