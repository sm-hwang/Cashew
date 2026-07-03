import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/emailScanWatermark.dart';

void main() {
  test('buildGmailAfterQuery converts ms to whole seconds', () {
    expect(buildGmailAfterQuery(1000), 'after:1'); // 1000ms -> 1s
    expect(buildGmailAfterQuery(1783000500), 'after:1783000'); // truncates ms
  });

  group('isNewerThanWatermark', () {
    test('strictly greater is new', () {
      expect(isNewerThanWatermark(2000, 1000), isTrue);
    });
    test('equal is NOT new (boundary already processed)', () {
      expect(isNewerThanWatermark(1000, 1000), isFalse);
    });
    test('older is not new', () {
      expect(isNewerThanWatermark(500, 1000), isFalse);
    });
  });

  group('advanceWatermark', () {
    test('moves to the max handled', () {
      expect(advanceWatermark(1000, [500, 3000, 2000]), 3000);
    });
    test('never moves backward', () {
      expect(advanceWatermark(5000, [1, 2, 3]), 5000);
    });
    test('unchanged when nothing handled', () {
      expect(advanceWatermark(1000, const []), 1000);
    });
  });

  group('initialWatermarkMs', () {
    test('fresh install backfills 30 days', () {
      final now = 1783000000000;
      expect(initialWatermarkMs(now, false),
          now - const Duration(days: 30).inMilliseconds);
    });
    test('existing email transactions -> forward-only (now)', () {
      final now = 1783000000000;
      expect(initialWatermarkMs(now, true), now);
    });
  });
}
