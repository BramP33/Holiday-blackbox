#!/bin/bash

# GUI-friendly Blackbox Holiday App Launcher
# This script starts the application silently in the background

PROJECT_ROOT="/home/blackbox/Holiday-blackbox"

# Set up environment variables that might be missing in GUI context
export PATH="$HOME/flutter/bin:$PATH"
export DISPLAY=${DISPLAY:-:0}

# Log file for GUI debugging  
LOG_FILE="/tmp/blackbox_gui_launcher.log"
echo "$(date): Starting Blackbox Holiday App" > "$LOG_FILE"
echo "$(date): PATH=$PATH" >> "$LOG_FILE"

# Start the main application in background
"$PROJECT_ROOT/start_blackbox.sh" >> "$LOG_FILE" 2>&1 &
LAUNCH_PID=$!

# Log the result
echo "$(date): Launch command executed (PID: $LAUNCH_PID)" >> "$LOG_FILE"