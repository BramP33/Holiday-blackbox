# Frontend/Backend Startup Timing Fix

## Probleem
De Flutter frontend start sneller dan de Python backend, waardoor de frontend geen data kan ophalen bij eerste start.

## Oplossing Geïmplementeerd

### 1. Backend: Lightweight Health Check Endpoint ✅
**File**: `Software/blackbox/web/app.py`

Toegevoegd `/api/ping` endpoint voor snelle health checks:
```python
@app.get('/api/ping')
def api_ping():
    """Lightweight health check endpoint for startup checks."""
    return jsonify({'status': 'ok', 'timestamp': _now_iso()})
```

### 2. Frontend: Automatic Retry Logic ✅
**File**: `Software/flutter_frontend/lib/services/api_client.dart`

Toegevoegd automatic retry mechanisme met exponential backoff:

```dart
class ApiClient {
  final int maxRetries = 5;
  final Duration initialRetryDelay = const Duration(milliseconds: 500);

  Future<http.Response> _retryRequest(
    Future<http.Response> Function() request, {
    int? maxRetries,
  }) async {
    final retries = maxRetries ?? this.maxRetries;
    var delay = initialRetryDelay;
    
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        final response = await request();
        return response;
      } on SocketException catch (_) {
        // Backend not ready yet
        if (attempt == retries - 1) rethrow;
        print('Backend not ready (attempt ${attempt + 1}/$retries), retrying in ${delay.inMilliseconds}ms...');
        await Future.delayed(delay);
        delay = delay * 2; // Exponential backoff
      }
    }
    throw Exception('Max retries reached');
  }
}
```

**Retry timing**:
- Attempt 1: 500ms delay
- Attempt 2: 1000ms delay  
- Attempt 3: 2000ms delay
- Attempt 4: 4000ms delay
- Attempt 5: 8000ms delay
- **Total**: ~15.5 seconds max wait

### 3. Frontend: Applied Retry to Critical Endpoints ✅

Updated `fetchTripStats()` to use retry logic:
```dart
Future<TripStats> fetchTripStats() async {
  final uri = _resolve('/api/stats');
  final response = await _retryRequest(() => _client.get(uri));
  // ...
}
```

### 4. Existing BootScreen Already Handles This ✅
**File**: `Software/flutter_frontend/lib/screens/boot_screen.dart`

De boot screen:
- Laadt `lastMediaLocationProvider` bij startup
- Toont "Blackbox is powering up…" tijdens laden
- Toont "Locating your last story…" tijdens API calls
- Wacht met navigeren tot data binnen is of timeout
- Heeft fallback naar Nederlandse steden bij errors

## Hoe Het Werkt

1. **Flutter app start** → Toont BootScreen met animatie
2. **API call naar backend** → Gebruikt `_retryRequest()` 
3. **Backend nog niet klaar** → SocketException
4. **Retry logica** → Wacht 500ms, probeert opnieuw
5. **Backend beschikbaar** → Data binnen, navigeert door
6. **Als backend >15s nodig heeft** → Error, toont fallback

## Visuele Feedback voor Gebruiker

### Tijdens Opstarten:
```
┌─────────────────────────────────┐
│                                 │
│    [Wereldkaart met zoom in]    │
│                                 │
│   "Blackbox is powering up…"    │
│  "Locating your last story…"    │
│                                 │
└─────────────────────────────────┘
```

### Backend Start Timing:
```
T=0s:   Frontend start
T=0.5s: Backend start (typisch)
T=1s:   API retry 1 (500ms delay) → Success!
T=2s:   Animatie klaar → Navigeert naar RootShell
```

### Backend Langzaam (worst case):
```
T=0s:   Frontend start
T=2s:   Backend start (langzaam systeem)
T=2.5s: API retry 3 (na 500ms + 1000ms + 2000ms)
T=4s:   Success! → Navigeert door
```

## Testing

### Test Backend Delay:
```bash
# Stop backend
sudo systemctl stop blackbox-web

# Start frontend
cd /home/blackbox/Holiday-blackbox/Software/flutter_frontend
./../flutter/bin/flutter run -d linux

# Start backend na 3 seconden
sleep 3 && sudo systemctl start blackbox-web
```

**Verwacht resultaat**: Frontend blijft "Locating your last story…" tonen tot backend reageert.

### Test Backend Crash:
```bash
# Backend blijft uit
sudo systemctl stop blackbox-web

# Start frontend
flutter run -d linux
```

**Verwacht resultaat**: Na ~15s timeout toont fallback city.

## Files Gewijzigd

1. ✅ `Software/blackbox/web/app.py`
   - Added `/api/ping` endpoint

2. ✅ `Software/flutter_frontend/lib/services/api_client.dart`
   - Added `_retryRequest()` method
   - Added `maxRetries` and `initialRetryDelay` parameters
   - Updated `fetchTripStats()` to use retry logic
   - Added import for `dart:io`

## Volgende Stappen (Optioneel)

### 1. Apply Retry to More Endpoints
Andere API calls kunnen ook retry logica gebruiken:
- `fetchPhotos()`
- `fetchVideos()`
- `fetchBackupStatus()`
- Etc.

### 2. Configureerbare Retry Settings
In `lib/state/providers.dart`:
```dart
final apiClientProvider = Provider<ApiClient>((ref) {
  final env = ref.watch(environmentProvider);
  final client = ApiClient(
    baseUri: env.baseUri,
    maxRetries: 10,  // Meer retries voor trage Pi's
    initialRetryDelay: Duration(milliseconds: 300),
  );
  return client;
});
```

### 3. Health Check Polling
Voor systemen waar backend vaak herstart:
```dart
class ApiClient {
  Stream<bool> watchBackendHealth() async* {
    while (true) {
      try {
        await _client.get(_resolve('/api/ping'));
        yield true;
      } catch (_) {
        yield false;
      }
      await Future.delayed(Duration(seconds: 5));
    }
  }
}
```

## Status

🎉 **KLAAR!** 

De frontend kan nu omgaan met late backend starts door:
1. Automatisch retries met exponential backoff
2. Duidelijke visuele feedback tijdens wachten
3. Graceful fallback bij langdurige failures

Rebuild de Flutter app om de wijzigingen te testen:
```bash
cd /home/blackbox/Holiday-blackbox/Software/flutter_frontend
flutter build linux
```
