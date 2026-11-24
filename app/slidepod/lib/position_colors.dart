import 'ui/seventh.dart';

/// The colour for each slide position, 1st–7th, in rainbow order so
/// "further out" reads as "further along the rainbow" (the design's
/// position colours, [Seventh.positions]).
class PositionColors {
  static const screen = Seventh.positions;

  /// The same colours for the pod's LEDs (r, g, b levels 0–255). Mixed on
  /// three separate LEDs rather than copied from [screen], since the green
  /// LED looks much brighter than the red at the same level.
  static const led = [
    (255, 0, 0),
    (255, 40, 0),
    (255, 120, 0),
    (0, 255, 0),
    (0, 200, 255),
    (0, 0, 255),
    (150, 0, 255),
  ];
}
