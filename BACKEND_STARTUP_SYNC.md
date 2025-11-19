# Backend Startup Synchronization

## Overview

The Blackbox Holiday application now has proper startup synchronization between the backend and frontend to prevent connection issues.

## How It Works

### Backend Startup (start_blackbox.sh)

1. **Web Server Starts** - The Python Flask backend starts running on `http://127.0.0.1:5000`
2. **Health Check Loop** - The startup script polls the backend's `/api/backup/status` endpoint
3. **Waits for Response** - It retries for up to 60 seconds (with 1-second intervals)
4. **Backend Ready** - Once the backend responds, the frontend is started

### Frontend Startup (Flutter App)

1. **Boot Screen** - Shows "Blackbox is powering up..." message
2. **Displays Status** - Shows different messages depending on backend state:
   - "Waiting for backend to start…" (if backend not responding)
   - "Locating your last story…" (while fetching location data)
   - Normal status once backend is healthy
3. **Health Check Provider** - The `backendHealthProvider` continuously checks backend health
4. **Automatic Retry** - Retries connecting to backend for up to 30 seconds
5. **Proceeds When Ready** - Only navigates to main app when backend is healthy

## Benefits

✅ **No Connection Errors** - Frontend waits for backend before starting critical operations
✅ **Better User Experience** - Clear status messages during startup
✅ **Automatic Recovery** - If backend crashes during startup, frontend shows status
✅ **Reliable Initialization** - Both services properly initialized before user interaction

## Technical Details

### Files Modified

- **start_blackbox.sh** - Added `wait_for_backend()` function
- **lib/state/backend_health.dart** - New provider for backend health checks
- **lib/screens/boot_screen.dart** - Updated to show backend status

### Health Check Strategy

The health check uses a simple exponential approach:
- Initial retry interval: 1 second
- Maximum attempts: 60 attempts = ~60 seconds total wait
- Shows progress every 10 attempts

If the backend doesn't respond after this time, the app shows an error message.

## Usage

```bash
# Start the application with backend synchronization
./start_blackbox.sh

# The script now:
# 1. Starts web server
# 2. Waits for backend to be healthy
# 3. Starts Flutter frontend
# 4. Frontend waits for backend confirmation before loading app
```

## Troubleshooting

If the frontend shows "Waiting for backend to start…":

1. Check if web server started: `ps aux | grep main.py`
2. Check logs: `tail -f /tmp/blackbox_web.log`
3. Verify port 5000 is available: `netstat -tlnp | grep 5000`
4. Check Python dependencies: `python3 -c "import blackbox"`
