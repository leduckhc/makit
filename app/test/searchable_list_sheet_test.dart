import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/widgets/searchable_list_sheet.dart';

const _items = ['Apple', 'Banana', 'Cherry', 'Avocado'];

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showSearchableListSheet<String>(
                context: context,
                title: 'Pick fruit',
                items: _items,
                matches: (s, q) => s.toLowerCase().contains(q.toLowerCase()),
                tileBuilder: (_, s) => ListTile(
                  title: Text(s),
                  onTap: () => Navigator.of(context).pop(s),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tapping an item returns it', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showSearchableListSheet<String>(
                    context: context,
                    title: 'Pick fruit',
                    items: _items,
                    matches: (s, q) =>
                        s.toLowerCase().contains(q.toLowerCase()),
                    tileBuilder: (_, s) => ListTile(
                      title: Text(s),
                      onTap: () => Navigator.of(context).pop(s),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cherry'));
    await tester.pumpAndSettle();

    expect(result, 'Cherry');
  });

  testWidgets('search filters the list', (tester) async {
    await _openSheet(tester);

    // Search button is present next to close.
    expect(find.byIcon(Icons.search), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    // "ch" only matches Cherry.
    await tester.enterText(find.byType(TextField), 'ch');
    await tester.pumpAndSettle();

    expect(find.text('Cherry'), findsOneWidget);
    expect(find.text('Apple'), findsNothing);
    expect(find.text('Banana'), findsNothing);
    expect(find.text('Avocado'), findsNothing);
  });

  testWidgets('no-match query shows the empty hint', (tester) async {
    await _openSheet(tester);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.textContaining('No matches'), findsOneWidget);
    for (final s in _items) {
      expect(find.text(s), findsNothing);
    }
  });

  testWidgets('empty list shows emptyState and hides search', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showSearchableListSheet<String>(
                  context: context,
                  title: 'Nothing here',
                  items: const [],
                  matches: (_, _) => true,
                  emptyState: const Text('No past sessions.'),
                  tileBuilder: (_, s) => ListTile(title: Text(s)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('No past sessions.'), findsOneWidget);
    // No search toggle when there is nothing to search.
    expect(find.byIcon(Icons.search), findsNothing);
  });

  testWidgets('sheet does not exceed the height cap', (tester) async {
    // Long list that would otherwise fill the screen.
    final many = [for (var i = 0; i < 60; i++) 'item $i'];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showSearchableListSheet<String>(
                  context: context,
                  title: 'Many',
                  items: many,
                  matches: (_, _) => true,
                  tileBuilder: (_, s) => ListTile(title: Text(s)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheet = tester.getRect(find.byType(BottomSheet));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    // The sheet must not take the full screen — a peek of background stays
    // visible above it so it reads as dismissible.
    expect(sheet.height, lessThan(screen.height));
    expect(sheet.top, greaterThan(0));
  });
}
