import 'package:flutter/material.dart';

/// Easy mode colour for each slide position, 1st–7th, in rainbow order so
/// "further out" reads as "further along the rainbow".
class PositionColors {
  static const screen = [
    Color(0xFFF44336), // 1st red
    Color(0xFFFF9800), // 2nd orange
    Color(0xFFFFEB3B), // 3rd yellow
    Color(0xFF4CAF50), // 4th green
    Color(0xFF00BCD4), // 5th cyan
    Color(0xFF42A5F5), // 6th blue
    Color(0xFFBA68C8), // 7th purple
  ];

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
