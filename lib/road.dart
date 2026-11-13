import 'dart:convert';
import 'dart:math' as math;

/// Within this distance of the road centreline you count as "on the mountain".
const double onRoadThresholdM = 40;

const double _refLat = -30.15 * math.pi / 180;
const double _mPerDeg = 111320;

/// Equirectangular projection around the observatories; accurate to well
/// under a metre over the ~40 km of road.
({double x, double y}) _toXY(double lat, double lon) => (x: lon * _mPerDeg * math.cos(_refLat), y: lat * _mPerDeg);

class RoadMatch {
  final double distanceM;
  final double alongM;
  final String branch;
  final double limitKmh;

  const RoadMatch(this.distanceM, this.alongM, this.branch, this.limitKmh);

  bool get onRoad => distanceM <= onRoadThresholdM;
}

/// A speed sign recorded in debug mode (files like 60_up.txt): from this
/// point on, driving up (or down) the mountain, the limit is [limitKmh]
/// until the next zone change or sign.
class Sign {
  final double limitKmh;
  final bool down;
  final double lat, lon;

  const Sign(this.limitKmh, this.down, this.lat, this.lon);
}

class _Branch {
  final String name;
  final List<double> xs, ys, cum;

  /// Going up: (startAlongM, limitKmh), sorted; the last start at or before
  /// the position applies.
  List<(double, double)> up;

  /// Going down: (endAlongM, limitKmh), sorted; the first end beyond the
  /// position applies (a zone change seen from above).
  List<(double, double)> down;

  _Branch(this.name, this.xs, this.ys, this.cum, List<(double, double)> zones)
    : up = zones,
      down = [for (var i = 1; i < zones.length; i++) (zones[i].$1, zones[i - 1].$2), (double.infinity, zones.last.$2)];

  double limitAt(double along, {bool down = false}) {
    if (down) {
      for (final z in this.down) {
        if (z.$1 > along) return z.$2;
      }
      return this.down.last.$2;
    }
    var limit = up.first.$2;
    for (final z in up) {
      if (z.$1 > along) break;
      limit = z.$2;
    }
    return limit;
  }

  /// (squared distance, along) of the nearest point on this branch.
  (double, double) project(({double x, double y}) p) {
    var bestD = double.infinity;
    var bestAlong = 0.0;
    for (var i = 0; i < xs.length - 1; i++) {
      final ax = xs[i], ay = ys[i];
      final dx = xs[i + 1] - ax, dy = ys[i + 1] - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (((p.x - ax) * dx + (p.y - ay) * dy) / len2).clamp(0.0, 1.0);
      final ex = p.x - (ax + t * dx), ey = p.y - (ay + t * dy);
      final d2 = ex * ex + ey * ey;
      if (d2 < bestD) {
        bestD = d2;
        bestAlong = cum[i] + t * (cum[i + 1] - cum[i]);
      }
    }
    return (bestD, bestAlong);
  }
}

class Road {
  final List<_Branch> _branches;
  final bool placeholderLimits;

  Road._(this._branches, this.placeholderLimits);

  /// Branches marked "optional" (e.g. ruta41) are only loaded when named in
  /// [optional].
  factory Road.fromJson(String source, {Set<String> optional = const {}}) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    final branches = <_Branch>[];
    for (final b in data['branches'] as List) {
      final opt = b['optional'] as String?;
      if (opt != null && !optional.contains(opt)) continue;
      final xs = <double>[], ys = <double>[], cum = <double>[];
      for (final p in b['points'] as List) {
        final xy = _toXY((p[0] as num).toDouble(), (p[1] as num).toDouble());
        cum.add(xs.isEmpty ? 0 : cum.last + math.sqrt(math.pow(xy.x - xs.last, 2) + math.pow(xy.y - ys.last, 2)));
        xs.add(xy.x);
        ys.add(xy.y);
      }
      final zones = [for (final z in b['zones'] as List) ((z[0] as num).toDouble(), (z[1] as num).toDouble())];
      branches.add(_Branch(b['name'] as String, xs, ys, cum, zones));
    }
    return Road._(branches, data['placeholder_limits'] == true);
  }

  /// Nearest point on any branch of the road; [down] picks the limits for
  /// driving down the mountain (towards the gate, or the airport).
  RoadMatch match(double lat, double lon, {bool down = false}) {
    final p = _toXY(lat, lon);
    var bestD = double.infinity;
    var bestAlong = 0.0;
    late _Branch bestBranch;
    for (final b in _branches) {
      final (d2, along) = b.project(p);
      if (d2 < bestD) {
        bestD = d2;
        bestAlong = along;
        bestBranch = b;
      }
    }
    return RoadMatch(math.sqrt(bestD), bestAlong, bestBranch.name, bestBranch.limitAt(bestAlong, down: down));
  }

  /// Recorded signs override the zone limits from where they stand to the
  /// next zone change or sign in their direction. A sign counts for every
  /// branch it is on (the branches share the lower road).
  void applySigns(Iterable<Sign> signs) {
    for (final s in signs) {
      final p = _toXY(s.lat, s.lon);
      for (final b in _branches) {
        final (d2, along) = b.project(p);
        if (d2 > onRoadThresholdM * onRoadThresholdM) continue;
        if (s.down) {
          b.down = [...b.down.where((z) => z.$1 != along), (along, s.limitKmh)]..sort((a, c) => a.$1.compareTo(c.$1));
        } else {
          b.up = [...b.up.where((z) => z.$1 != along), (along, s.limitKmh)]..sort((a, c) => a.$1.compareTo(c.$1));
        }
      }
    }
  }
}

enum SpeedStatus { ok, warn, danger }

/// How far over the limit the two alarms start: a percentage of the limit
/// (1020percent.txt, the default) or km/h (1020.txt).
class Thresholds {
  final int warn;
  final int danger;
  final bool percent;

  const Thresholds(this.warn, this.danger, {this.percent = true});

  static const standard = Thresholds(10, 20);

  /// "1530percent.txt" -> 15 / 30 %, "0510.txt" -> 5 / 10 km/h, else null.
  static Thresholds? fromFileName(String name) {
    final m = RegExp(r'^(\d\d)(\d\d)(percent)?\.txt$', caseSensitive: false).firstMatch(name);
    if (m == null) return null;
    final warn = int.parse(m[1]!), danger = int.parse(m[2]!);
    if (warn <= 0 || danger <= warn) return null;
    return Thresholds(warn, danger, percent: m[3] != null);
  }

  String get fileName => '${_two(warn)}${_two(danger)}${percent ? 'percent' : ''}.txt';

  String get description => percent ? '$warn% / $danger% over' : '$warn / $danger km/h over';

  static String _two(int n) => n.toString().padLeft(2, '0');

  double _over(double limitKmh, int by) => percent ? limitKmh * (1 + by / 100) : limitKmh + by;
}

/// ok: up to the first threshold over the limit (default 10%), warn: more
/// than that, danger: more than the second threshold (default 20%).
SpeedStatus classify(double speedKmh, double limitKmh, [Thresholds t = Thresholds.standard]) {
  if (speedKmh > t._over(limitKmh, t.danger)) return SpeedStatus.danger;
  if (speedKmh > t._over(limitKmh, t.warn)) return SpeedStatus.warn;
  return SpeedStatus.ok;
}
