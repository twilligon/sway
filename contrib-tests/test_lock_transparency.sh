#!/bin/bash
#
# End-to-end test for sway-session-lock-config-v1 transparency.
#
# Tests the patched swaylock against the patched sway compositor.
# Uses swaybg for a known background color, then verifies pixel values
# through screencopy screenshots.
#
set -eo pipefail

export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

SWAY_BIN="/home/user/sway/build/sway/sway"
SWAYLOCK_BIN="/tmp/swaylock/build/swaylock"
SWAYMSG_BIN="/home/user/sway/build/swaymsg/swaymsg"
SCREENSHOT_BIN="/tmp/test-lock/screenshot"
OUTDIR="/tmp/test-lock/results"
mkdir -p "$OUTDIR"

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    kill $SWAYLOCK_PID 2>/dev/null || true
    kill $SWAYBG_PID 2>/dev/null || true
    kill $SWAY_PID 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

# Kill any leftovers
killall -9 sway swaylock swaybg 2>/dev/null || true
sleep 1
rm -f "$XDG_RUNTIME_DIR"/wayland-*

echo "=== Starting headless sway ==="
WLR_BACKENDS=headless WLR_RENDERER=pixman \
    "$SWAY_BIN" -c /tmp/test-lock/sway-test-config -d 2>"$OUTDIR/sway.log" &
SWAY_PID=$!
sleep 3

if ! kill -0 $SWAY_PID 2>/dev/null; then
    echo "FATAL: Sway failed to start"
    tail -30 "$OUTDIR/sway.log"
    exit 1
fi

# Find the socket
WAYLAND_DISPLAY=""
for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
    if [ -S "$sock" ]; then
        WAYLAND_DISPLAY=$(basename "$sock")
        break
    fi
done
if [ -z "$WAYLAND_DISPLAY" ]; then
    echo "FATAL: No wayland socket found"
    exit 1
fi
export WAYLAND_DISPLAY
echo "Sway running: PID=$SWAY_PID, WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

# Create a headless output at known resolution
"$SWAYMSG_BIN" 'output HEADLESS-1 resolution 320x240' 2>/dev/null || true
sleep 1

echo ""
echo "=== Starting swaybg with blue background ==="
# Use a distinctive blue so we can detect it through the lock surface
swaybg -c '#0000FF' -m solid_color 2>"$OUTDIR/swaybg.log" &
SWAYBG_PID=$!
sleep 2

# Take "before" screenshot
echo ""
echo "=== Screenshot 1: Desktop (should be blue) ==="
"$SCREENSHOT_BIN" "$OUTDIR/1_desktop.ppm" 2>&1
echo "Saved: $OUTDIR/1_desktop.ppm"

# Read center pixel of desktop screenshot
read_center_pixel() {
    local ppm="$1"
    python3 -c "
import sys
with open('$ppm', 'rb') as f:
    magic = f.readline().strip()
    dims = f.readline().strip()
    maxval = f.readline().strip()
    w, h = map(int, dims.split())
    data = f.read()
    # Center pixel
    cx, cy = w//2, h//2
    offset = (cy * w + cx) * 3
    r, g, b = data[offset], data[offset+1], data[offset+2]
    print(f'R={r} G={g} B={b}')
"
}

echo "Desktop center pixel: $(read_center_pixel "$OUTDIR/1_desktop.ppm")"

echo ""
echo "=== Running swaylock with semi-transparent green ==="
# Color RRGGBBAA: green with 50% alpha = 00FF0080
# This means: R=0, G=255, B=0, Alpha=128 (50%)
"$SWAYLOCK_BIN" --color '00FF0080' -d 2>"$OUTDIR/swaylock.log" &
SWAYLOCK_PID=$!
sleep 3

if ! kill -0 $SWAYLOCK_PID 2>/dev/null; then
    echo "WARNING: swaylock exited early"
    cat "$OUTDIR/swaylock.log"
fi

# Take screenshot with lock active
echo ""
echo "=== Screenshot 2: Lock screen (transparent bg expected) ==="
"$SCREENSHOT_BIN" "$OUTDIR/2_locked.ppm" 2>&1
echo "Saved: $OUTDIR/2_locked.ppm"
echo "Locked center pixel: $(read_center_pixel "$OUTDIR/2_locked.ppm")"

echo ""
echo "=== Screenshot analysis ==="
python3 << 'PYEOF'
import sys

def read_ppm(path):
    with open(path, 'rb') as f:
        magic = f.readline().strip()
        # Skip comments
        line = f.readline().strip()
        while line.startswith(b'#'):
            line = f.readline().strip()
        w, h = map(int, line.split())
        maxval = int(f.readline().strip())
        data = f.read()
    return w, h, data

def center_pixel(path):
    w, h, data = read_ppm(path)
    cx, cy = w // 2, h // 2
    off = (cy * w + cx) * 3
    return data[off], data[off+1], data[off+2]

desktop = center_pixel("/tmp/test-lock/results/1_desktop.ppm")
locked = center_pixel("/tmp/test-lock/results/2_locked.ppm")

print(f"Desktop pixel: R={desktop[0]} G={desktop[1]} B={desktop[2]}")
print(f"Locked  pixel: R={locked[0]} G={locked[1]} B={locked[2]}")
print()

# Expected behavior:
# Desktop: pure blue (0, 0, 255)
# Lock surface: 50% green, color 00FF0080 in swaylock's RRGGBBAA format
#   swaylock's parse_color shifts 6-char to (RRGGBB << 8) | 0xFF
#   For 8-char "00FF0080": parsed as uint32 0x00FF0080
#   cairo_set_source_u32 extracts:
#     R = (0x00FF0080 >> 24) & 0xFF = 0x00
#     G = (0x00FF0080 >> 16) & 0xFF = 0xFF
#     B = (0x00FF0080 >> 8)  & 0xFF = 0x00
#     A = (0x00FF0080 >> 0)  & 0xFF = 0x80 = 128/255 ≈ 0.502
#
# Cairo OPERATOR_SOURCE replaces the buffer contents, so the buffer
# has straight-alpha RGBA (0, 255, 0, 128). Wayland expects premultiplied,
# but cairo_image_surface uses CAIRO_FORMAT_ARGB32 which stores premultiplied.
# cairo_set_source_rgba(0, 1.0, 0, 0.502) + paint with OPERATOR_SOURCE
# gives premultiplied: A=128, R=0, G=128, B=0 in the buffer.
#
# Compositing (premultiplied over):
#   result = src + dst * (1 - src_alpha)
#
# With OPAQUE black bg (sway's default lock bg):
#   result = (0, 128, 0) + (0, 0, 0) * 0.498 = (0, 128, 0)
#
# With TRANSPARENT bg (blue desktop shows through):
#   result = (0, 128, 0) + (0, 0, 255) * 0.498 = (0, 128, 127)
#
# Key test: if B > 0 in the locked screenshot, transparency is working!

tests_passed = 0
tests_total = 0

# Test 1: Desktop should be blue
tests_total += 1
if desktop[2] > 200:
    print(f"TEST 1 PASS: Desktop is blue (B={desktop[2]})")
    tests_passed += 1
else:
    print(f"TEST 1 FAIL: Desktop should be blue (B={desktop[2]}, expected >200)")

# Test 2: Locked screen should have green component (from lock surface)
tests_total += 1
if locked[1] > 100:
    print(f"TEST 2 PASS: Lock surface green present (G={locked[1]})")
    tests_passed += 1
else:
    print(f"TEST 2 FAIL: Lock surface should show green (G={locked[1]}, expected >100)")

# Test 3: THE KEY TEST - blue channel in locked screenshot
# If transparency works: B should be ~127 (blue desktop visible through green overlay)
# If opaque bg: B should be ~0 (black bg, no blue bleed)
tests_total += 1
if locked[2] > 80:
    print(f"TEST 3 PASS: Desktop blue visible through lock! (B={locked[2]}, expected ~127)")
    print(f"  -> Transparency IS working!")
    tests_passed += 1
else:
    print(f"TEST 3 FAIL: No blue visible through lock (B={locked[2]}, expected >80)")
    print(f"  -> Transparency NOT working or desktop not visible")

# Test 4: Locked pixel should differ from pure green-over-black
tests_total += 1
green_over_black = (0, 128, 0)
if locked != green_over_black:
    print(f"TEST 4 PASS: Locked pixel differs from green-over-black {green_over_black}")
    tests_passed += 1
else:
    print(f"TEST 4 FAIL: Locked pixel equals green-over-black (no transparency effect)")

print()
print(f"{'='*50}")
print(f"RESULTS: {tests_passed}/{tests_total} tests passed")
print(f"{'='*50}")

sys.exit(0 if tests_passed == tests_total else 1)
PYEOF

echo ""
echo "=== Swaylock log ==="
cat "$OUTDIR/swaylock.log"
echo ""
echo "=== Sway log (lock-related) ==="
grep -i "lock\|transparen" "$OUTDIR/sway.log" | tail -20 || true
