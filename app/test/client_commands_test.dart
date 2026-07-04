import 'package:flutter_test/flutter_test.dart';
import 'package:pino/ui/composer/client_commands.dart';

void main() {
  group('client command registry', () {
    ClientCommand cmd(String name) =>
        clientCommands.firstWhere((c) => c.name == name);

    test(
      '/compact, /thinking, and /model are registered as builtin palette commands',
      () {
        // These back the pi built-ins that get_commands does NOT return, so they
        // must be present in the client registry to show in the slash palette
        // and to be intercepted by handleClientCommand (not sent to the agent).
        for (final name in ['compact', 'thinking', 'model']) {
          final c = cmd(name);
          expect(c.description, isNotEmpty);
          expect(c.toSlashCmd().source, 'builtin');
          expect(c.toSlashCmd().name, name);
        }
      },
    );

    test('command names are unique', () {
      final names = clientCommands.map((c) => c.name).toList();
      expect(names.toSet().length, names.length);
    });
  });
}
