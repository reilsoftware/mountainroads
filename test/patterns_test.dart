import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mountain_roads/config.dart';
import 'package:mountain_roads/patterns.dart';
import 'package:mountain_roads/road.dart';

void main() {
  // Renders each background so the patterns can be checked by eye:
  //   flutter test --update-goldens test/patterns_test.dart
  for (final (name, colors) in [('standard', defaultColors), ('colorblind', parseColors(colorBlindDefaults)!)]) {
    testWidgets('$name backgrounds', (tester) async {
      tester.view.physicalSize = const Size(1500, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              for (final s in SpeedStatus.values)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: AlertBackground(status: s, colors: colors, child: const SizedBox.expand()),
                  ),
                ),
            ],
          ),
        ),
      );
      await expectLater(find.byType(Row), matchesGoldenFile('goldens/backgrounds_$name.png'));
    });
  }
}
