#!/bin/bash
# Remote Desktop System — Local Test Script
# This script sets up the environment, starts the server, and launches the Flutter client.
# Designed for local testing on a single machine or across a LAN.

set -e

SERVER_DIR="$(cd "$(dirname "$0")/server" && pwd)"
CLIENT_DIR="$(cd "$(dirname "$0")/client" && pwd)"
ENV_FILE="$SERVER_DIR/.env"
ENV_EXAMPLE="$SERVER_DIR/.env.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=============================================="
echo "  Remote Desktop System"
echo "  Local/LAN Test Script"
echo "=============================================="
echo ""

# Step 1: Check prerequisites
echo -n "Checking Flutter... "
if command -v flutter &> /dev/null; then
    flutter_version=$(flutter --version 2>&1 | head -1)
    echo -e "${GREEN}✓${NC} $flutter_version"
else
    echo -e "${RED}✗ Flutter not found${NC}"
    echo "Install: brew install --cask flutter"
    exit 1
fi

echo -n "Checking Node.js... "
if command -v node &> /dev/null; then
    node_version=$(node --version)
    echo -e "${GREEN}✓${NC} $node_version"
else
    echo -e "${RED}✗ Node.js not found${NC}"
    exit 1
fi

echo -n "Checking npm... "
if command -v npm &> /dev/null; then
    npm_version=$(npm --version)
    echo -e "${GREEN}✓${NC} v$npm_version"
else
    echo -e "${RED}✗ npm not found${NC}"
    exit 1
fi

echo ""

# Step 2: Setup server
echo -n "Setting up server... "
if [ ! -f "$SERVER_DIR/node_modules" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo "Installing dependencies..."
    cd "$SERVER_DIR" && npm install
fi
echo -e "${GREEN}✓${NC} Ready"

# Step 3: Setup client
echo -n "Setting up Flutter client... "
if [ ! -d "$CLIENT_DIR/.dart_tool" ]; then
    echo "Getting packages..."
    cd "$CLIENT_DIR" && flutter pub get
fi
echo -e "${GREEN}✓${NC} Ready"

# Step 4: Start server in background
echo ""
echo "Starting server on port 3000..."
cd "$SERVER_DIR"

# Check if server is already running
if pgrep -f "node.*index.js" > /dev/null; then
    echo -e "${YELLOW}⚠ Server already running.${NC}"
    read -p "Kill existing server? (y/N): " confirm
    if [[ "$confirm" == [yY] ]]; then
        pkill -f "node.*index.js"
        sleep 1
    fi
fi

# Start server in background
cd "$SERVER_DIR"
npm run dev &
SERVER_PID=$!
sleep 2

# Verify server is running
echo -n "Verifying server... "
if curl -s http://localhost:3000/health | grep -q '"status"'; then
    echo -e "${GREEN}✓${NC} Server is running (PID: $SERVER_PID)"
    echo "  Health: $(curl -s http://localhost:3000/health)"
else
    echo -e "${RED}✗ Server failed to start${NC}"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "=============================================="
echo "  Server is running at:"
echo "    HTTP:  http://localhost:3000"
echo "    WS:    ws://localhost:3000/signal"
echo ""
echo "  To connect from another machine on the LAN:"
echo "    HTTP:  http://<YOUR-IP>:3000"
echo "    WS:    ws://<YOUR-IP>:3000/signal"
echo ""
echo "  Find your LAN IP with:"
echo "    ipconfig getifaddr en0    # WiFi"
echo "    ipconfig getifaddr en1    # Ethernet"
echo "=============================================="
echo ""

# Step 5: Launch Flutter client
echo "Launching Flutter client..."
read -p "Open in Controller mode? (y) for Controller, (v) for Viewer [y]: " mode
mode=${mode:-y}

cd "$CLIENT_DIR"

if [[ "$mode" == [yY] ]]; then
    echo ""
    echo -e "${GREEN}Starting CONTROLLER client...${NC}"
    echo "On the other machine, run this client as VIEWER to test."
    flutter run -d macos
else
    echo ""
    echo -e "${GREEN}Starting VIEWER client...${NC}"
    echo "First, start a CONTROLLER on another machine or terminal."
    flutter run -d macos
fi

# Cleanup on exit
trap "echo ''; echo 'Stopping server (PID: $SERVER_PID)...'; kill $SERVER_PID 2>/dev/null; echo 'Done.'; exit 0" EXIT
