#!/bin/bash
# Quick verify: install server deps and test startup
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"

echo "Installing server dependencies..."
cd "$SERVER_DIR"
npm install 2>&1

echo ""
echo "Creating .env file..."
if [ ! -f "$SERVER_DIR/.env" ]; then
    cp "$SERVER_DIR/.env.example" "$SERVER_DIR/.env"
    echo ".env created from .env.example"
else
    echo ".env already exists, skipping"
fi

echo ""
echo "Quick test: starting server for 3 seconds..."
timeout 3 node "$SERVER_DIR/src/index.js" 2>&1 || true

echo ""
echo "Setup complete! You can now:"
echo "  1. cd $SERVER_DIR && npm run dev   (start server)"
echo "  2. cd $SCRIPT_DIR/client && flutter run -d macos   (start client)"
echo "  3. Or run: $SCRIPT_DIR/test-local.sh   (full test)"
