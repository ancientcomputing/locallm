#!/usr/bin/env bash
set -euo pipefail

# scrub-example-models.sh — remove the MLX models (and, optionally, the pin records) that the
# examples create, so the next run is a true first-run download.
#
# DRY RUN BY DEFAULT: it prints what it would remove and how big it is. Nothing is deleted
# until you pass --yes.
#
#   ./scripts/scrub-example-models.sh                       # dry run, every example
#   ./scripts/scrub-example-models.sh --example aiql        # only one example (repeatable)
#   ./scripts/scrub-example-models.sh --pins                # also remove pin records
#   ./scripts/scrub-example-models.sh --shared              # also remove the examples' models from
#                                                           #   the shared ~/.cache/huggingface/hub
#   ./scripts/scrub-example-models.sh --shared --pins --yes # really do it, everything
#   ./scripts/scrub-example-models.sh --check               # is this script's model list stale?
#
# Keep the shared models safe while you test:
#   ./scripts/scrub-example-models.sh --shared-backup --shared --pins --yes   # back up, then remove
#   ./scripts/scrub-example-models.sh --shared-restore --yes                  # put the models back
# --shared-backup copies the examples' models from the shared cache to a sibling folder,
# <parent of the hub>/hub-example-backup (e.g. ~/.cache/huggingface/hub-example-backup; override with
# SCRUB_BACKUP_DIR). On APFS it clones the files (copy-on-write), so it costs almost no extra disk
# space and is near-instant. It never overwrites an existing backup, and in a run that also removes
# (--shared) the removal happens only after the backup is verified. --shared-restore copies them
# back and skips any model that is already in the cache.
#
# Where things live (see docs/sdk-guide.md, "Where the weights go"):
#   - A SANDBOXED example app keeps its own cache inside its container:
#       ~/Library/Containers/<bundle-id>/Data/Library/Caches/huggingface/
#     By default that whole cache is removed; it only ever holds that example's downloads.
#   - A NON-SANDBOXED example (swift run, the CLIs) uses the SHARED Hugging Face cache,
#       ~/.cache/huggingface/hub/models--<org>--<name>
#     which the LocalLM Lab app and any other tool also use, so those folders are only removed
#     with --shared, and only the models the examples name. HF_HUB_CACHE / HF_HOME are honored.
#   - Pin records (mlx-pins.json, mlx-managed-pins.json) are separate from the weights and stay
#     unless you pass --pins. Removing them lets you exercise "first download captures a pin".
#     Shipped pins live in each example's source, not on disk.
#
# It never touches the LocalLM Lab app's own data (~/Library/Application Support/LocalLM Lab).

YES=0; SHARED=0; PINS=0; CHECK=0; BACKUP=0; RESTORE=0
SELECTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --shared) SHARED=1 ;;
    --pins) PINS=1 ;;
    --check) CHECK=1 ;;
    --shared-backup) BACKUP=1 ;;
    --shared-restore) RESTORE=1 ;;
    --example) shift; SELECTED="$SELECTED $1" ;;
    -h|--help) sed -n '3,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

ALL_EXAMPLES="aiql code-buddy mlx-control-room os-matrix repo-qa-local vistanova workspace-buddy-local"

# ---- what each example creates -------------------------------------------------------------
# Keep in step with the examples' sources; `--check` reports repos this list is missing.
example_models() {
  case "$1" in
    aiql)                  echo "mlx-community/Qwen3-14B-4bit" ;;
    code-buddy)            echo "mlx-community/Qwen3-8B-4bit mlx-community/Qwen2.5-3B-Instruct-4bit" ;;
    mlx-control-room)      echo "mlx-community/Qwen2.5-0.5B-Instruct-4bit mlx-community/gemma-3-270m-it-4bit mlx-community/gemma-3-270m-4bit mlx-community/Qwen3-4B-4bit mlx-community/Qwen3-0.6B-4bit mlx-community/Qwen3-0.6B-bf16 stbenjam/qwen3-0.6b-haiku-mlx-lora" ;;
    os-matrix)             echo "mlx-community/Qwen3-4B-4bit" ;;
    repo-qa-local)         echo "mlx-community/Qwen3-8B-4bit" ;;
    vistanova)             echo "mlx-community/Qwen3-4B-4bit" ;;
    workspace-buddy-local) echo "mlx-community/Qwen3-8B-4bit" ;;
    *) return 1 ;;
  esac
}
# Sandbox container bundle id, if the example ships as a sandboxed .app.
example_container() {
  case "$1" in
    aiql)                  echo "lab.locallm.sdk.reference.aiql" ;;
    mlx-control-room)      echo "lab.locallm.sdk.reference.mlxcontrolroom" ;;
    workspace-buddy-local) echo "lab.locallm.sdk.reference.workspacebuddylocal" ;;
    *) echo "" ;;
  esac
}
# Unsandboxed pin-store directory (MLXFilePinStore's default: Application Support/<process>/LocalLMLab).
example_pin_dir() {
  case "$1" in
    code-buddy)       echo "$HOME/Library/Application Support/CodeBuddy/LocalLMLab" ;;
    mlx-control-room) echo "$HOME/Library/Application Support/MLXControlRoom/LocalLMLab" ;;
    repo-qa-local)    echo "$HOME/Library/Application Support/RepoQALocal/LocalLMLab" ;;
    *) echo "" ;;
  esac
}

# ---- --check: are there model repos in the examples that this list doesn't know? ------------
if [ "$CHECK" -eq 1 ]; then
  cd "$(cd "$(dirname "$0")/.." && pwd)"
  known=""
  for e in $ALL_EXAMPLES; do known="$known $(example_models "$e")"; done
  found="$(grep -rhoE '(mlx-community|stbenjam)/[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]' examples/*/Sources 2>/dev/null | sort -u)"
  missing=0
  for repo in $found; do
    case " $known " in *" $repo "*) ;; *) echo "not in the scrub list: $repo"; missing=1 ;; esac
  done
  if [ "$missing" -eq 0 ]; then echo "OK: every model repo named in examples/*/Sources is in the scrub list."; fi
  exit "$missing"
fi

# ---- helpers -------------------------------------------------------------------------------
size_of() { local s; s="$(du -sh "$1" 2>/dev/null | cut -f1)" || true; echo "${s:-?}"; }
TOTAL_ITEMS=0
remove() {  # <path> <label>
  local path="$1" label="$2" size
  [ -e "$path" ] || return 0
  size="$(size_of "$path")"
  TOTAL_ITEMS=$((TOTAL_ITEMS + 1))
  if [ "$YES" -eq 1 ]; then
    rm -rf -- "$path"
    printf 'removed       %6s  %s  (%s)\n' "$size" "$path" "$label"
  else
    printf 'would remove  %6s  %s  (%s)\n' "$size" "$path" "$label"
  fi
}
# Refuse to ever act on the app's own data or an obviously wrong path.
guard() {
  case "$1" in
    *"/LocalLM Lab"|*"/LocalLM Lab/"*) echo "refusing to touch the LocalLM Lab app's data: $1" >&2; exit 3 ;;
    ""|"/"|"$HOME"|"$HOME/") echo "refusing a suspicious path: '$1'" >&2; exit 3 ;;
  esac
}

hf_hub_dir() {
  if [ -n "${HF_HUB_CACHE:-}" ]; then echo "$HF_HUB_CACHE"
  elif [ -n "${HF_HOME:-}" ]; then echo "$HF_HOME/hub"
  else echo "$HOME/.cache/huggingface/hub"; fi
}

backup_dir() {
  if [ -n "${SCRUB_BACKUP_DIR:-}" ]; then echo "$SCRUB_BACKUP_DIR"
  else echo "$(dirname "$(hf_hub_dir)")/hub-example-backup"; fi
}
SEEN=""
once() {  # true the first time a key is seen, so a model shared by several examples is handled once
  case "$SEEN" in *"|$1|"*) return 1 ;; esac
  SEEN="$SEEN|$1|"
}
# Copy a directory tree, cloning (copy-on-write) where the volume supports it. Preserves the
# symlinks a Hugging Face cache is built from. <src> <dst> — dst must not exist.
copy_tree() {
  cp -a -c "$1" "$2" 2>/dev/null || cp -a "$1" "$2"
}
tree_count() { find "$1" 2>/dev/null | wc -l | tr -d ' '; }

if [ "$RESTORE" -eq 1 ] && { [ "$BACKUP" -eq 1 ] || [ "$SHARED" -eq 1 ] || [ "$PINS" -eq 1 ]; }; then
  echo "--shared-restore can't be combined with --shared-backup, --shared or --pins." >&2; exit 2
fi

[ -z "$SELECTED" ] && SELECTED="$ALL_EXAMPLES"
for e in $SELECTED; do
  example_models "$e" >/dev/null 2>&1 || { echo "unknown example: $e (known: $ALL_EXAMPLES)" >&2; exit 2; }
done

if [ "$RESTORE" -eq 1 ]; then MODE="restoring"; else MODE="scrubbing"; fi
if [ "$YES" -eq 1 ]; then echo "== $MODE =="; else echo "== dry run (pass --yes to act) =="; fi

BK="$(backup_dir)"; HUB="$(hf_hub_dir)"
guard "$BK"
COPIED=0
for e in $SELECTED; do
  echo "-- $e"
  if [ "$RESTORE" -eq 1 ]; then
    for repo in $(example_models "$e"); do
      name="models--$(echo "$repo" | sed 's|/|--|')"
      once "restore:$name" || continue
      if [ ! -e "$BK/$name" ]; then echo "no backup   $repo"; continue; fi
      if [ -e "$HUB/$name" ]; then echo "already in cache  $repo  (left as is)"; continue; fi
      if [ "$YES" -eq 1 ]; then
        mkdir -p "$HUB"; copy_tree "$BK/$name" "$HUB/$name"
        if [ "$(tree_count "$BK/$name")" != "$(tree_count "$HUB/$name")" ]; then echo "restore of $repo looks incomplete" >&2; exit 4; fi
        printf 'restored      %6s  %s\n' "$(size_of "$HUB/$name")" "$repo"
      else
        printf 'would restore %6s  %s\n' "$(size_of "$BK/$name")" "$repo"
      fi
      COPIED=$((COPIED + 1))
    done
    continue
  fi
  if [ "$BACKUP" -eq 1 ]; then
    for repo in $(example_models "$e"); do
      name="models--$(echo "$repo" | sed 's|/|--|')"
      once "backup:$name" || continue
      [ -e "$HUB/$name" ] || continue
      if [ -e "$BK/$name" ]; then echo "already backed up  $repo"; continue; fi
      if [ "$YES" -eq 1 ]; then
        mkdir -p "$BK"; copy_tree "$HUB/$name" "$BK/$name"
        if [ "$(tree_count "$HUB/$name")" != "$(tree_count "$BK/$name")" ]; then echo "backup of $repo looks incomplete; nothing was removed" >&2; exit 4; fi
        printf 'backed up     %6s  %s\n' "$(size_of "$HUB/$name")" "$repo"
      else
        printf 'would back up %6s  %s\n' "$(size_of "$HUB/$name")" "$repo"
      fi
      COPIED=$((COPIED + 1))
    done
  fi
  container="$(example_container "$e")"
  if [ -n "$container" ]; then
    p="$HOME/Library/Containers/$container/Data/Library/Caches/huggingface"
    guard "$p"; remove "$p" "sandbox cache"
    if [ "$PINS" -eq 1 ]; then
      p="$HOME/Library/Containers/$container/Data/Library/Application Support/$container/LocalLMLab"
      guard "$p"; remove "$p" "pin records"
    fi
  fi
  if [ "$PINS" -eq 1 ]; then
    p="$(example_pin_dir "$e")"
    if [ -n "$p" ]; then guard "$p"; remove "$p" "pin records"; fi
  fi
  if [ "$SHARED" -eq 1 ]; then
    hub="$(hf_hub_dir)"
    for repo in $(example_models "$e"); do
      p="$hub/models--$(echo "$repo" | sed 's|/|--|')"
      once "remove:$p" || continue
      guard "$p"; remove "$p" "shared cache"
    done
  fi
done

if [ "$RESTORE" -eq 1 ]; then
  echo; echo "$COPIED model(s) $( [ "$YES" -eq 1 ] && echo restored || echo "would be restored (re-run with --yes)" ) from $BK"
  exit 0
fi
if [ "$BACKUP" -eq 1 ]; then
  echo; echo "$COPIED model(s) $( [ "$YES" -eq 1 ] && echo "backed up" || echo "would be backed up" ) to $BK"
fi
if [ "$YES" -eq 0 ]; then
  echo
  echo "$TOTAL_ITEMS item(s) would be removed. Re-run with --yes to delete."
  if [ "$SHARED" -eq 0 ]; then echo "Not included: models in the shared cache (--shared) — used by the LocalLM Lab app too."; fi
  if [ "$PINS" -eq 0 ]; then echo "Not included: pin records (--pins)."; fi
else
  echo
  echo "Done: $TOTAL_ITEMS item(s) removed."
fi
