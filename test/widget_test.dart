import 'package:flutter_test/flutter_test.dart';
import 'package:panjmap_capture/main.dart' as app;

void main() {
  testWidgets('Missing API root gives actionable configuration guidance', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    expect(find.textContaining('API_BASE_URL'), findsOneWidget);
  });
}
