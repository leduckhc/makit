import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The trackpad and wheel half of SPEC-pane-zoom (D5).
///
/// The keyboard steps a ladder; these two inputs are continuous, so they set a
/// value between the stops and let the keyboard snap back to one later.

/// True while a modifier that means "zoom, do not scroll" is down.
///
/// `⌘` is the macOS convention and `⌃` is the convention everywhere else. Both
/// are accepted, because a user with an external keyboard reaches for either.
/// Shift and alt are deliberately excluded: they already carry other meanings
/// over a scroll (shift scrolls horizontally).
///
/// Read at event time rather than cached, so nothing has to listen to the
/// keyboard and no rebuild is needed when the modifier goes down.
bool get zoomModifierHeld {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isMetaPressed || keyboard.isControlPressed;
}

/// Scroll physics that refuse a user offset while [zoomModifierHeld].
///
/// This is what lets the pane win the wheel event. `Scrollable` registers with
/// the [PointerSignalResolver], the resolver keeps the **first** registrant, and
/// `GestureBinding` dispatches deepest-first — so the transcript's `Scrollable`
/// would always beat the pane's `Listener`, and the pane would zoom *and*
/// scroll. `Scrollable` checks `shouldAcceptUserOffset` before it registers, so
/// refusing here makes it return and leaves the event to the pane.
///
/// Browsers behave the same way: with the modifier held, the wheel zooms and
/// never scrolls.
class ZoomAwareScrollPhysics extends ScrollPhysics {
  /// Wraps [parent], which keeps deciding everything except the zoom gate.
  const ZoomAwareScrollPhysics({super.parent});

  @override
  ZoomAwareScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ZoomAwareScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      !zoomModifierHeld && super.shouldAcceptUserOffset(position);
}

/// Turns a trackpad pinch and a modifier+wheel into zoom for one pane.
///
/// [onNudge] receives a *relative* factor, so the caller multiplies its current
/// zoom by it. [onFocus] runs first, because the pane the user gestures over
/// must become the active pane — zoom always acts on the active pane, and a
/// pinch does not press a button that would otherwise focus it.
class PaneZoomGestures extends StatefulWidget {
  /// Wraps [child] with the pinch and wheel handlers.
  const PaneZoomGestures({
    required this.onNudge,
    required this.onFocus,
    required this.child,
    super.key,
  });

  /// Multiplies the pane's zoom by the given factor.
  final void Function(double factor) onNudge;

  /// Makes this pane the active pane.
  final VoidCallback onFocus;

  /// The pane's content.
  final Widget child;

  @override
  State<PaneZoomGestures> createState() => _PaneZoomGesturesState();
}

class _PaneZoomGesturesState extends State<PaneZoomGestures> {
  /// The cumulative scale reported by the live pinch, or 1 between gestures.
  ///
  /// `PointerPanZoomUpdateEvent.scale` counts from the start of the gesture, so
  /// each frame's *relative* factor is the ratio against the previous frame.
  double _lastPinchScale = 1;

  /// One wheel notch. Smaller than a ladder step, so a wheel feels smooth while
  /// the keyboard stays predictable.
  static const double _wheelFactor = 1.1;

  void _onPanZoomStart(PointerPanZoomStartEvent event) => _lastPinchScale = 1;

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final factor = event.scale / _lastPinchScale;
    _lastPinchScale = event.scale;
    // A two-finger pan reports scale 1 throughout, so scrolling never zooms.
    if (factor == 1) return;
    widget.onFocus();
    widget.onNudge(factor);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) => _lastPinchScale = 1;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !zoomModifierHeld) return;
    // Registering (rather than acting at once) keeps the contract with any other
    // interested handler: exactly one of us reacts to this event.
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final scroll = resolved as PointerScrollEvent;
      if (scroll.scrollDelta.dy == 0) return;
      widget.onFocus();
      // Wheel up (a negative delta) zooms in, as everywhere else.
      widget.onNudge(
        scroll.scrollDelta.dy < 0 ? _wheelFactor : 1 / _wheelFactor,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerPanZoomStart: _onPanZoomStart,
    onPointerPanZoomUpdate: _onPanZoomUpdate,
    onPointerPanZoomEnd: _onPanZoomEnd,
    onPointerSignal: _onPointerSignal,
    child: widget.child,
  );
}
