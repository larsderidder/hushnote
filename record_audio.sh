#!/bin/bash

# Audio recording script for meetings
# Records system audio and microphone to a WAV file

set -euo pipefail

# Check for dependencies
if ! command -v pactl &> /dev/null; then
    echo "Error: pactl not found. Install pulseaudio-utils or pipewire-pulse"
    exit 1
fi

if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg not found. Install ffmpeg"
    exit 1
fi

# Configuration
OUTPUT_DIR="${RECORDINGS_DIR:-./recordings}"
DATE=$(date +%Y%m%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MEETING_DIR="${OUTPUT_DIR}/${DATE}/meeting_${TIMESTAMP}"
OUTPUT_FILE="${MEETING_DIR}/meeting_${TIMESTAMP}.wav"
LOADED_AUDIO_MODULES=()
AUDIO_MONITOR_PIDS=()
HUSHNOTE_AUDIO_MONITOR="${HUSHNOTE_AUDIO_MONITOR:-true}"
HUSHNOTE_AUDIO_MONITOR_GRACE="${HUSHNOTE_AUDIO_MONITOR_GRACE:-20}"
HUSHNOTE_AUDIO_MONITOR_INTERVAL="${HUSHNOTE_AUDIO_MONITOR_INTERVAL:-30}"
HUSHNOTE_AUDIO_MONITOR_SAMPLE="${HUSHNOTE_AUDIO_MONITOR_SAMPLE:-3}"
HUSHNOTE_AUDIO_MONITOR_WARN_AFTER="${HUSHNOTE_AUDIO_MONITOR_WARN_AFTER:-2}"
HUSHNOTE_AUDIO_SILENCE_MAX_DB="${HUSHNOTE_AUDIO_SILENCE_MAX_DB:--60}"

cleanup_audio_modules() {
    local pid module
    for pid in "${AUDIO_MONITOR_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    for module in "${LOADED_AUDIO_MODULES[@]:-}"; do
        pactl unload-module "$module" >/dev/null 2>&1 || true
    done
}

trap cleanup_audio_modules EXIT

# Parse arguments
DURATION=""
TITLE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -t|--title)
            TITLE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-d DURATION] [-o OUTPUT_FILE] [-t TITLE]"
            echo "  -d, --duration    Recording duration (e.g., 3600 for 1 hour)"
            echo "  -o, --output      Output file path (default: ./recordings/meeting_TIMESTAMP.wav)"
            echo "  -t, --title       Meeting title"
            echo ""
            echo "Environment variables:"
            echo "  RECORDINGS_DIR    Directory for recordings (default: ./recordings)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create output directory
mkdir -p "$(dirname "$OUTPUT_FILE")"

notify_audio_warning() {
    local title="$1"
    local body="$2"
    echo "Warning: $body" >&2
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical -a hushnote "$title" "$body" >/dev/null 2>&1 || true
    fi
}

sample_audio_max_volume() {
    local source="$1"
    local sample_file
    sample_file=$(mktemp --suffix=.wav)

    if [ "$RECORD_BACKEND" = "pw-record" ]; then
        timeout "$HUSHNOTE_AUDIO_MONITOR_SAMPLE" pw-record \
            --target "$source" \
            --rate 16000 \
            --channels 1 \
            --format s16 \
            "$sample_file" >/dev/null 2>&1 || true
    else
        timeout "$HUSHNOTE_AUDIO_MONITOR_SAMPLE" ffmpeg \
            -hide_banner \
            -nostats \
            -f pulse \
            -i "$source" \
            -t "$HUSHNOTE_AUDIO_MONITOR_SAMPLE" \
            -ar 16000 \
            -ac 1 \
            -c:a pcm_s16le \
            "$sample_file" >/dev/null 2>&1 || true
    fi

    if [ ! -s "$sample_file" ]; then
        rm -f "$sample_file"
        echo "-inf"
        return
    fi

    ffmpeg -hide_banner -nostats -i "$sample_file" -af volumedetect -f null - 2>&1 \
        | awk '/max_volume:/ { print $5; found=1 } END { if (!found) print "-inf" }'
    rm -f "$sample_file"
}

is_silent_level() {
    local level="$1"
    [ "$level" = "-inf" ] && return 0
    awk -v level="$level" -v threshold="$HUSHNOTE_AUDIO_SILENCE_MAX_DB" 'BEGIN { exit !(level < threshold) }'
}

monitor_audio_source() {
    local label="$1"
    local source="$2"
    local silent_count=0
    local warned=false
    local level

    sleep "$HUSHNOTE_AUDIO_MONITOR_GRACE"
    while true; do
        level=$(sample_audio_max_volume "$source")
        if is_silent_level "$level"; then
            silent_count=$((silent_count + 1))
        else
            echo "Audio monitor verified $label (${level} dB max); stopping monitor" >&2
            return 0
        fi

        if [ "$silent_count" -ge "$HUSHNOTE_AUDIO_MONITOR_WARN_AFTER" ] && [ "$warned" = false ]; then
            notify_audio_warning \
                "HushNote audio warning" \
                "$label has not produced audio yet (${level} dB max). Check meeting audio capture."
            warned=true
        fi

        sleep "$HUSHNOTE_AUDIO_MONITOR_INTERVAL"
    done
}

stop_recording_command() {
    if [ -n "${RECORDING_PID:-}" ]; then
        kill -INT "$RECORDING_PID" >/dev/null 2>&1 || true
    fi
    if [ -n "${RECORDING_TIMER_PID:-}" ]; then
        kill "$RECORDING_TIMER_PID" >/dev/null 2>&1 || true
    fi
}

run_recording_command() {
    local duration="$1"
    shift
    local status

    RECORDING_PID=""
    RECORDING_TIMER_PID=""
    trap stop_recording_command INT TERM

    "$@" &
    RECORDING_PID="$!"

    if [ -n "$duration" ]; then
        (sleep "$duration"; kill -TERM "$RECORDING_PID" >/dev/null 2>&1 || true) &
        RECORDING_TIMER_PID="$!"
    fi

    wait "$RECORDING_PID"
    status=$?

    if [ -n "$RECORDING_TIMER_PID" ]; then
        kill "$RECORDING_TIMER_PID" >/dev/null 2>&1 || true
        wait "$RECORDING_TIMER_PID" >/dev/null 2>&1 || true
    fi

    trap - INT TERM
    return "$status"
}

start_audio_monitor() {
    local label="$1"
    local source="$2"

    case "${HUSHNOTE_AUDIO_MONITOR,,}" in
        false|no|0)
            return
            ;;
    esac

    monitor_audio_source "$label" "$source" &
    AUDIO_MONITOR_PIDS+=("$!")
    echo "Audio monitor enabled for $label: $source" >&2
}

# Determine audio source.
# AUDIO_SOURCE env var overrides everything.
# AUDIO_SOURCE_TYPE controls what to capture:
#   "microphone" (default) - default PulseAudio/PipeWire source (mic)
#   "monitor"              - monitor of default sink (captures output audio,
#                            needed for meeting audio on BT headsets)
#   "both"                 - mix microphone + sink monitor into one recording
#                            (captures both sides of a call)
if [ -n "${AUDIO_SOURCE:-}" ]; then
    RECORD_SOURCE="$AUDIO_SOURCE"
    AUDIO_SOURCE_TYPE="microphone"  # treat explicit source as single source
elif [ "${AUDIO_SOURCE_TYPE:-microphone}" = "monitor" ]; then
    RECORD_SOURCE="$(pactl get-default-sink).monitor"
elif [ "${AUDIO_SOURCE_TYPE:-microphone}" = "both" ]; then
    RECORD_SOURCE=""  # handled separately below
else
    RECORD_SOURCE="$(pactl get-default-source)"
fi

echo "Recording audio..." >&2
echo "Output file: $OUTPUT_FILE" >&2
if [ -n "$RECORD_SOURCE" ]; then
    echo "Audio source: $RECORD_SOURCE" >&2
else
    echo "Audio source: mic + output mix" >&2
fi
if [ -n "$DURATION" ]; then
    echo "Duration: ${DURATION}s" >&2
fi
echo "" >&2
echo "Press Ctrl+C to stop recording" >&2

# RECORD_BACKEND controls the recording tool:
#   "ffmpeg" (default) - ffmpeg with PulseAudio compat layer
#   "pw-record"        - pw-record, talks directly to PipeWire graph;
#                        required for BT headsets in HSP/HFP mode where
#                        ffmpeg -f pulse captures silence
RECORD_BACKEND="${RECORD_BACKEND:-ffmpeg}"

set +e
ffmpeg_exit_code=0

if [ "${AUDIO_SOURCE_TYPE:-microphone}" = "both" ]; then
    # Mix microphone and sink monitor into a single recording.
    MIC_SOURCE="$(pactl get-default-source)"
    MONITOR_SOURCE="$(pactl get-default-sink).monitor"
    echo "Mixing mic ($MIC_SOURCE) + monitor ($MONITOR_SOURCE)" >&2
    start_audio_monitor "microphone" "$MIC_SOURCE"
    start_audio_monitor "meeting output" "$MONITOR_SOURCE"

    if [ "$RECORD_BACKEND" = "pw-record" ]; then
        MIX_SINK="hushnote_mix_${TIMESTAMP}"
        NULL_MODULE=$(pactl load-module module-null-sink sink_name="$MIX_SINK" sink_properties="device.description=HushNote Mix")
        LOADED_AUDIO_MODULES+=("$NULL_MODULE")
        MIC_LOOP_MODULE=$(pactl load-module module-loopback source="$MIC_SOURCE" sink="$MIX_SINK" latency_msec=20)
        LOADED_AUDIO_MODULES+=("$MIC_LOOP_MODULE")
        MONITOR_LOOP_MODULE=$(pactl load-module module-loopback source="$MONITOR_SOURCE" sink="$MIX_SINK" latency_msec=20)
        LOADED_AUDIO_MODULES+=("$MONITOR_LOOP_MODULE")
        sleep 0.5

        PW_ARGS=(--target "${MIX_SINK}.monitor" --rate 16000 --channels 1 --format s16)
        run_recording_command "$DURATION" pw-record "${PW_ARGS[@]}" "$OUTPUT_FILE" >&2
        ffmpeg_exit_code=$?
    else
        FFMPEG_ARGS=(
            -f pulse -i "$MIC_SOURCE"
            -f pulse -i "$MONITOR_SOURCE"
            -filter_complex amix=inputs=2:duration=longest:normalize=0
            -ar 16000 -ac 1 -c:a pcm_s16le
        )
        [ -n "$DURATION" ] && FFMPEG_ARGS+=(-t "$DURATION")
        FFMPEG_ARGS+=("$OUTPUT_FILE")

        ffmpeg "${FFMPEG_ARGS[@]}" >&2
        ffmpeg_exit_code=$?
    fi

elif [ "$RECORD_BACKEND" = "pw-record" ]; then
    start_audio_monitor "audio source" "$RECORD_SOURCE"
    PW_ARGS=(--target "$RECORD_SOURCE" --rate 16000 --channels 1 --format s16)
    run_recording_command "$DURATION" pw-record "${PW_ARGS[@]}" "$OUTPUT_FILE" >&2
    ffmpeg_exit_code=$?

else
    start_audio_monitor "audio source" "$RECORD_SOURCE"
    FFMPEG_ARGS=(-f pulse -i "$RECORD_SOURCE")
    [ -n "$DURATION" ] && FFMPEG_ARGS+=(-t "$DURATION")
    FFMPEG_ARGS+=(-ar 16000 -ac 1 -c:a pcm_s16le "$OUTPUT_FILE")

    ffmpeg "${FFMPEG_ARGS[@]}" >&2
    ffmpeg_exit_code=$?
fi

set -e

# Always output filename if file was created, even if interrupted
if [ -f "$OUTPUT_FILE" ]; then
    echo "" >&2
    echo "Recording saved to: $OUTPUT_FILE" >&2

    # Create metadata file
    meeting_dir=$(dirname "$OUTPUT_FILE")
    base_name=$(basename "$OUTPUT_FILE" .wav)
    metadata_file="${meeting_dir}/${base_name}_metadata.json"

    # Generate metadata JSON
    cat > "$metadata_file" << EOF
{
  "title": "${TITLE}",
  "timestamp": "${TIMESTAMP}",
  "date": "${DATE}",
  "audio_file": "$(basename "$OUTPUT_FILE")",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "local_recording"
}
EOF

    if [ -n "$TITLE" ]; then
        echo "Title: $TITLE" >&2
    fi

    # Output only the filename to stdout (for script capture)
    echo "$OUTPUT_FILE"
else
    echo "" >&2
    echo "Error: Recording file was not created" >&2
    exit 1
fi
