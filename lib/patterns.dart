import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'road.dart';

/// Default screen colours: normal (solid), over 10% (yield), over 20% (stop).
const defaultColors = [Color(0xFF0B3D1E), Color(0xFFF2C200), Color(0xFFC8102E)];

/// Full-screen background for the speed status: solid colour when fine,
/// tiled yield triangles when more than 10% over, tiled stop octagons when
/// more than 20% over. Shapes as well as colour, so it reads without colour.
class AlertBackground extends StatelessWidget {
  final SpeedStatus status;
  final List<Color> colors;
  final Widget child;

  const AlertBackground({super.key, required this.status, required this.colors, required this.child});

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _PatternPainter(status, colors), child: child);
}

class _PatternPainter extends CustomPainter {
  final SpeedStatus status;
  final List<Color> colors;

  _PatternPainter(this.status, this.colors);

  static const _tile = 120.0;
  static const _ground = Color(0xFF141414);

  @override
  void paint(Canvas canvas, Size size) {
    if (status == SpeedStatus.ok) {
      canvas.drawRect(Offset.zero & size, Paint()..color = colors[0]);
      return;
    }
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = _ground);
    final fill = Paint()..color = status == SpeedStatus.warn ? colors[1] : colors[2];
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = status == SpeedStatus.warn ? Colors.black : Colors.white;
    // Offset every other row by half a tile.
    for (var row = 0; row * _tile * 0.9 < size.height + _tile; row++) {
      final y = row * _tile * 0.9;
      final shift = row.isOdd ? _tile / 2 : 0.0;
      for (var x = -_tile + shift; x < size.width + _tile; x += _tile) {
        final c = Offset(x, y);
        final path = status == SpeedStatus.warn ? _yield(c, _tile * 0.36) : _octagon(c, _tile * 0.36);
        canvas.drawPath(path, fill);
        canvas.drawPath(path, rim);
      }
    }
  }

  /// Downward-pointing equilateral triangle.
  Path _yield(Offset c, double r) {
    final p = Path();
    for (var i = 0; i < 3; i++) {
      final a = math.pi / 2 + i * 2 * math.pi / 3; // first vertex points down
      final v = c + Offset(r * math.cos(a), r * math.sin(a));
      i == 0 ? p.moveTo(v.dx, v.dy) : p.lineTo(v.dx, v.dy);
    }
    return p..close();
  }

  /// Regular octagon with flat top and bottom, like a stop sign.
  Path _octagon(Offset c, double r) {
    final p = Path();
    for (var i = 0; i < 8; i++) {
      final a = math.pi / 8 + i * math.pi / 4;
      final v = c + Offset(r * math.cos(a), r * math.sin(a));
      i == 0 ? p.moveTo(v.dx, v.dy) : p.lineTo(v.dx, v.dy);
    }
    return p..close();
  }

  @override
  bool shouldRepaint(_PatternPainter old) => old.status != status || old.colors != colors;
}
