#!/bin/bash
#
# Test for abandoned session lock fallback behavior.
#
# When a lock client crashes (disconnects without unlocking), sway should:
# 1. Switch the lock background to solid RED (1,0,0,1)
# 2. Ignore any further transparency requests
# 3. Keep the screen locked (red screen = security fallback)
#
# This test verifies that killing swaylock (simulating a crash) results
# in a solid red background, NOT a transparent one.
#
set -eo pipefail

export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

SWAY_BIN="/home/user/sway/build/sway/sway"
SWAYLOCK_BIN="/tmp/swaylock/build/swaylock"
SWAYMSG_BIN="/home/user/sway/build/swaymsg/swaymsg"
SCREENSHOT_BIN="/tmp/test-lock/screenshot"
OUTDIR="/tmp/test-lock/abandoned-results"
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

echo "=== Abandoned Lock Fallback Test ==="
echo ""

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
swaybg -c '#0000FF' -m solid_color 2>"$OUTDIR/swaybg.log" &
SWAYBG_PID=$!
sleep 2

# Take desktop screenshot
echo ""
echo "=== Screenshot 1: Desktop (should be blue) ==="
"$SCREENSHOT_BIN" "$OUTDIR/1_desktop.ppm" 2>&1
echo "Saved: $OUTDIR/1_desktop.ppm"

echo ""
echo "=== Starting swaylock with semi-transparent green ==="
# 00FF0080 = green with 50% alpha
"$SWAYLOCK_BIN" --color '00FF0080' -d 2>"$OUTDIR/swaylock.log" &
SWAYLOCK_PID=$!
sleep 3

if ! kill -0 $SWAYLOCK_PID 2>/dev/null; then
    echo "FATAL: swaylock exited early (can't test abandon)"
    cat "$OUTDIR/swaylock.log"
    exit 1
fi

# Take screenshot with transparency active
echo ""
echo "=== Screenshot 2: Locked with transparency (green over blue) ==="
"$SCREENSHOT_BIN" "$OUTDIR/2_locked_transparent.ppm" 2>&1
echo "Saved: $OUTDIR/2_locked_transparent.ppm"

# NOW: Kill swaylock to simulate a crash (abandon)
echo ""
echo "=== KILLING swaylock to simulate crash (triggering abandon) ==="
kill -9 $SWAYLOCK_PID 2>/dev/null || true
wait $SWAYLOCK_PID 2>/dev/null || true
SWAYLOCK_PID=""
echo "swaylock killed."

# Give sway time to process the abandoned lock
sleep 2

# Take screenshot after abandon - should be solid RED
echo ""
echo "=== Screenshot 3: After abandon (should be solid RED) ==="
"$SCREENSHOT_BIN" "$OUTDIR/3_abandoned.ppm" 2>&1
echo "Saved: $OUTDIR/3_abandoned.ppm"

echo ""
echo "=== Analyzing screenshots ==="
python3 << 'PYEOF'
import sys

def read_ppm(path):
    with open(path, 'rb') as f:
        magic = f.readline().strip()
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

desktop = center_pixel("/tmp/test-lock/abandoned-results/1_desktop.ppm")
locked = center_pixel("/tmp/test-lock/abandoned-results/2_locked_transparent.ppm")
abandoned = center_pixel("/tmp/test-lock/abandoned-results/3_abandoned.ppm")

print(f"Desktop pixel:     R={desktop[0]:3d} G={desktop[1]:3d} B={desktop[2]:3d}")
print(f"Locked pixel:      R={locked[0]:3d} G={locked[1]:3d} B={locked[2]:3d}")
print(f"Abandoned pixel:   R={abandoned[0]:3d} G={abandoned[1]:3d} B={abandoned[2]:3d}")
print()

tests_passed = 0
tests_total = 0

# Test 1: Desktop should be blue
tests_total += 1
if desktop[2] > 200 and desktop[0] < 50 and desktop[1] < 50:
    print(f"TEST 1 PASS: Desktop is blue (R={desktop[0]} G={desktop[1]} B={desktop[2]})")
    tests_passed += 1
else:
    print(f"TEST 1 FAIL: Desktop should be blue (R={desktop[0]} G={desktop[1]} B={desktop[2]})")

# Test 2: Locked screenshot should show transparency (blue channel present)
# With transparent green (50% alpha) over blue desktop: B should be > 0
tests_total += 1
if locked[2] > 50:
    print(f"TEST 2 PASS: Transparency working - blue visible through lock (B={locked[2]})")
    tests_passed += 1
else:
    print(f"TEST 2 FAIL: No blue visible through lock (B={locked[2]}, expected >50)")

# Test 3: THE KEY TEST - Abandoned screen should be solid RED
# When lock is abandoned, sway sets bg to (1.0, 0.0, 0.0, 1.0) = solid red
# The lock surface is gone (client died), so only the red bg rect remains
tests_total += 1
if abandoned[0] > 200:
    print(f"TEST 3 PASS: Abandoned screen has high red (R={abandoned[0]})")
    tests_passed += 1
else:
    print(f"TEST 3 FAIL: Abandoned screen red too low (R={abandoned[0]}, expected >200)")

# Test 4: Abandoned screen should NOT be transparent (no blue showing through)
# The abandoned bg uses alpha=1.0, so blue desktop should NOT be visible
tests_total += 1
if abandoned[2] < 30:
    print(f"TEST 4 PASS: Abandoned screen blocks blue desktop (B={abandoned[2]})")
    tests_passed += 1
else:
    print(f"TEST 4 FAIL: Blue visible through abandoned lock! (B={abandoned[2]}, expected <30)")
    print(f"  -> This means abandoned lock is TRANSPARENT - security issue!")

# Test 5: Abandoned green channel should be ~0 (pure red, not blended)
tests_total += 1
if abandoned[1] < 30:
    print(f"TEST 5 PASS: Abandoned screen has no green (G={abandoned[1]})")
    tests_passed += 1
else:
    print(f"TEST 5 FAIL: Green present in abandoned lock (G={abandoned[1]}, expected <30)")

# Test 6: Abandoned screen should differ from the transparent locked screen
tests_total += 1
if abandoned != locked:
    print(f"TEST 6 PASS: Abandoned screen differs from transparent locked screen")
    tests_passed += 1
else:
    print(f"TEST 6 FAIL: Abandoned screen identical to transparent locked screen")

print()
print(f"{'='*60}")
print(f"RESULTS: {tests_passed}/{tests_total} tests passed")
if tests_passed == tests_total:
    print("ALL TESTS PASSED - Abandoned lock shows opaque red fallback!")
else:
    print("SOME TESTS FAILED - Check abandoned lock behavior!")
print(f"{'='*60}")

sys.exit(0 if tests_passed == tests_total else 1)
PYEOF

echo ""
echo "=== Sway log (lock/abandon-related) ==="
grep -i "lock\|abandon\|transparen" "$OUTDIR/sway.log" | tail -30 || true
