# Colors
# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }


# Early check for OPENAI_API_KEY
check_api_key() {
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        warn "OPENAI_API_KEY not set. Transcription and summaries will be skipped."
        warn "Media downloads will still work."
        echo ""
    fi
}

show_help() {
    cat << EOF
grab v${VERSION}
Download and archive content from URLs

USAGE:
    grab <url>
    grab --config          Reconfigure save directory

SUPPORTED:
    - X/Twitter tweets (with video, images, or text-only)
    - X/Twitter articles
    - Reddit posts (text, images, video, galleries)
    - YouTube videos

OUTPUT:
    All downloads saved to: $GRAB_DIR/<type>/<folder>/
    Config: $CONFIG_FILE

REQUIREMENTS:
    brew install yt-dlp ffmpeg
    OPENAI_API_KEY env var (for transcription/summaries)

EOF
}

check_deps() {
    local missing=()
    command -v yt-dlp >/dev/null || missing+=("yt-dlp")
    command -v ffmpeg >/dev/null || missing+=("ffmpeg")
    command -v curl >/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies: ${missing[*]}"
        echo "   Install: brew install ${missing[*]}"
        exit 1
    fi
}

# --- Helpers ---

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | head -c 60
}

date_str() {
    date +%Y-%m-%d
}

transcribe_audio() {
    local audio_file="$1"
    local output_file="$2"

    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        warn "OPENAI_API_KEY not set. Skipping transcription."
        return 1
    fi

    info "Transcribing audio..."

    # Check file size — OpenAI limit is 25MB
    local file_size
    file_size=$(stat -f%z "$audio_file" 2>/dev/null || stat -c%s "$audio_file" 2>/dev/null || echo 0)

    if [[ "$file_size" -gt 25000000 ]]; then
        info "File > 25MB, extracting audio and splitting..."
        local tmp_dir
        tmp_dir=$(mktemp -d)
        local audio_only="$tmp_dir/audio.m4a"

        # Extract audio only (much smaller)
        ffmpeg -i "$audio_file" -vn -acodec aac -b:a 64k -y "$audio_only" 2>/dev/null

        local audio_size
        audio_size=$(stat -f%z "$audio_only" 2>/dev/null || stat -c%s "$audio_only" 2>/dev/null || echo 0)

        if [[ "$audio_size" -gt 25000000 ]]; then
            # Split into chunks
            local duration
            duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$audio_only" 2>/dev/null | cut -d. -f1)
            local chunk_duration=600  # 10 min chunks
            local chunks=()
            local offset=0
            local i=0

            while [[ "$offset" -lt "$duration" ]]; do
                local chunk_file="$tmp_dir/chunk_$(printf '%03d' $i).m4a"
                ffmpeg -i "$audio_only" -ss "$offset" -t "$chunk_duration" -acodec aac -b:a 64k -y "$chunk_file" 2>/dev/null
                chunks+=("$chunk_file")
                offset=$((offset + chunk_duration))
                i=$((i + 1))
            done

            # Transcribe each chunk
            local full_transcript=""
            for chunk in "${chunks[@]}"; do
                local chunk_result
                chunk_result=$(curl -sS https://api.openai.com/v1/audio/transcriptions \
                    -H "Authorization: Bearer $OPENAI_API_KEY" \
                    -F "file=@$chunk" \
                    -F "model=whisper-1" \
                    -F "response_format=text" 2>/dev/null) || true
                full_transcript="$full_transcript $chunk_result"
            done

            echo "$full_transcript" > "$output_file"
        else
            # Small enough after audio extraction
            local result
            result=$(curl -sS https://api.openai.com/v1/audio/transcriptions \
                -H "Authorization: Bearer $OPENAI_API_KEY" \
                -F "file=@$audio_only" \
                -F "model=whisper-1" \
                -F "response_format=text" 2>/dev/null) || true
            echo "$result" > "$output_file"
        fi

        rm -rf "$tmp_dir"
    else
        # Small enough, transcribe directly
        local result
        result=$(curl -sS https://api.openai.com/v1/audio/transcriptions \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -F "file=@$audio_file" \
            -F "model=whisper-1" \
            -F "response_format=text" 2>/dev/null) || true
        echo "$result" > "$output_file"
    fi

    if [[ -s "$output_file" ]]; then
        local words
        words=$(wc -w < "$output_file" | tr -d ' ')
        log "Transcript saved ($words words)"
        return 0
    else
        warn "Transcription produced no output"
        rm -f "$output_file"
        return 1
    fi
}

summarize_text() {
    local input_file="$1"
    local output_file="$2"
    local context="${3:-video}"

    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        warn "OPENAI_API_KEY not set. Skipping summary."
        return 1
    fi

    if [[ ! -s "$input_file" ]]; then
        warn "No content to summarize"
        return 1
    fi

    info "Generating summary..."

    local content
    content=$(head -c 100000 "$input_file")

    local payload
    payload=$(GRAB_CONTEXT="$context" python3 -c "
import json, sys, os
content = sys.stdin.read()
ctx = os.environ.get('GRAB_CONTEXT', 'video')
data = {
    'model': 'gpt-4o-mini',
    'messages': [
        {'role': 'system', 'content': f'You are an expert summarizer. Given a transcript of a {ctx}, provide a thorough summary covering: 1. Main topics discussed 2. Key insights and takeaways 3. Notable quotes or moments. Format with clear sections and bullet points. Be detailed but digestible.'},
        {'role': 'user', 'content': content}
    ],
    'temperature': 0.2
}
print(json.dumps(data))
" <<< "$content")

    local response
    response=$(curl -sS https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || {
            warn "Summary API request failed"
            return 1
        }

    local summary
    summary=$(python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['choices'][0]['message']['content'])
except:
    sys.exit(1)
" <<< "$response") || {
        warn "Failed to parse summary response"
        return 1
    }

    echo "$summary" > "$output_file"
    log "Summary saved"
    return 0
}

generate_title() {
    local transcript_file="$1"
    local context="${2:-video}"

    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        echo ""
        return
    fi

    if [[ ! -s "$transcript_file" ]]; then
        echo ""
        return
    fi

    local content
    content=$(head -c 10000 "$transcript_file")

    local payload
    payload=$(GRAB_CONTEXT="$context" python3 -c "
import json, sys, os
content = sys.stdin.read()
ctx = os.environ.get('GRAB_CONTEXT', 'video')
data = {
    'model': 'gpt-4o-mini',
    'messages': [
        {'role': 'system', 'content': f'Given a transcript of a {ctx}, generate a short descriptive title (5-10 words) that captures the main topic or message. Just output the title, nothing else. No quotes.'},
        {'role': 'user', 'content': content}
    ],
    'max_tokens': 30,
    'temperature': 0.3
}
print(json.dumps(data))
" <<< "$content")

    local response
    response=$(curl -sS https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || {
        echo ""
        return
    }

    python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['choices'][0]['message']['content'].strip('\"').strip())
except:
    print('')
" <<< "$response"
}

describe_image() {
    local image_file="$1"

    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        echo "image"
        return
    fi

    local base64_img
    base64_img=$(base64 -i "$image_file" 2>/dev/null | tr -d '\n')

    local ext
    ext="${image_file##*.}"
    local mime="image/jpeg"
    [[ "$ext" == "png" ]] && mime="image/png"
    [[ "$ext" == "webp" ]] && mime="image/webp"
    [[ "$ext" == "gif" ]] && mime="image/gif"

    local payload
    payload=$(python3 -c "
import json
data = {
    'model': 'gpt-4o-mini',
    'messages': [
        {'role': 'user', 'content': [
            {'type': 'text', 'text': 'Describe this image in 5-8 words for use as a folder name. Be specific and descriptive. Just the description, nothing else.'},
            {'type': 'image_url', 'image_url': {'url': 'data:$mime;base64,$(echo "$base64_img" | head -c 50000)'}}
        ]}
    ],
    'max_tokens': 30
}
print(json.dumps(data))
")

    local response
    response=$(curl -sS https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || {
        echo "image"
        return
    }

    python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['choices'][0]['message']['content'].strip('\"').strip())
except:
    print('image')
" <<< "$response"
}

