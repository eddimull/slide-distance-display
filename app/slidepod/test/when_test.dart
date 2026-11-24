import 'package:flutter_test/flutter_test.dart';
import 'package:slidepod/ui/when.dart';

void main() {
  test('dates read the way people say them', () {
    final now = DateTime(2026, 11, 23, 20, 0);
    expect(friendlyWhen(DateTime(2026, 11, 23, 14, 5), now: now), 'Today 14:05');
    expect(friendlyWhen(DateTime(2026, 11, 22, 19, 20), now: now), 'Yesterday 19:20');
    expect(friendlyWhen(DateTime(2026, 11, 21, 18, 40), now: now), 'Nov 21');
    expect(friendlyWhen(DateTime(2025, 12, 31, 9, 0), now: now), 'Dec 31, 2025');
    // Just after midnight, last night is yesterday.
    expect(friendlyWhen(DateTime(2026, 11, 22, 23, 59), now: DateTime(2026, 11, 23, 0, 1)),
        'Yesterday 23:59');
  });
}
