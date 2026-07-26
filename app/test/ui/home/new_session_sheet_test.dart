import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/models.dart';
import 'package:makit/ui/home/new_session_sheet.dart';

AgentDescriptor _agent(
  String id, {
  String? label,
  String transport = 'acp',
  bool available = true,
  List<SessionConfigOption> configOptions = const [],
}) => AgentDescriptor(
  id: id,
  label: label ?? id,
  transport: transport,
  available: available,
  configOptions: configOptions,
);

SessionConfigOption _selectOption(
  String id,
  String name, {
  required String currentValue,
  required List<ConfigOptionValue> options,
  String? category,
}) => SessionConfigOption(
  id: id,
  name: name,
  category: category,
  type: ConfigOptionType.select,
  currentValue: currentValue,
  options: options,
);

SessionConfigOption _boolOption(String id, String name, {bool value = false}) =>
    SessionConfigOption(
      id: id,
      name: name,
      type: ConfigOptionType.boolean,
      currentValue: value,
    );

Worktree _wt(String path, {String? branch, bool isPrimary = false}) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: isPrimary,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: const [],
);

OpenPr _pr(int number, String title, String head) => OpenPr(
  number: number,
  title: title,
  headRefName: head,
  isDraft: false,
  url: '',
);

void main() {
  testWidgets('shows worktree source toggle, harness cards, and config rows', (
    tester,
  ) async {
    final agents = [
      _agent(
        'pi',
        transport: 'acp',
        configOptions: [
          _selectOption(
            'model',
            'Model',
            category: 'model',
            currentValue: 'gpt-5',
            options: const [
              ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
              ConfigOptionValue(value: 'sonnet', name: 'Sonnet'),
            ],
          ),
        ],
      ),
      _agent('codex', transport: 'native'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionSheet(
            agents: agents,
            branches: const ['main'],
            worktrees: [_wt('/tmp/demo', branch: 'main', isPrimary: true)],
            openPrs: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Worktree source toggle segments.
    expect(find.text('Existing'), findsOneWidget);
    expect(find.text('New branch'), findsOneWidget);
    expect(find.text('From PR'), findsOneWidget);

    // Harness cards.
    expect(find.text('pi'), findsOneWidget);
    expect(find.text('codex'), findsOneWidget);

    // Config row for the selected harness (pi) with its current value.
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('GPT-5'), findsOneWidget);
  });

  testWidgets('picking a config value updates the row', (tester) async {
    final agents = [
      _agent(
        'pi',
        configOptions: [
          _selectOption(
            'model',
            'Model',
            category: 'model',
            currentValue: 'gpt-5',
            options: const [
              ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
              ConfigOptionValue(value: 'sonnet', name: 'Sonnet'),
            ],
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionSheet(
            agents: agents,
            branches: const ['main'],
            worktrees: const [],
            openPrs: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GPT-5'), findsOneWidget);

    // Open the picker and choose Sonnet.
    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonnet').last);
    await tester.pumpAndSettle();

    // The row now shows the new value.
    expect(find.text('Sonnet'), findsOneWidget);
    expect(find.text('GPT-5'), findsNothing);
  });

  testWidgets('boolean config option renders a switch and toggles', (
    tester,
  ) async {
    final agents = [
      _agent('pi', configOptions: [_boolOption('yolo', 'Auto-approve')]),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionSheet(
            agents: agents,
            branches: const ['main'],
            worktrees: const [],
            openPrs: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Auto-approve'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);

    Switch sw() => tester.widget<Switch>(find.byType(Switch));
    expect(sw().value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(sw().value, isTrue);
  });

  testWidgets('empty catalog renders no config rows', (tester) async {
    final agents = [_agent('codex', transport: 'native')];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionSheet(
            agents: agents,
            branches: const ['main'],
            worktrees: const [],
            openPrs: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsNothing);
    // No config-option label rows are present.
    expect(find.byType(ConfigRow), findsNothing);
  });

  testWidgets('Start returns a choice carrying the config picks', (
    tester,
  ) async {
    NewSessionChoice? choice;
    final agents = [
      _agent(
        'pi',
        configOptions: [
          _selectOption(
            'model',
            'Model',
            category: 'model',
            currentValue: 'gpt-5',
            options: const [
              ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
              ConfigOptionValue(value: 'sonnet', name: 'Sonnet'),
            ],
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                choice = await showModalBottomSheet<NewSessionChoice>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => NewSessionSheet(
                    agents: agents,
                    branches: const ['main'],
                    worktrees: const [],
                    openPrs: const [],
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

    // Change the model, then Start.
    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonnet').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(choice, isNotNull);
    expect(choice!.agent, 'pi');
    expect(choice!.configOptions, hasLength(1));
    expect(choice!.configOptions.single.id, 'model');
    expect(choice!.configOptions.single.value, 'sonnet');
  });

  testWidgets('From PR source carries the chosen PR number', (tester) async {
    NewSessionChoice? choice;
    final agents = [_agent('pi')];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                choice = await showModalBottomSheet<NewSessionChoice>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => NewSessionSheet(
                    agents: agents,
                    branches: const ['main'],
                    worktrees: const [],
                    openPrs: [_pr(42, 'Add login', 'feat/login')],
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

    await tester.tap(find.text('From PR'));
    await tester.pumpAndSettle();

    // Open the PR picker, then choose the PR.
    await tester.tap(find.text('Choose a PR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add login'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(choice, isNotNull);
    expect(choice!.source, WorktreeSource.fromPr);
    expect(choice!.prNumber, 42);
  });

  testWidgets('Existing source carries the chosen worktree path', (
    tester,
  ) async {
    NewSessionChoice? choice;
    final agents = [_agent('pi')];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                choice = await showModalBottomSheet<NewSessionChoice>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => NewSessionSheet(
                    agents: agents,
                    branches: const ['main'],
                    worktrees: [
                      _wt('/tmp/demo', branch: 'main', isPrimary: true),
                      _wt('/tmp/feat', branch: 'feat/x'),
                    ],
                    openPrs: const [],
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

    await tester.tap(find.text('Existing'));
    await tester.pumpAndSettle();

    // Open the worktree picker (defaulted to the primary 'main' worktree) and
    // choose the feature-branch worktree.
    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('feat/x'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(choice, isNotNull);
    expect(choice!.source, WorktreeSource.existing);
    expect(choice!.worktreePath, '/tmp/feat');
  });
}
