#!/bin/bash
# Play an mcap bag and stream it live over Foxglove WebSocket.
# Usage: ./scripts/play_mcap_foxglove.sh <path_to_mcap> [additional ros2 bag play args, e.g. --loop --rate 0.5]
#
# Runs inside the mola_ws image (ROS 2 Humble + rosbag2 mcap plugin + foxglove_bridge)
# on the host network, so Foxglove on any machine can connect to ws://<thor-ip>:8765.

set -e

BAG_PATH="${1}"
shift || true

if [ -z "$BAG_PATH" ] || [ ! -f "$BAG_PATH" ]; then
    echo "Usage: $0 <path_to_mcap> [additional ros2 bag play args]"
    exit 1
fi

IMAGE="${IMAGE:-mola_ws}"
PORT="${FOXGLOVE_PORT:-8765}"
BAG_DIR="$(cd "$(dirname "$BAG_PATH")" && pwd)"
BAG_FILE="$(basename "$BAG_PATH")"

echo "Bag:       $BAG_PATH"
echo "Foxglove:  ws://$(hostname -I | awk '{print $1}'):$PORT"
echo "Press Ctrl+C to stop."
echo ""

docker run --rm -it \
    --name mcap_play \
    --network=host \
    --entrypoint bash \
    -v "$BAG_DIR":/bag:ro \
    "$IMAGE" -c "
        source /opt/ros/humble/setup.bash
        ros2 run foxglove_bridge foxglove_bridge --ros-args -p port:=$PORT &
        BRIDGE_PID=\$!
        trap 'kill \$BRIDGE_PID 2>/dev/null' EXIT
        sleep 2
        ros2 bag play /bag/$BAG_FILE $*
    "
