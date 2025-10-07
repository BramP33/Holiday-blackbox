import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

class CampNameGenerator {
  CampNameGenerator._();

  static final CampNameGenerator instance = CampNameGenerator._();
  static const _defaultNames = [
    'Trailhead Echo',
    'Firefly Basin',
    'Whispering Pines',
    'Summit Hollow',
    'Cedar Ridge',
    'Foxglove Crossing',
    'Moonlight Knoll',
    "Raven's Roost",
    'Ember Creekside',
    'Timberline Nook',
    'Starlit Meadow',
    'Bearclaw Pass',
    'Prairie Lantern',
    "Badger's Hideout",
    'Cascade Glade',
    'Quarry Overlook',
    'Larkspur Point',
    'Nightjar Clearing',
    'Sentinel Bluff',
    'Otterstone Bend',
    'Bivouac Bluff',
    'Fernhaven Loop',
    'Sunset Spur',
    'Meadowlark Rise',
    'Northwind Shelf',
    'Marmot Terrace',
    'Sagebrush Saddle',
    'Switchback Cove',
    'Evergreen Fork',
    "Wanderer's Rest",
  ];

  final Random _random = Random();
  List<String> _names = List.of(_defaultNames);
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final data = await rootBundle.loadString('assets/data/camp_names.txt');
      final lines = data
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      if (lines.isNotEmpty) {
        _names = lines;
      }
    } catch (_) {
      // ignore missing asset, fallback to defaults
    } finally {
      _loaded = true;
    }
  }

  String fallbackForKey(String key) {
    if (_names.isEmpty) {
      return _defaultNames[_random.nextInt(_defaultNames.length)];
    }
    final index = key.hashCode % _names.length;
    return _names[index < 0 ? index + _names.length : index];
  }

  String randomName() {
    if (_names.isEmpty) {
      return _defaultNames[_random.nextInt(_defaultNames.length)];
    }
    return _names[_random.nextInt(_names.length)];
  }
}
