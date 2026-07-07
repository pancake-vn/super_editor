import 'package:flutter/widgets.dart';
import 'package:follow_the_leader/follow_the_leader.dart';

/// A [FollowerBoundary] that wraps another [boundary] and shrinks its bounds by
/// [padding].
///
/// A `Follower` clamps itself so its rect stays inside its boundary. With the
/// raw screen/widget boundary a follower can end up flush against an edge — for
/// example the mobile selection toolbar, which is horizontally centered on the
/// caret, lands against the left/right screen edge when the caret sits near the
/// edge of an otherwise-empty composer. Deflating the boundary by [padding]
/// keeps the follower that distance away from the edges.
class InsetFollowerBoundary implements FollowerBoundary {
  const InsetFollowerBoundary({
    required this.boundary,
    this.padding = EdgeInsets.zero,
  });

  /// The boundary whose bounds are deflated by [padding].
  final FollowerBoundary boundary;

  /// The amount to shrink [boundary]'s bounds on each side.
  final EdgeInsets padding;

  @override
  Rect calculateGlobalBounds(BuildContext context) {
    final bounds = boundary.calculateGlobalBounds(context);
    if (padding == EdgeInsets.zero) {
      return bounds;
    }
    return padding.deflateRect(bounds);
  }
}
