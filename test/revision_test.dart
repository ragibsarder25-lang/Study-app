import 'package:flutter_test/flutter_test.dart';
import 'package:recursive_study/core.dart';
import 'package:recursive_study/planner.dart';

void main() {
  final defaultIntervals = [1, 3, 7, 14, 30, 60];
  setUp(() => Prefs.intervals = List<int>.from(defaultIntervals));
  tearDown(() => Prefs.intervals = List<int>.from(defaultIntervals));

  group('repeated hard topics', () {
    test('counts weak ratings among the last 5 only', () {
      expect(Plan.hardCount([5, 2, 3, 4, 1, 2, 5]), 3); // window = 3,4,1,2,5
      expect(Plan.hardCount([4, 5]), 0);
      expect(Plan.hardCount([]), 0);
    });
  });

  group('priority', () {
    test('overdue days and repeated hard both raise priority', () {
      expect(Plan.priority(overdueDays: 4, hard: 2, latest: 2), 16.0);
      expect(Plan.priority(overdueDays: 0, hard: 0, latest: 5), 0.0);
      expect(Plan.priority(overdueDays: -3, hard: 1, latest: 3), 5.0);
    });
    test('overdue contribution is capped at 30 days', () {
      expect(Plan.priority(overdueDays: 40, hard: 0), 60.0);
    });
    test('a hard repeated topic outranks a slightly more overdue easy one', () {
      final hard = Plan.priority(overdueDays: 2, hard: 3, latest: 2); // 4 + 9 + 2
      final easy = Plan.priority(overdueDays: 4, hard: 0, latest: 5); // 8
      expect(hard, greaterThan(easy));
    });
  });

  group('confidence', () {
    test('no ratings -> null / "No data"', () {
      expect(Plan.confidence(ratings: [], revisionCount: 0, overdueDays: 0, steps: 6), isNull);
      expect(Plan.confLabel(null), 'No data');
    });
    test('perfect ratings through all intervals = 100, all 1-star = 0', () {
      expect(Plan.confidence(ratings: [5, 5, 5], revisionCount: 6, overdueDays: 0, steps: 6), 100);
      expect(Plan.confidence(ratings: [1, 1], revisionCount: 0, overdueDays: 0, steps: 6), 0);
    });
    test('overdue lowers confidence', () {
      final a = Plan.confidence(ratings: [2, 3, 4], revisionCount: 3, overdueDays: 0, steps: 6)!;
      final b = Plan.confidence(ratings: [2, 3, 4], revisionCount: 3, overdueDays: 2, steps: 6)!;
      expect(a, 50);
      expect(b, 44);
    });
    test('penalty is capped and result stays within 0..100', () {
      expect(Plan.confidence(ratings: [5], revisionCount: 0, overdueDays: 20, steps: 6), 45);
      expect(Plan.confidence(ratings: [1], revisionCount: 0, overdueDays: 99, steps: 6), 0);
    });
    test('labels', () {
      expect(Plan.confLabel(80), 'High');
      expect(Plan.confLabel(55), 'Medium');
      expect(Plan.confLabel(10), 'Low');
    });
  });

  group('revision intervals set in Settings still drive everything', () {
    test('defaults unchanged', () {
      expect([for (var s = 0; s < 7; s++) Plan.days(s, 3, 1.0)], [1.0, 3.0, 7.0, 14.0, 30.0, 60.0, 60.0]);
      expect(Prefs.afterNew(), 1);
    });
    test('changing Prefs.intervals changes the planner immediately', () {
      Prefs.intervals = [2, 5, 10];
      expect([for (var s = 0; s < 5; s++) Plan.days(s, 3, 1.0)], [2.0, 5.0, 10.0, 10.0, 10.0]);
      expect(Prefs.afterNew(), 2);
      expect(Prefs.afterRevision(0), 5);
      expect(Prefs.afterRevision(9), 10); // beyond the list -> last interval
    });
    test('confidence progress follows the configured number of intervals', () {
      final long = Plan.confidence(ratings: [4, 4], revisionCount: 2, overdueDays: 0, steps: 6)!;
      final short = Plan.confidence(ratings: [4, 4], revisionCount: 2, overdueDays: 0, steps: 2)!;
      expect(short, greaterThan(long));
    });
    test('a one-item interval list does not break anything', () {
      Prefs.intervals = [7];
      expect(Plan.days(0, 3, 1.0), 7.0);
      expect(Plan.days(5, 3, 1.0), 7.0);
      expect(Plan.confidence(ratings: [3], revisionCount: 1, overdueDays: 0, steps: Prefs.intervals.length), isNotNull);
    });
    test('difficulty still shortens/lengthens the configured interval', () {
      expect(Plan.days(0, 1, 1.0), 0.5); // very hard -> sooner
      Prefs.intervals = [3, 7];
      expect(Plan.days(0, 5, 1.0), 4.0); // very easy -> later
    });
  });

  group('settings and data are preserved', () {
    test('plan map keeps old keys, adds dailyCap, does not duplicate intervals', () {
      final m = Plan.toMap();
      for (final k in ['starPct', 'adapt', 'fade', 'lapseAt', 'lapseBack', 'minDays', 'maxDays', 'budget', 'balance', 'newPerDay', 'practiceMin', 'horizon', 'notifyMin', 'askNew', 'askRev', 'notify']) {
        expect(m.containsKey(k), isTrue, reason: k);
      }
      expect(m.containsKey('dailyCap'), isTrue);
      expect(m.containsKey('intervals'), isFalse);
    });
    test('an old backup without dailyCap keeps the current value; out-of-range is clamped', () async {
      final before = Plan.dailyCap;
      await Plan.fromMap({'adapt': 20});
      expect(Plan.dailyCap, before);
      await Plan.fromMap({'dailyCap': 999});
      expect(Plan.dailyCap, 60);
      await Plan.fromMap({'dailyCap': 0});
      expect(Plan.dailyCap, 1);
      await Plan.reset();
      expect(Plan.dailyCap, 10);
    });
  });
}
