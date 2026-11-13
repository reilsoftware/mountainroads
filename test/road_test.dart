import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mountain_roads/config.dart';
import 'package:mountain_roads/road.dart';

void main() {
  final road = Road.fromJson(File('assets/road.json').readAsStringSync());

  test('gate is on the road', () {
    expect(road.match(-30.0462381, -70.8193721).onRoad, isTrue);
  });

  test('observatory buildings are near the road end', () {
    // Map pins are on the buildings, not the road.
    for (final (lat, lon) in [(-30.1696927, -70.8064637), (-30.2446535, -70.7493386)]) {
      expect(road.match(lat, lon).distanceM, lessThan(200));
    }
  });

  test('upper branches are matched to the right summit', () {
    expect(road.match(-30.1696927, -70.8064637).branch, 'Tololo');
    expect(road.match(-30.2446535, -70.7493386).branch, 'Rubin');
    expect(road.match(-30.2407, -70.7366).branch, 'Gemini');
  });

  test('limits from the 2020 zone report', () {
    final gemini =
        (jsonDecode(File('assets/road.json').readAsStringSync())['branches'] as List).firstWhere(
              (b) => b['name'] == 'Gemini',
            )['points']
            as List;
    // Limit at road points whose distance from the gate falls in [fromKm, toKm].
    Set<double> limitsBetween(double fromKm, double toKm) => {
      for (final p in gemini)
        if (road.match(p[0], p[1]) case final m when m.alongM >= fromKm * 1000 && m.alongM <= toKm * 1000) m.limitKmh,
    };
    expect(road.match(-30.0462381, -70.8193721).limitKmh, 50); // zone 1 at the gate
    expect(limitsBetween(2.0, 2.5), {70}); // zone 2
    expect(limitsBetween(27.0, 27.3), {30}); // zone 14 just past El Quisco
    // El Quisco to Tololo is 40 (zone 27).
    expect(road.match(-30.1696927, -70.8064637).limitKmh, 40);
    // Rubin spur from the Gemini/SOAR split is 20.
    expect(road.match(-30.2446535, -70.7493386).limitKmh, 20);
    // Zone 26 at Gemini South is 40.
    expect(road.match(-30.2407, -70.7366).limitKmh, 40);
  });

  test('Gemini and SOAR drivers never get the Rubin 20 limit', () {
    final gemini =
        (jsonDecode(File('assets/road.json').readAsStringSync())['branches'] as List).firstWhere(
              (b) => b['name'] == 'Gemini',
            )['points']
            as List;
    // Every point from zone 26 to SOAR, including the stretch shared with
    // the Rubin road before the turn-off.
    final limits = {
      for (final p in gemini)
        if (road.match(p[0], p[1]) case final m when m.alongM >= 40700) m.limitKmh,
    };
    expect(limits, {40});
    expect(road.match(-30.2380723, -70.7337158).limitKmh, 40); // SOAR
  });

  test('Vicuña is off the mountain, about 14 km from the gate', () {
    final m = road.match(-30.0319, -70.7081);
    expect(m.onRoad, isFalse);
    expect(m.distanceM, inInclusiveRange(9000, 15000));
  });

  test('speed thresholds', () {
    expect(classify(40, 40), SpeedStatus.ok);
    expect(classify(44, 40), SpeedStatus.ok);
    expect(classify(44.5, 40), SpeedStatus.warn);
    expect(classify(48, 40), SpeedStatus.warn);
    expect(classify(48.5, 40), SpeedStatus.danger);
  });

  test('alarm threshold files', () {
    final p1530 = Thresholds.fromFileName('1530percent.txt')!;
    expect(classify(45, 40, p1530), SpeedStatus.ok);
    expect(classify(46.5, 40, p1530), SpeedStatus.warn);
    expect(classify(52.5, 40, p1530), SpeedStatus.danger);
    final p0510 = Thresholds.fromFileName('0510percent.txt')!;
    expect(classify(42.5, 40, p0510), SpeedStatus.warn);
    expect(classify(44.5, 40, p0510), SpeedStatus.danger);
    final kmh1020 = Thresholds.fromFileName('1020.txt')!;
    expect(kmh1020.percent, isFalse);
    expect(classify(50, 40, kmh1020), SpeedStatus.ok);
    expect(classify(51, 40, kmh1020), SpeedStatus.warn);
    expect(classify(61, 40, kmh1020), SpeedStatus.danger);
    expect(Thresholds.fromFileName('0515.txt')!.danger, 15);
    expect(Thresholds.fromFileName('1020percent.txt')!.fileName, '1020percent.txt');
    for (final bad in ['2010.txt', '1020percent.mp3', 'ColorBlind.txt', '0000.txt', '102.txt']) {
      expect(Thresholds.fromFileName(bad), isNull, reason: bad);
    }
  });

  test('Ruta 41 only counts when ruta41.txt switches it on', () {
    final json = File('assets/road.json').readAsStringSync();
    final withRuta41 = Road.fromJson(json, optional: {'ruta41'});
    final ruta41 = (jsonDecode(json)['branches'] as List).firstWhere((b) => b['name'] == 'Ruta41')['points'] as List;
    // A point on Ruta 41 about 7 km from the airport (zone C, Altovalsol, 70).
    final p = ruta41.firstWhere((p) => withRuta41.match(p[0], p[1]).alongM > 7000) as List;
    final (lat, lon) = ((p[0] as num).toDouble(), (p[1] as num).toDouble());
    expect(road.match(lat, lon).onRoad, isFalse);
    final m = withRuta41.match(lat, lon);
    expect(m.branch, 'Ruta41');
    expect(m.onRoad, isTrue);
    expect(m.limitKmh, 70);
    // The mountain roads are unchanged.
    expect(withRuta41.match(-30.2446535, -70.7493386).limitKmh, 20);
  });

  test('recorded signs override limits in their direction only', () {
    final json = File('assets/road.json').readAsStringSync();
    final pts = (jsonDecode(json)['branches'] as List).firstWhere((b) => b['name'] == 'Gemini')['points'] as List;
    final r = Road.fromJson(json);
    // First road point at least [km] from the gate.
    (double, double) at(double km) {
      final p = pts.firstWhere((p) => r.match(p[0], p[1]).alongM >= km * 1000) as List;
      return ((p[0] as num).toDouble(), (p[1] as num).toDouble());
    }

    double limit((double, double) p, {bool down = false}) => r.match(p.$1, p.$2, down: down).limitKmh;
    // Zone 4 (70) to 6.67 km, zone 5 (40) to 14.32 km, then zone 6 (70).
    final (k6, k9, k10, k12, k15) = (at(6), at(9), at(10), at(12), at(15));
    expect([limit(k9), limit(k12), limit(k12, down: true)], [40, 40, 40]);
    r.applySigns(
      parseSigns('60_up.txt', '${k10.$1},${k10.$2}\n') + parseSigns('30_down.txt', '${k10.$1},${k10.$2}\nnot a line\n'),
    );
    expect(limit(k9), 40); // before the up sign
    expect(limit(k12), 60); // past it going up
    expect(limit(k15), 70); // next zone change ends it
    expect(limit(k12, down: true), 40); // down: not yet at the down sign
    expect(limit(k9, down: true), 30); // past the down sign going down
    expect(limit(k6, down: true), 70); // zone 4 below ends it
    expect(parseSigns('ColorBlind.txt', '1,2'), isEmpty);
  });

  test('ColorBlind.txt colours', () {
    expect(parseColors('#0072B2,#F0E442,#D55E00')!.map((c) => c.toARGB32()).toList(), [
      0xFF0072B2,
      0xFFF0E442,
      0xFFD55E00,
    ]);
    expect(parseColors('0072B2, F0E442 ,D55E00'), isNotNull);
    expect(parseColors('red,green,blue'), isNull);
    expect(parseColors('#0072B2,#F0E442'), isNull);
  });
}
