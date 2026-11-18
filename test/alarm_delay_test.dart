import 'package:flutter_test/flutter_test.dart';
import 'package:mountain_roads/tracker.dart';

void main() {
  final t0 = DateTime(2026, 11, 18, 12);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('no limit drop: the warning delay alone', () {
    expect(soundDue(at(0), at(0), null, 0), isTrue);
    expect(soundDue(at(9), at(0), null, 10), isFalse);
    expect(soundDue(at(10), at(0), null, 10), isTrue);
    expect(soundDue(at(10), null, null, 0), isFalse);
  });

  test('limit drop: 5 s, then the warning delay on top', () {
    // 0SecondsWarning: sound 5 s after the drop.
    expect(soundDue(at(4), at(0), at(0), 0), isFalse);
    expect(soundDue(at(5), at(0), at(0), 0), isTrue);
    // 10SecondsWarning: 15 s after the drop.
    expect(soundDue(at(14), at(0), at(0), 10), isFalse);
    expect(soundDue(at(15), at(0), at(0), 10), isTrue);
    // Already over before the drop: still 5 s from the drop.
    expect(soundDue(at(103), at(0), at(100), 0), isFalse);
    expect(soundDue(at(105), at(0), at(100), 0), isTrue);
  });

  test('going over long after a drop: the warning delay alone', () {
    expect(soundDue(at(60), at(60), at(0), 0), isTrue);
    expect(soundDue(at(69), at(60), at(0), 10), isFalse);
  });
}
