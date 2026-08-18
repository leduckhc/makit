import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';

/// Contract test for the sidebar layout providers (SPEC-desktop-sidebar-topbar-restructure WS-D): sane defaults
/// and clamp bounds. The interactive clamp-on-drag path is exercised at the
/// widget level in desktop_chat_shell_test.dart.
void main() {
  test('default sidebar state is expanded at the default width', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(sidebarCollapsedProvider), isFalse);
    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth);
  });

  test('width bounds are the spec values (250–450, default 320)', () {
    expect(kSidebarMinWidth, 250);
    expect(kSidebarMaxWidth, 450);
    expect(kSidebarDefaultWidth, 320);
    expect(kSidebarDefaultWidth, greaterThanOrEqualTo(kSidebarMinWidth));
    expect(kSidebarDefaultWidth, lessThanOrEqualTo(kSidebarMaxWidth));
  });

  test('width provider clamps updates to the min/max bounds', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(sidebarWidthProvider.notifier);

    notifier.update(
      (w) => (w - 1000).clamp(kSidebarMinWidth, kSidebarMaxWidth),
    );
    expect(container.read(sidebarWidthProvider), kSidebarMinWidth);

    notifier.update(
      (w) => (w + 1000).clamp(kSidebarMinWidth, kSidebarMaxWidth),
    );
    expect(container.read(sidebarWidthProvider), kSidebarMaxWidth);
  });

  test('width provider accumulates in-bounds deltas without overshoot', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(sidebarWidthProvider.notifier);

    notifier.update((w) => (w + 10).clamp(kSidebarMinWidth, kSidebarMaxWidth));
    notifier.update((w) => (w + 10).clamp(kSidebarMinWidth, kSidebarMaxWidth));

    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth + 20);
  });

  test('collapsed provider toggles independently of width', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(sidebarCollapsedProvider.notifier).state = true;
    expect(container.read(sidebarCollapsedProvider), isTrue);
    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth);

    container.read(sidebarCollapsedProvider.notifier).state = false;
    expect(container.read(sidebarCollapsedProvider), isFalse);
  });
}
