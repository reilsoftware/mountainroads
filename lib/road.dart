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

class _Branch {
  final String name;
  final List<double> xs, ys, cum;
  final List<(double, double)> zones; // (startAlongM, limitKmh), sorted

  _Branch(this.name, this.xs, this.ys, this.cum, this.zones);

  double limitAt(double along) {
    var limit = zones.first.$2;
    for (final z in zones) {
      if (z.$1 > along) break;
      limit = z.$2;
    }
    return limit;
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

  /// Nearest point on any branch of the road.
  RoadMatch match(double lat, double lon) {
    final p = _toXY(lat, lon);
    var bestD = double.infinity;
    var bestAlong = 0.0;
    late _Branch bestBranch;
    for (final b in _branches) {
      for (var i = 0; i < b.xs.length - 1; i++) {
        final ax = b.xs[i], ay = b.ys[i];
        final dx = b.xs[i + 1] - ax, dy = b.ys[i + 1] - ay;
        final len2 = dx * dx + dy * dy;
        final t = len2 == 0 ? 0.0 : (((p.x - ax) * dx + (p.y - ay) * dy) / len2).clamp(0.0, 1.0);
        final ex = p.x - (ax + t * dx), ey = p.y - (ay + t * dy);
        final d2 = ex * ex + ey * ey;
        if (d2 < bestD) {
          bestD = d2;
          bestAlong = b.cum[i] + t * (b.cum[i + 1] - b.cum[i]);
          bestBranch = b;
        }
      }
    }
    return RoadMatch(math.sqrt(bestD), bestAlong, bestBranch.name, bestBranch.limitAt(bestAlong));
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
