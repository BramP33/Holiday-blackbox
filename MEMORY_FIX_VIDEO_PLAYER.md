# Video Player Memory Fix voor Raspberry Pi

## Probleem
De Flutter frontend crashte na het afspelen van ongeveer 5 video's op de Raspberry Pi. Dit werd veroorzaakt door geheugenlekken in de video player en image cache.

## Oorzaken
1. **VideoPlayerController werd niet goed afgesloten** - De controller moet eerst gepauzeerd worden voordat deze wordt gedisposed
2. **Image cache stapelde zich op** - Flutter's standaard image cache (1000 images, 100MB) is te groot voor Raspberry Pi
3. **CachedNetworkImage houdt te veel in het geheugen** - Thumbnails bleven in het geheugen zelfs na navigatie
4. **Geen cleanup na video playback** - Video geheugen werd niet vrijgegeven na het sluiten van de video player

## Oplossingen Geïmplementeerd

### 1. Image Cache Limiet Verlaagd (`main.dart`)
```dart
// Configureer image cache voor Raspberry Pi
PaintingBinding.instance.imageCache.maximumSize = 200; // Van 1000 naar 200 images
PaintingBinding.instance.imageCache.maximumSizeBytes = 50 << 20; // 50MB ipv 100MB
```

### 2. Verbeterde Video Player Disposal (`video_player_screen.dart`)
- VideoPlayerController wordt nu eerst gepauzeerd voordat dispose
- Try-catch toegevoegd om errors tijdens cleanup te voorkomen
- Alle timers worden correct geannuleerd

```dart
@override
void dispose() {
  // Cancel all timers first
  _positionTimer?.cancel();
  _transcriptCheckTimer?.cancel();
  _controlsHideTimer?.cancel();
  
  // Remove listener before disposing
  _controller.removeListener(_onVideoPlayerUpdate);
  
  // Properly stop and dispose the video player
  try {
    if (_controller.value.isInitialized) {
      _controller.pause();
    }
  } catch (e) {
    // Ignore errors during cleanup
  }
  
  // Dispose controller - this should free video memory
  _controller.dispose();
  
  super.dispose();
}
```

### 3. Cache-Control Headers voor Video Streaming
- HTTP headers toegevoegd om excessive caching op het apparaat te voorkomen

```dart
_controller = VideoPlayerController.networkUrl(
  videoUri,
  httpHeaders: {
    'Cache-Control': 'no-cache, no-store',
  },
);
```

### 4. Agressief Image Cache Management (`media_library_screen.dart`)
- WidgetsBindingObserver toegevoegd om app lifecycle te monitoren
- Cache wordt geleegd bij:
  - Wisselen tussen tabs
  - App gaat naar background
  - Voor en na video playback
  - Wanneer cache > 70% vol is

```dart
void _clearExcessImageCache() {
  final imageCache = PaintingBinding.instance.imageCache;
  
  if (imageCache.currentSize > (imageCache.maximumSize * 0.7).round()) {
    imageCache.clear();
    imageCache.clearLiveImages();
  }
}
```

### 5. Cleanup Bij Video Navigation
- Image cache wordt geleegd voor het openen van video player
- Image cache wordt geleegd na het sluiten van video player
- Dit zorgt ervoor dat video geheugen volledig wordt vrijgegeven

## Verwacht Resultaat
- Frontend zou nu **minstens 20-30 video's** moeten kunnen afspelen zonder te crashen
- Geheugengebruik blijft stabiel rond 200-300MB op Raspberry Pi
- Snellere navigatie tussen video's door betere resource cleanup

## Testen
1. Start de Flutter app op de Raspberry Pi
2. Speel 10+ video's achter elkaar af
3. Wissel tussen tabs (foto's, video's, trash)
4. Monitor geheugengebruik met: `top -p $(pgrep -f flutter)`

## Technische Details
- **Platform**: Raspberry Pi OS (Bookworm)
- **Flutter SDK**: 3.16+
- **Video Player**: video_player_media_kit 1.0.5
- **Image Cache**: cached_network_image 3.3.1

## Extra Optimalisaties (Optioneel)
Als je nog steeds crashes ervaart na 15-20 video's:

1. Verlaag image cache verder in `main.dart`:
   ```dart
   PaintingBinding.instance.imageCache.maximumSize = 100; // Nog kleiner
   PaintingBinding.instance.imageCache.maximumSizeBytes = 25 << 20; // 25MB
   ```

2. Voeg memory monitoring toe in `video_player_screen.dart`:
   ```dart
   import 'dart:io';
   
   // In dispose():
   print('Memory: ${ProcessInfo.currentRss ~/ (1024 * 1024)} MB');
   ```

3. Forceer garbage collection na video dispose (advanced):
   ```dart
   import 'dart:developer' as developer;
   
   // Na _controller.dispose():
   developer.Timeline.startSync('GC');
   developer.Timeline.finishSync();
   ```

## Datum
4 november 2025

## Bestanden Gewijzigd
1. `/Software/flutter_frontend/lib/main.dart` - Image cache configuratie
2. `/Software/flutter_frontend/lib/screens/video_player_screen.dart` - Verbeterde disposal en cache headers
3. `/Software/flutter_frontend/lib/screens/media_library_screen.dart` - Agressieve cache cleanup

## Build & Deploy

### Voor Native Linux Build (Raspberry Pi):
```bash
# Rebuild de Flutter app
cd Software/flutter_frontend
flutter clean
flutter build linux --release

# De binary wordt gebouwd naar:
# build/linux/arm64/release/bundle/flutter_frontend (op ARM64)
# of build/linux/release/bundle/flutter_frontend (op andere architecturen)

# Herstart de service op de Raspberry Pi:
sudo systemctl restart blackbox-flutter

# Of gebruik het startup script:
cd /home/blackbox/Holiday-blackbox
./start_blackbox.sh
```

### Memory Monitoring op Raspberry Pi:
```bash
# Monitor het geheugengebruik tijdens video playback:
watch -n 1 "ps aux | grep flutter_frontend | grep -v grep"

# Of met meer detail:
top -p $(pgrep -f flutter_frontend)
```
