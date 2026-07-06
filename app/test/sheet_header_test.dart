import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/ui/widgets/sheet_header.dart';

void main() {
  testWidgets('renders the title and a close button', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SheetHeader(title: 'Model')),
      ),
    );

    expect(find.text('Model'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('close button pops the sheet without a selection', (
    tester,
  ) async {
    String? result = 'unset';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showModalBottomSheet<String>(
                  context: context,
                  builder: (_) => const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [SheetHeader(title: 'Pick one')],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Pick one'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Pick one'), findsNothing); // sheet dismissed
    expect(result, isNull); // no selection returned
  });
}
