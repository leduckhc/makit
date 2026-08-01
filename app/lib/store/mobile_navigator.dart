/// Mobile's single message-navigator control (SPEC-34 §Surface matrix).
///
/// The desktop preference system does not reach mobile: `PreferencesController`
/// persists under the key `desktop_settings_overrides` and is used nowhere
/// outside `lib/desktop/`, while mobile's settings screen is a hand-built list.
/// Porting it is a separate spec.
///
/// So mobile gets **one switch**, not the picker — success criterion 4 ("a user
/// who finds it noisy can turn it off") is not negotiable.
///
/// On means **outline mode**, and the reasoning is worth keeping: the rail and
/// breadcrumb need hover, and the other two are built around a pointer's
/// precision even though both technically work by touch. The scrubber asks a
/// thumb to land on one of N markers down a 22pt edge strip — at 40 prompts on a
/// phone those are ~18pt apart, it competes with the iOS edge-swipe-back
/// gesture, and the thumb covers the very preview card it is driving. Outline is
/// a tap, it needs no precision, and collapsing the agent away is *more*
/// valuable on a small screen, not less: the whole conversation becomes a
/// readable table of contents.
///
/// Persistence mirrors [RecentModelsController] (SPEC-31): a single
/// SharedPreferences key, read at startup, tolerant of a missing value.
library;

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/session/navigator/navigator_style.dart';

/// SharedPreferences key holding mobile's navigator on/off flag.
const String kMobileNavigatorKey = 'chat.navigator.mobileEnabled';

/// Whether mobile shows a message navigator. Defaults to on.
class MobileNavigatorController extends StateNotifier<bool> {
  /// Creates a controller over [prefs], seeded with [initial].
  MobileNavigatorController(this._prefs, bool initial) : super(initial);

  /// A non-persisting controller, for the provider default and for tests.
  MobileNavigatorController.ephemeral() : this(null, true);

  /// Reads the stored flag, defaulting to on when absent or corrupt.
  ///
  /// Reads untyped: `getBool` *throws* a cast error when the stored value is not
  /// a bool, which would take the whole app down on startup over one junk key.
  factory MobileNavigatorController.load(SharedPreferences prefs) {
    final stored = prefs.get(kMobileNavigatorKey);
    return MobileNavigatorController(prefs, stored is bool ? stored : true);
  }

  final SharedPreferences? _prefs;

  /// The style mobile should render for the current flag.
  MessageNavigatorStyle get style =>
      state ? MessageNavigatorStyle.outline : MessageNavigatorStyle.off;

  /// Turns the navigator on or off, persisting the choice.
  Future<void> set(bool enabled) async {
    if (enabled == state) return;
    state = enabled;
    await _prefs?.setBool(kMobileNavigatorKey, enabled);
  }
}

/// The active mobile navigator flag. `main.dart` overrides this with a
/// [SharedPreferences]-backed controller.
final mobileNavigatorProvider =
    StateNotifierProvider<MobileNavigatorController, bool>(
      (ref) => MobileNavigatorController.ephemeral(),
    );
