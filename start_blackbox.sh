#!/bin/bash

# Blackbox Holiday App Startup Script
# This script automatically starts the latest build with all services

set -e

# Configuration
PROJECT_ROOT="/home/blackbox/Holiday-blackbox"
SOFTWARE_DIR="$PROJECT_ROOT/Software"
FLUTTER_DIR="$SOFTWARE_DIR/flutter_frontend"
BUILD_DIR="$FLUTTER_DIR/build/linux/arm64/release/bundle"
APP_BINARY="$BUILD_DIR/flutter_frontend"
FLUTTER_DIR="$SOFTWARE_DIR/flutter_frontend"
BUILD_DIR="$FLUTTER_DIR/build/linux/arm64/release/bundle"
APP_BINARY="$BUILD_DIR/flutter_frontend"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[Blackbox]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo "[WARN] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

# Check if the app needs to be built

# Function to check if app binary exists and is up-to-date
check_build() {
    if [ ! -f "$APP_BINARY" ]; then
        error "App binary not found at $APP_BINARY"
        log "Building Flutter app..."
        cd "$FLUTTER_DIR"
        flutter build linux --release
        if [ $? -ne 0 ]; then
            error "Flutter build failed!"
            exit 1
        fi
        success "Flutter build completed"
    else
        log "App binary found: $APP_BINARY"
        
        # Check if any Dart source file is newer than binary
        NEWEST_SOURCE=$(find "$FLUTTER_DIR/lib" -name "*.dart" -type f -newer "$APP_BINARY" 2>/dev/null | head -1)
        if [ -n "$NEWEST_SOURCE" ] || [ "$FLUTTER_DIR/pubspec.yaml" -nt "$APP_BINARY" ]; then
            warn "Source code is newer than binary. Rebuilding..."
            cd "$FLUTTER_DIR"
            flutter build linux --release
            if [ $? -ne 0 ]; then
                error "Flutter build failed!"
                exit 1
            fi
            success "Flutter app rebuilt"
        else
            success "App binary is up-to-date"
        fi
    fi
}

# Force rebuild function
force_rebuild() {
    log "Force rebuilding Flutter app..."
    cd "$FLUTTER_DIR"
    flutter clean
    flutter build linux --release
    if [ $? -ne 0 ]; then
        error "Flutter build failed!"
        exit 1
    fi
    log_success "Flutter app rebuilt"
}

# Function to start web server
start_web_server() {
    log "Starting web server..."
    cd "$SOFTWARE_DIR"
    
    # Kill any existing web server
    pkill -f "python.*main.py" 2>/dev/null || true
    sleep 1
    
    # Activate virtual environment if it exists
    if [ -d "$SOFTWARE_DIR/venv" ]; then
        source "$SOFTWARE_DIR/venv/bin/activate"
        log "Using virtual environment for Python dependencies"
    fi
    
    # Start web server in background
    export PYTHONPATH="$SOFTWARE_DIR"
    nohup python3 -m blackbox.main > /tmp/blackbox_web.log 2>&1 &
    WEB_PID=$!
    
    # Wait a moment and check if it started
    sleep 2
    if kill -0 $WEB_PID 2>/dev/null; then
        success "Web server started (PID: $WEB_PID)"
        echo $WEB_PID > /tmp/blackbox_web.pid
    else
        error "Failed to start web server"
        cat /tmp/blackbox_web.log
        return 1
    fi
}

# Function to start transcription worker
start_transcription_worker() {
    log "Starting transcription worker..."
    cd "$SOFTWARE_DIR"
    
    # Kill any existing transcription worker
    pkill -f "python.*transcription" 2>/dev/null || true
    sleep 1
    
    # Activate virtual environment if it exists
    if [ -d "$SOFTWARE_DIR/venv" ]; then
        source "$SOFTWARE_DIR/venv/bin/activate"
        log "Using virtual environment for transcription worker"
    fi
    
    # Start transcription worker in background
    export PYTHONPATH="$SOFTWARE_DIR"
    nohup python3 -m blackbox.transcription.worker > /tmp/blackbox_transcription.log 2>&1 &
    TRANSCRIPTION_PID=$!
    
    # Wait a moment and check if it started
    sleep 2
    if kill -0 $TRANSCRIPTION_PID 2>/dev/null; then
        success "Transcription worker started (PID: $TRANSCRIPTION_PID)"
        echo $TRANSCRIPTION_PID > /tmp/blackbox_transcription.pid
    else
        error "Failed to start transcription worker"
        cat /tmp/blackbox_transcription.log
        return 1
    fi
}

# Function to check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    # Check if Flutter is available
    if ! command -v flutter &> /dev/null; then
        error "Flutter is not installed or not in PATH"
        exit 1
    fi
    
    # Check if Python dependencies are available
    cd "$SOFTWARE_DIR"
    if ! python3 -c "import flask, blackbox" &> /dev/null; then
        warn "Some Python dependencies may be missing"
    fi
    
    success "Dependencies check completed"
}

# Function to stop services (for cleanup)
stop_services() {
    log "Stopping services..."
    # Stop web server
    pkill -f "python.*main.py" 2>/dev/null || true
    # Stop transcription worker
    pkill -f "python.*transcription" 2>/dev/null || true
    # Stop Flutter app
    pkill -f "flutter_frontend" 2>/dev/null || true
    # Clean up PID files
    rm -f /tmp/blackbox_web.pid 2>/dev/null || true
    rm -f /tmp/blackbox_transcription.pid 2>/dev/null || true
    success "Services stopped"
}

# Function to start the app
start_app() {
    log "Starting Blackbox Holiday App..."
    
    # Set display if not set
    export DISPLAY=${DISPLAY:-:0}
    
    # Change to app directory
    cd "$BUILD_DIR"
    
    # Start the app
    "$APP_BINARY" &
    APP_PID=$!
    
    success "Blackbox Holiday App started (PID: $APP_PID)"
    
    # Wait for app to finish
    wait $APP_PID
    APP_EXIT_CODE=$?
    
    if [ $APP_EXIT_CODE -eq 0 ]; then
        success "App exited normally"
    else
        warn "App exited with code: $APP_EXIT_CODE"
    fi
}

# Main application startup function
start_application() {
    log "Starting Blackbox Holiday Application..."
    
    # Check dependencies
    check_dependencies
    
    # Check and build if needed
    check_build
    
    # Start web server
    start_web_server
    
    # Wait a moment for services to initialize
    sleep 3
    
    # Start Flutter app
    start_app
    
    log_success "Blackbox Holiday Application completed!"
}

# Cleanup function
cleanup() {
    log "Cleaning up..."
    stop_services
}

# Set trap for cleanup on exit
trap cleanup EXIT

# Main script logic
case "${1:-}" in
    "stop")
        log "Stopping services..."
        cleanup
        log_success "Services stopped"
        ;;
    "build")
        check_build
        ;;
    "rebuild")
        force_rebuild
        ;;
    "start"|"")
        # Default action - start application
        start_application
        ;;
    *)
        echo "Usage: $0 [start|stop|build|rebuild]"
        echo "  start   - Start the application (default)"
        echo "  stop    - Stop all services"
        echo "  build   - Check and build if needed"
        echo "  rebuild - Force rebuild the app"
        echo "  (no arg) - Start the application"
        exit 1
        ;;
esac

# Handle command line arguments
case "${1:-}" in
    "stop")
        stop_services
        exit 0
        ;;
    "build")
        check_build
        exit 0
        ;;
    "rebuild")
        log "Force rebuilding Flutter app..."
        cd "$FLUTTER_DIR"
        flutter clean
        flutter build linux --release
        success "Rebuild completed"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "Usage: $0 [stop|build|rebuild]"
        echo "  stop    - Stop all services"
        echo "  build   - Check and build if needed"
        echo "  rebuild - Force rebuild the app"
        echo "  (no arg) - Start the application"
        exit 1
        ;;
esac