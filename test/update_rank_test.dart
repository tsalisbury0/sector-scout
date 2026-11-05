import 'package:cell_tower_monitor/services/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('releaseRank', () {
    test('a beta bump outranks the beta before it', () {
      // The bug this pins: both tags reduce to 1.1.0, so the check never saw
      // the second beta as newer than the first.
      expect(
        releaseRank('v1.1.0-beta2'),
        greaterThan(releaseRank('v1.1.0-beta')),
      );
      expect(
        releaseRank('v1.1.0-beta10'),
        greaterThan(releaseRank('v1.1.0-beta2')),
      );
      expect(
        releaseRank('v1.1.0-beta'),
        greaterThan(releaseRank('v1.0.9')),
      );
    });

    test('a stable release outranks every beta of the same numbers', () {
      expect(releaseRank('v1.1.0'), greaterThan(releaseRank('v1.1.0-beta10')));
      expect(
        releaseRank('v1.1.1-beta'),
        greaterThan(releaseRank('v1.1.0')),
      );
    });

    test('the same tag in either spelling is the same release', () {
      expect(releaseRank('v1.1.1-beta'), releaseRank('1.1.1-beta'));
      expect(releaseRank('v1.1.1-beta'), isNot(greaterThan(releaseRank('v1.1.1-beta'))));
    });
  });
}
