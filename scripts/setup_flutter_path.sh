#!/bin/bash

# Setup Flutter PATH - detects Flutter installation and adds to shell profile
# This script finds Flutter installed by VS Code or other methods and configures your shell

set -e

echo "🔍 Searching for Flutter installation..."

# Common Flutter installation locations
FLUTTER_LOCATIONS=(
    "$HOME/flutter/bin"                    # Manual install in home
    "$HOME/snap/flutter/common/flutter/bin" # Snap install
    "/opt/flutter/bin"                     # System install
    "$HOME/development/flutter/bin"        # Common dev folder
    "$HOME/.flutter/bin"                   # Hidden folder
    "$HOME/fvm/default/bin"                # FVM (Flutter Version Manager)
)

# Try to find flutter command in common locations
FLUTTER_BIN=""
for location in "${FLUTTER_LOCATIONS[@]}"; do
    if [ -f "$location/flutter" ]; then
        FLUTTER_BIN="$location"
        echo "✅ Found Flutter at: $FLUTTER_BIN"
        break
    fi
done

# If not found in common locations, try to find it using 'which' (if already in PATH)
if [ -z "$FLUTTER_BIN" ]; then
    if command -v flutter >/dev/null 2>&1; then
        FLUTTER_BIN=$(dirname $(which flutter))
        echo "✅ Found Flutter in PATH at: $FLUTTER_BIN"
    fi
fi

# If still not found, try to find anywhere in home directory
if [ -z "$FLUTTER_BIN" ]; then
    echo "🔎 Searching entire home directory (this may take a moment)..."
    FOUND=$(find "$HOME" -name "flutter" -type f -path "*/bin/flutter" 2>/dev/null | head -n 1)
    if [ -n "$FOUND" ]; then
        FLUTTER_BIN=$(dirname "$FOUND")
        echo "✅ Found Flutter at: $FLUTTER_BIN"
    fi
fi

# If STILL not found, give up
if [ -z "$FLUTTER_BIN" ]; then
    echo "❌ ERROR: Could not find Flutter installation!"
    echo ""
    echo "Please install Flutter first:"
    echo "  1. Via snap: sudo snap install flutter --classic"
    echo "  2. Via manual download: https://docs.flutter.dev/get-started/install/linux"
    echo "  3. Via VS Code: Install Flutter extension and follow prompts"
    echo ""
    exit 1
fi

# Get the directory without /bin
FLUTTER_DIR=$(dirname "$FLUTTER_BIN")

echo ""
echo "Flutter location: $FLUTTER_DIR"
echo "Flutter binary: $FLUTTER_BIN/flutter"
echo ""

# Test Flutter
echo "🧪 Testing Flutter installation..."
"$FLUTTER_BIN/flutter" --version || {
    echo "❌ ERROR: Flutter command exists but failed to run!"
    exit 1
}

echo ""
echo "✅ Flutter is working!"
echo ""

# Determine which shell config file to use
SHELL_NAME=$(basename "$SHELL")
CONFIG_FILE=""

case "$SHELL_NAME" in
    bash)
        if [ -f "$HOME/.bashrc" ]; then
            CONFIG_FILE="$HOME/.bashrc"
        elif [ -f "$HOME/.bash_profile" ]; then
            CONFIG_FILE="$HOME/.bash_profile"
        else
            CONFIG_FILE="$HOME/.bashrc"
        fi
        ;;
    zsh)
        CONFIG_FILE="$HOME/.zshrc"
        ;;
    *)
        echo "⚠️  Unknown shell: $SHELL_NAME"
        CONFIG_FILE="$HOME/.profile"
        ;;
esac

echo "📝 Shell configuration file: $CONFIG_FILE"
echo ""

# Check if Flutter is already in PATH config
if grep -q "flutter/bin" "$CONFIG_FILE" 2>/dev/null; then
    echo "ℹ️  Flutter PATH already exists in $CONFIG_FILE"
    echo ""
    echo "Current Flutter PATH line(s):"
    grep "flutter/bin" "$CONFIG_FILE"
    echo ""
    read -p "Do you want to update it? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping PATH update."
        echo ""
        echo "To use Flutter in current terminal, run:"
        echo "  export PATH=\"$FLUTTER_BIN:\$PATH\""
        exit 0
    fi
    
    # Remove old Flutter PATH entries
    echo "🗑️  Removing old Flutter PATH entries..."
    # Create temp file without Flutter PATH lines
    grep -v "flutter/bin" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" || true
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
fi

# Add Flutter to PATH
echo "➕ Adding Flutter to PATH in $CONFIG_FILE"
cat >> "$CONFIG_FILE" << EOF

# Flutter PATH (added by Holiday-blackbox setup)
export PATH="$FLUTTER_BIN:\$PATH"
EOF

echo "✅ Flutter PATH added to $CONFIG_FILE"
echo ""
echo "📋 Next steps:"
echo ""
echo "1. Reload your shell configuration:"
echo "   source $CONFIG_FILE"
echo ""
echo "2. Or close and reopen your terminal"
echo ""
echo "3. Verify Flutter is in PATH:"
echo "   flutter --version"
echo ""
echo "4. For current terminal session, run:"
echo "   export PATH=\"$FLUTTER_BIN:\$PATH\""
echo ""

# Offer to source it now
read -p "Do you want to reload the shell configuration now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo "🔄 Reloading shell configuration..."
    # Note: This only affects the current script, user still needs to source or restart
    source "$CONFIG_FILE"
    echo "✅ Configuration reloaded for this script"
    echo ""
    echo "⚠️  NOTE: You still need to source the file in your terminal or restart it:"
    echo "   source $CONFIG_FILE"
fi

echo ""
echo "🎉 Flutter setup complete!"
