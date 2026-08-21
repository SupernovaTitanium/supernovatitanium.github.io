#!/usr/bin/env bash
set -uo pipefail

OUT="${1:?output directory required}"
WORK="${2:?work directory required}"
SUPPORT="${3:?support directory required}"
mkdir -p "$OUT" "$WORK"
LOG="$OUT/setup.log"
exec > >(tee -a "$LOG") 2>&1

STATUS=0
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

write_status() {
  python3 - "$OUT/setup-status.json" "$STATUS" <<'PY'
import json, os, sys, time
path, code = sys.argv[1], int(sys.argv[2])
json.dump(
    {
        "success": code == 0,
        "exit_code": code,
        "github_run_id": os.environ.get("GITHUB_RUN_ID", "unknown"),
        "github_sha": os.environ.get("GITHUB_SHA", "unknown"),
        "written_at_unix": int(time.time()),
    },
    open(path, "w", encoding="utf-8"),
    ensure_ascii=False,
    indent=2,
)
PY
}

main() {
  set -e
  echo "=== Codex × human-writing A/B experiment ==="
  date -u +'%Y-%m-%dT%H:%M:%SZ' | tee "$OUT/started-at.txt"
  printf '%s\n' "${GITHUB_RUN_ID:-unknown}" > "$OUT/run-id.txt"
  cp "$SUPPORT/prompts.json" "$OUT/prompts.json"

  {
    uname -a
    lscpu
    free -h
    python3 --version
    node --version
    npm --version
  } > "$OUT/environment.txt" 2>&1

  sudo apt-get update -qq
  sudo apt-get install -y -qq jq unzip ca-certificates curl git >/dev/null

  echo "=== Install official Codex CLI ==="
  CODEX_PREFIX="$WORK/codex-npm"
  mkdir -p "$CODEX_PREFIX"
  CODEX_REQUESTED="0.146.0-alpha.13"
  if npm install -g --prefix "$CODEX_PREFIX" "@openai/codex@$CODEX_REQUESTED"; then
    printf '%s\n' "$CODEX_REQUESTED" > "$OUT/codex-requested-version.txt"
  else
    echo "Pinned alpha unavailable from npm; falling back to the current published package."
    npm install -g --prefix "$CODEX_PREFIX" @openai/codex
    printf '%s\n' "latest-fallback" > "$OUT/codex-requested-version.txt"
  fi
  CODEX="$CODEX_PREFIX/bin/codex"
  "$CODEX" --version | tee "$OUT/codex-version.txt"
  sha256sum "$CODEX" > "$OUT/codex-launcher-sha256.txt" || true

  echo "=== Fetch pinned human-writing skill ==="
  SKILL_SHA="4fda173f3fef7fb808f3eba991eeb2528ea4b189"
  SKILL_REPO="$WORK/human-writing-repo"
  git init -q "$SKILL_REPO"
  git -C "$SKILL_REPO" remote add origin https://github.com/KKKKhazix/human-writing.git
  git -C "$SKILL_REPO" fetch -q --depth=1 origin "$SKILL_SHA"
  git -C "$SKILL_REPO" checkout -q --detach FETCH_HEAD
  ACTUAL_SKILL_SHA="$(git -C "$SKILL_REPO" rev-parse HEAD)"
  test "$ACTUAL_SKILL_SHA" = "$SKILL_SHA"
  printf '%s\n' "$ACTUAL_SKILL_SHA" > "$OUT/human-writing-commit.txt"
  cp "$SKILL_REPO/human-writing/VERSION" "$OUT/human-writing-version.txt"
  find "$SKILL_REPO/human-writing" -type f -print0 | sort -z | xargs -0 sha256sum > "$OUT/human-writing-files-sha256.txt"

  echo "=== Download official llama.cpp release ==="
  LLAMA_RELEASE_JSON="$WORK/llama-release.json"
  curl -fsSL --retry 5 https://api.github.com/repos/ggml-org/llama.cpp/releases/latest > "$LLAMA_RELEASE_JSON"
  cp "$LLAMA_RELEASE_JSON" "$OUT/llama-release.json"
  LLAMA_ASSET_URL="$(jq -r '.assets[] | select(.name | test("bin-ubuntu-x64\\.zip$")) | .browser_download_url' "$LLAMA_RELEASE_JSON" | head -n1)"
  LLAMA_ASSET_NAME="$(jq -r '.assets[] | select(.name | test("bin-ubuntu-x64\\.zip$")) | .name' "$LLAMA_RELEASE_JSON" | head -n1)"
  LLAMA_ASSET_DIGEST="$(jq -r '.assets[] | select(.name | test("bin-ubuntu-x64\\.zip$")) | (.digest // "")' "$LLAMA_RELEASE_JSON" | head -n1)"
  test -n "$LLAMA_ASSET_URL"
  printf '%s\n' "$LLAMA_ASSET_NAME" > "$OUT/llama-asset-name.txt"
  printf '%s\n' "$LLAMA_ASSET_DIGEST" > "$OUT/llama-asset-expected-digest.txt"
  LLAMA_ZIP="$WORK/$LLAMA_ASSET_NAME"
  curl -fL --retry 5 --retry-delay 5 -o "$LLAMA_ZIP" "$LLAMA_ASSET_URL"
  sha256sum "$LLAMA_ZIP" | tee "$OUT/llama-asset-sha256.txt"
  if [[ "$LLAMA_ASSET_DIGEST" == sha256:* ]]; then
    echo "${LLAMA_ASSET_DIGEST#sha256:}  $LLAMA_ZIP" | sha256sum -c -
  fi
  LLAMA_DIR="$WORK/llama-bin"
  mkdir -p "$LLAMA_DIR"
  unzip -q "$LLAMA_ZIP" -d "$LLAMA_DIR"
  LLAMA_SERVER="$(find "$LLAMA_DIR" -type f -name llama-server -perm -111 | head -n1)"
  test -x "$LLAMA_SERVER"
  export LD_LIBRARY_PATH="$(dirname "$LLAMA_SERVER"):${LD_LIBRARY_PATH:-}"
  "$LLAMA_SERVER" --version 2>&1 | tee "$OUT/llama-server-version.txt"
  "$LLAMA_SERVER" --help > "$WORK/llama-server-help.txt" 2>&1 || true

  echo "=== Download official Qwen/Qwen3-4B-GGUF Q4_K_M ==="
  MODEL_REPO="Qwen/Qwen3-4B-GGUF"
  MODEL_FILE="Qwen3-4B-Q4_K_M.gguf"
  MODEL="$WORK/$MODEL_FILE"
  MODEL_API="$OUT/model-api.json"
  curl -fsSL --retry 5 "https://huggingface.co/api/models/$MODEL_REPO?blobs=true" > "$MODEL_API" || true
  EXPECTED_MODEL_SHA=""
  EXPECTED_MODEL_SIZE=""
  if [[ -s "$MODEL_API" ]]; then
    EXPECTED_MODEL_SHA="$(jq -r --arg f "$MODEL_FILE" '.siblings[]? | select(.rfilename == $f) | (.lfs.sha256 // .lfs.oid // "")' "$MODEL_API" | head -n1)"
    EXPECTED_MODEL_SIZE="$(jq -r --arg f "$MODEL_FILE" '.siblings[]? | select(.rfilename == $f) | (.size // .lfs.size // "")' "$MODEL_API" | head -n1)"
  fi
  printf '%s\n' "$MODEL_REPO" > "$OUT/model-repo.txt"
  printf '%s\n' "$MODEL_FILE" > "$OUT/model-file.txt"
  printf '%s\n' "$EXPECTED_MODEL_SHA" > "$OUT/model-expected-sha256.txt"
  printf '%s\n' "$EXPECTED_MODEL_SIZE" > "$OUT/model-expected-size.txt"
  curl -fL --retry 8 --retry-delay 5 --continue-at - \
    -o "$MODEL" \
    "https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_FILE?download=true"
  stat --printf='%s\n' "$MODEL" | tee "$OUT/model-actual-size.txt"
  sha256sum "$MODEL" | tee "$OUT/model-actual-sha256.txt"
  if [[ "$EXPECTED_MODEL_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "$EXPECTED_MODEL_SHA  $MODEL" | sha256sum -c -
  fi
  if [[ "$EXPECTED_MODEL_SIZE" =~ ^[0-9]+$ ]]; then
    test "$(stat --printf='%s' "$MODEL")" = "$EXPECTED_MODEL_SIZE"
  fi

  echo "=== Configure isolated A/B homes ==="
  for condition in A B; do
    HOME_DIR="$WORK/home-$condition"
    CWD_DIR="$WORK/work-$condition"
    mkdir -p "$HOME_DIR/.codex" "$HOME_DIR/.agents/skills" "$CWD_DIR"
    git -C "$CWD_DIR" init -q
    cat > "$HOME_DIR/.codex/config.toml" <<'TOML'
model = "qwen3-4b"
model_provider = "llamacpp"
model_context_window = 32768

[model_providers.llamacpp]
name = "local llama.cpp"
base_url = "http://127.0.0.1:8080/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 1
stream_max_retries = 1
stream_idle_timeout_ms = 300000
TOML
  done
  cp -a "$SKILL_REPO/human-writing" "$WORK/home-B/.agents/skills/human-writing"
  find "$WORK/home-A/.agents/skills" -mindepth 1 -print -quit | grep -q . && {
    echo "Baseline home unexpectedly contains a skill" >&2
    return 1
  }
  test -f "$WORK/home-B/.agents/skills/human-writing/SKILL.md"

  echo "=== Start local llama.cpp Responses API ==="
  HELP="$WORK/llama-server-help.txt"
  SERVER_ARGS=(--model "$MODEL" --alias qwen3-4b --host 127.0.0.1 --port 8080 --ctx-size 32768)
  grep -q -- '--parallel' "$HELP" && SERVER_ARGS+=(--parallel 1)
  grep -q -- '--jinja' "$HELP" && SERVER_ARGS+=(--jinja)
  grep -q -- '--no-webui' "$HELP" && SERVER_ARGS+=(--no-webui)
  grep -q -- '--cache-type-k' "$HELP" && SERVER_ARGS+=(--cache-type-k q8_0 --cache-type-v q8_0)
  grep -q -- '--seed' "$HELP" && SERVER_ARGS+=(--seed 424242)
  grep -q -- '--temp' "$HELP" && SERVER_ARGS+=(--temp 0)
  grep -q -- '--top-k' "$HELP" && SERVER_ARGS+=(--top-k 1)
  grep -q -- '--n-predict' "$HELP" && SERVER_ARGS+=(--n-predict 1024)
  grep -q -- '--chat-template-kwargs' "$HELP" && SERVER_ARGS+=(--chat-template-kwargs '{"enable_thinking":false}')
  printf '%q ' "$LLAMA_SERVER" "${SERVER_ARGS[@]}" > "$OUT/llama-server-command.txt"
  printf '\n' >> "$OUT/llama-server-command.txt"
  "$LLAMA_SERVER" "${SERVER_ARGS[@]}" > "$OUT/llama-server.log" 2>&1 &
  SERVER_PID=$!
  printf '%s\n' "$SERVER_PID" > "$OUT/llama-server-pid.txt"

  READY=0
  for _ in $(seq 1 900); do
    if curl -fsS http://127.0.0.1:8080/health > "$OUT/llama-health.json" 2>/dev/null; then
      READY=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "llama-server exited during model load" >&2
      tail -n 200 "$OUT/llama-server.log" >&2 || true
      return 1
    fi
    sleep 1
  done
  test "$READY" = 1
  curl -fsS http://127.0.0.1:8080/v1/models > "$OUT/llama-models.json"
  curl -fsS http://127.0.0.1:8080/props > "$OUT/llama-props.json" || true
  curl -fsS -N -X POST http://127.0.0.1:8080/v1/responses \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3-4b","input":"只回覆 OK。 /no_think","stream":true,"max_output_tokens":24}' \
    > "$OUT/llama-responses-smoke.sse"
  grep -q 'response.completed' "$OUT/llama-responses-smoke.sse"

  echo "=== Run 20 fresh Codex sessions ==="
  python3 "$SUPPORT/run_experiment.py" \
    --work "$WORK" \
    --out "$OUT" \
    --prompts "$SUPPORT/prompts.json" \
    --codex "$CODEX" \
    --timeout 240

  echo "=== Analyze outputs with the skill's own checker ==="
  python3 "$SUPPORT/analyze.py" \
    --out "$OUT" \
    --prompts "$SUPPORT/prompts.json" \
    --checker "$SKILL_REPO/human-writing/scripts/check_prose.py"

  python3 - "$OUT/results.json" <<'PY'
import json, sys
records = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(records) == 20, len(records)
missing = [(r["id"], r["condition"], r["returncode"]) for r in records if not r["output"].strip()]
if missing:
    raise SystemExit(f"empty outputs: {missing}")
PY
  echo "success" > "$OUT/experiment-result.txt"
}

main || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "Experiment failed with status $STATUS" | tee "$OUT/experiment-result.txt"
  tail -n 250 "$LOG" > "$OUT/fatal-tail.txt" || true
fi
write_status
exit 0
