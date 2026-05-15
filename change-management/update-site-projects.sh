#!/bin/bash
set -eo pipefail

export NODE_TLS_REJECT_UNAUTHORIZED=0
DEPLOYMENT=""
DEBUG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    --debug)      DEBUG=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done
BASE_PROJECT_FILE="${BASE_PROJECT_FILE:-app/main-project.yaml}"

# ── Check openfn CLI version ─────────────────────────────────────────────────
_required_version="1.31.0"
if ! command -v openfn &>/dev/null; then
  echo "Error: openfn CLI is not installed."
  echo "Install with: npm i -g @openfn/cli   or   pnpm i -g @openfn/cli"
  exit 1
fi
_actual_version=$(openfn version 2>&1 | awk '/▸.*cli/ { print $NF }')
if [ -z "$_actual_version" ]; then
  echo "Error: could not determine openfn CLI version."
  echo "Try reinstalling: npm i -g @openfn/cli   or   pnpm i -g @openfn/cli"
  exit 1
fi
if ! printf '%s\n%s\n' "$_required_version" "$_actual_version" | sort -V -C; then
  echo "Error: openfn CLI $_actual_version is installed but >= $_required_version is required."
  echo "Upgrade with: npm i -g @openfn/cli   or   pnpm i -g @openfn/cli"
  exit 1
fi
unset _required_version _actual_version

# Load env vars (API keys etc.) so ${!api_key_var} resolution works below
[ -f .env ] && set -a && source .env && set +a

log() { echo "[update] $*"; }

# ── Parse the base project ──────────────────────────────────────────────────
BASE_PROJECT_NAME=$(grep '^name:' "$BASE_PROJECT_FILE" | head -1 | awk '{print $2}')

COLLECTION_KEYS=$(awk '
  /^collections:/ { f=1; next }
  /^[^ ]/         { f=0 }
  f && /^  [a-zA-Z0-9_-]+:/ { gsub(/:$/, "", $1); print $1 }
' "$BASE_PROJECT_FILE")

CREDENTIAL_NAMES=$(awk '
  /^credentials:/ { f=1; next }
  /^[^ ]/         { f=0 }
  f && /^    name:/ { sub(/^    name: /, ""); print }
' "$BASE_PROJECT_FILE")

# Credential keys actually referenced in workflow jobs (non-null)
USED_CRED_KEYS=$(awk '
  /^workflows:/ { f=1 }
  f && /^        credential: / {
    val = $2
    if (val != "null") print val
  }
' "$BASE_PROJECT_FILE" | sort -u)
export USED_CRED_KEYS

log "Base project : ${BASE_PROJECT_NAME}"
log "Collections  : $(echo "$COLLECTION_KEYS" | tr '\n' ' ')"
log "Used cred keys: $(echo "$USED_CRED_KEYS" | tr '\n' ' ')"

# ── Collect all facility names (used to filter already-prefixed collection keys) ──
ALL_FACILITIES=()
for _cfg in */*-config.json; do
  _sp=$(grep '"specPath"' "$_cfg" | sed 's/.*"specPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  _base=$(basename "$_sp")
  ALL_FACILITIES+=("${_base%-project.yaml}")
done

# ── Per-project processing ───────────────────────────────────────────────────
_status_file=$(mktemp)

for project_config in ${DEPLOYMENT:-*}/*-config.json; do
  (
  spec_path=$(grep '"specPath"' "$project_config" \
    | sed 's/.*"specPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  project_file="$spec_path"
  dest_dir=$(dirname "$spec_path")                            # e.g. hub
  base=$(basename "$spec_path")                               # e.g. adhc1-project.yaml
  facility="${base%-project.yaml}"                            # e.g. adhc1

  project_name="${facility}-et-emr"
  facility_cap="$(echo "${facility:0:1}" | tr '[:lower:]' '[:upper:]')${facility:1}"

  api_key_var="$(echo "$dest_dir" | tr '[:lower:]' '[:upper:]')_API_KEY"
  endpoint=$(grep '"endpoint"' "$project_config" | sed 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

  if [ -z "${!api_key_var}" ]; then
    log "API key '\$${api_key_var}' is not set, skipping '${project_config}'."
    echo "skipped" >> "$_status_file"
    exit 0
  fi

  # ── Step 1: Resolve project ID ───────────────────────────────────────────
  project_id=$(curl -sk \
    -H "Authorization: Bearer ${!api_key_var}" \
    "${endpoint}/api/projects" \
    | awk -v target="$project_name" '
        BEGIN { RS="\"type\":\"projects\"" }
        index($0, "\"name\":\"" target "\"") {
          match($0, /"id":"[^"]*"/)
          print substr($0, RSTART+6, RLENGTH-7)
          exit
        }
      ')

  if [ -z "$project_id" ]; then
    log "Project '${project_name}' not found on '${endpoint}', skipping."
    echo "skipped" >> "$_status_file"
    exit 0
  fi

  log ""
  log "Processing '${project_name}' (id: ${project_id})..."

  # ── Step 2: Pull latest state from server ────────────────────────────────
  log "  Pulling latest..."
  if ! OPENFN_API_KEY="${!api_key_var}" openfn pull "$project_id" -c "$project_config" --no-confirm; then
    log "  Pull failed, skipping."
    echo "failed" >> "$_status_file"
    exit 1
  fi

  # Read owner, credentials and wf/job names from the freshly pulled file
  SITE_OWNER=$(awk '/^    owner:/ { print $2; exit }' "$project_file" 2>/dev/null || true)

  EXISTING_CRED_KEYS=""
  EXISTING_CREDS_YAML=""
  EXISTING_CRED_KEYS=$(awk '
    /^credentials:/ { f=1; next }
    /^[^ ]/         { f=0 }
    f && /^  [^ ]/  { key=$1; gsub(/:$/, "", key); print key }
  ' "$project_file")
  EXISTING_CREDS_YAML=$(awk '
    /^credentials:/ { f=1; next }
    /^[^ ]/         { f=0 }
    f               { print }
  ' "$project_file")
  export EXISTING_CRED_KEYS EXISTING_CREDS_YAML

  EXISTING_WF_NAMES=$(awk '
    /^workflows:/ { in_wf=1; next }
    in_wf && /^[^ ]/ { in_wf=0 }
    in_wf && /^  [^ ]/ { cur_key=$1; gsub(/:$/, "", cur_key) }
    in_wf && cur_key && /^    name: / {
      name=$0; sub(/^    name: /, "", name); print name "|" cur_key; cur_key=""
    }
  ' "$project_file")
  EXISTING_JOB_NAMES=$(awk '
    /^workflows:/ { in_wf=1; next }
    in_wf && /^[^ ]/ { in_wf=0 }
    in_wf && /^  [^ ]/ { cur_wf=$1; gsub(/:$/, "", cur_wf); in_jobs=0 }
    in_wf && /^    jobs:/ { in_jobs=1; next }
    in_wf && /^    [^ ]/  { in_jobs=0 }
    in_wf && in_jobs && /^      [^ ]/ { cur_job=$1; gsub(/:$/, "", cur_job) }
    in_wf && in_jobs && cur_job && /^        name: / {
      name=$0; sub(/^        name: /, "", name)
      print cur_wf "|" name "|" cur_job; cur_job=""
    }
  ' "$project_file")
  export EXISTING_WF_NAMES EXISTING_JOB_NAMES

  log "  Pulled. Owner: ${SITE_OWNER:-<not found>}"

  # ── Step 3: Backup pulled file ────────────────────────────────────────────
  backup_file=$(mktemp)
  cp "$project_file" "$backup_file"
  export EXISTING_PROJECT_BACKUP="$backup_file"

  # Build sed substitutions — skip collection keys already prefixed with any facility name
  sed_args=()
  while IFS= read -r coll_key; do
    [ -z "$coll_key" ] && continue
    skip_key=false
    for _fac in "${ALL_FACILITIES[@]}"; do
      [[ "$coll_key" == "${_fac}-"* ]] && { skip_key=true; break; }
    done
    $skip_key && continue
    sed_args+=(-e "s/${coll_key}/${facility}-${coll_key}/g")
  done <<< "$COLLECTION_KEYS"
  while IFS= read -r cred_name; do
    [ -z "$cred_name" ] && continue
    sed_args+=(-e "s/name: ${cred_name}/name: ${facility_cap} ${cred_name}/g")
  done <<< "$CREDENTIAL_NAMES"
  sed_args+=(
    -e "s/${BASE_PROJECT_NAME}/${project_name}/g"
  )
  [ -n "$SITE_OWNER" ] && sed_args+=(-e "s|owner: .*|owner: ${SITE_OWNER}|")

  # Pre-scan the sed output to collect base project workflow/job keys.
  _sed_out=$(sed "${sed_args[@]}" "$BASE_PROJECT_FILE")
  BASE_WF_KEYS=$(echo "$_sed_out" | awk '
    /^workflows:/ { in_wf=1; next }
    in_wf && /^[^ ]/ { in_wf=0 }
    in_wf && /^  [^ ]/ { k=$1; gsub(/:$/, "", k); print k }
  ')
  BASE_JOB_KEYS=$(echo "$_sed_out" | awk '
    /^workflows:/ { in_wf=1; next }
    in_wf && /^[^ ]/ { in_wf=0 }
    in_wf && /^    jobs:/ { in_jobs=1; next }
    in_wf && /^    [^ ]/ { in_jobs=0 }
    in_wf && in_jobs && /^      [^ ]/ { k=$1; gsub(/:$/, "", k); print k }
  ')
  export BASE_WF_KEYS BASE_JOB_KEYS

  # Pipe sed → awk to strip unused credentials, rewrite credential keys,
  # and remap workflow/job keys via Jaro-Winkler fuzzy matching
  echo "$_sed_out" \
  | awk '
      # ── Jaro-Winkler ──────────────────────────────────────────────────────────
      function jaro(s1, s2,    l1, l2, win, matches, t, i, j, lo, hi, k, _m1, _m2) {
        if (s1 == s2) return 1.0
        l1 = length(s1); l2 = length(s2)
        if (!l1 || !l2) return 0.0
        win = int((l1 > l2 ? l1 : l2) / 2) - 1
        if (win < 0) win = 0
        matches = 0
        for (i = 1; i <= l1; i++) {
          lo = i - win; if (lo < 1) lo = 1
          hi = i + win; if (hi > l2) hi = l2
          for (j = lo; j <= hi; j++) {
            if (_m2[j] || substr(s1,i,1) != substr(s2,j,1)) continue
            _m1[i] = _m2[j] = 1; matches++; break
          }
        }
        if (!matches) return 0.0
        t = 0; k = 1
        for (i = 1; i <= l1; i++) {
          if (!_m1[i]) continue
          while (!_m2[k]) k++
          if (substr(s1,i,1) != substr(s2,k,1)) t++
          k++
        }
        return (matches/l1 + matches/l2 + (matches - t/2)/matches) / 3
      }

      function jaro_winkler(s1, s2,    j, prefix, i) {
        j = jaro(s1, s2)
        prefix = 0
        for (i = 1; i <= 4 && i <= length(s1) && i <= length(s2); i++) {
          if (substr(s1,i,1) == substr(s2,i,1)) prefix++
          else break
        }
        return j + prefix * 0.1 * (1 - j)
      }

      function match_wf_by_name(app_name,    best_key, best_score, i, score) {
        # 1. Exact name match
        for (i = 1; i <= wf_count; i++) {
          if (!(wf_key[i] in used_wf_key) && !(wf_key[i] in emitted_wf_key) && app_name == wf_name[i]) {
            used_wf_key[wf_key[i]] = 1
            return wf_key[i]
          }
        }
        # 2. Jaro-Winkler fuzzy match (threshold 0.60 to handle renamed workflows)
        best_key = ""; best_score = 0
        for (i = 1; i <= wf_count; i++) {
          if ((wf_key[i] in used_wf_key) || (wf_key[i] in emitted_wf_key) || (wf_key[i] in base_wf_keys)) continue
          score = jaro_winkler(app_name, wf_name[i])
          if (score > best_score) { best_score = score; best_key = wf_key[i] }
        }
        if (best_score >= 0.60) { used_wf_key[best_key] = 1; return best_key }
        return ""
      }

      function match_job_by_name(app_name, cur_wf,    best_key, best_score, i, score, cnt, jkey) {
        cnt = job_counts[cur_wf]
        if (!cnt) return ""
        # 1. Exact name match
        for (i = 1; i <= cnt; i++) {
          jkey = job_key[cur_wf, i]
          if (!((cur_wf, jkey) in used_job_key) && !((cur_wf, jkey) in emitted_job_key) && app_name == job_name[cur_wf, i]) {
            used_job_key[cur_wf, jkey] = 1
            return jkey
          }
        }
        # 2. Jaro-Winkler fuzzy match (threshold 0.60 to handle renamed jobs)
        best_key = ""; best_score = 0
        for (i = 1; i <= cnt; i++) {
          jkey = job_key[cur_wf, i]
          if (((cur_wf, jkey) in used_job_key) || ((cur_wf, jkey) in emitted_job_key) || (jkey in base_job_keys)) continue
          score = jaro_winkler(app_name, job_name[cur_wf, i])
          if (score > best_score) { best_score = score; best_key = jkey }
        }
        if (best_score >= 0.60) { used_job_key[cur_wf, best_key] = 1; return best_key }
        return ""
      }

      # Safe string replace (avoids regex-escaping issues with special chars in keys)
      function str_replace(str, find, repl,    result, pos, flen) {
        result = ""; flen = length(find)
        while ((pos = index(str, find)) > 0) {
          result = result substr(str, 1, pos-1) repl
          str = substr(str, pos + flen)
        }
        return result str
      }

      # ── Orphan workflow passthrough ────────────────────────────────────────────
      function output_unmatched_workflows(    _file, _line, _in_wf, _cur_key, _in_cur, _arr) {
        _file = ENVIRON["EXISTING_PROJECT_BACKUP"]
        if (_file == "") return
        _in_wf = 0; _cur_key = ""; _in_cur = 0
        while ((getline _line < _file) > 0) {
          if (_line ~ /^workflows:/) { _in_wf = 1; continue }
          if (_in_wf && _line ~ /^[^ ]/) break
          if (!_in_wf) continue
          if (_line ~ /^  [^ ]/) {
            split(_line, _arr)
            _cur_key = _arr[1]; gsub(/:$/, "", _cur_key)
            _in_cur = !(_cur_key in used_wf_key) && !(_cur_key in emitted_wf_key)
          }
          if (_in_cur) print _line
        }
        close(_file)
      }

      # ── Credential helpers ─────────────────────────────────────────────────────
      function flush_cred(    slug, new_key) {
        if (buf_key == "") return
        slug = buf_name; gsub(/ /, "-", slug)
        new_key = buf_owner "-" slug
        cred_key_map[buf_key] = new_key
        if (!(new_key in state_cred_keys)) {
          print "  " new_key ":"
          print "    name: " buf_name
          print "    owner: " buf_owner
        }
        buf_key = ""; buf_name = ""; buf_owner = ""
      }

      BEGIN {
        nb = split(ENVIRON["BASE_WF_KEYS"], bwf_arr, "\n")
        for (i = 1; i <= nb; i++) if (bwf_arr[i] != "") base_wf_keys[bwf_arr[i]] = 1
        nj = split(ENVIRON["BASE_JOB_KEYS"], bjob_arr, "\n")
        for (i = 1; i <= nj; i++) if (bjob_arr[i] != "") base_job_keys[bjob_arr[i]] = 1

        n = split(ENVIRON["USED_CRED_KEYS"], arr, "\n")
        for (i = 1; i <= n; i++) if (arr[i] != "") keep[arr[i]] = 1
        m = split(ENVIRON["EXISTING_CRED_KEYS"], sarr, "\n")
        for (i = 1; i <= m; i++) if (sarr[i] != "") state_cred_keys[sarr[i]] = 1
        state_yaml = ENVIRON["EXISTING_CREDS_YAML"]

        nw = split(ENVIRON["EXISTING_WF_NAMES"], wf_tmp, "\n")
        for (i = 1; i <= nw; i++) {
          if (wf_tmp[i] == "") continue
          p = index(wf_tmp[i], "|")
          if (!p) continue
          wf_name[++wf_count] = substr(wf_tmp[i], 1, p-1)
          wf_key[wf_count]    = substr(wf_tmp[i], p+1)
        }

        nj = split(ENVIRON["EXISTING_JOB_NAMES"], job_tmp, "\n")
        for (i = 1; i <= nj; i++) {
          if (job_tmp[i] == "") continue
          p1 = index(job_tmp[i], "|")
          if (!p1) continue
          wfk  = substr(job_tmp[i], 1, p1-1)
          rest = substr(job_tmp[i], p1+1)
          p2   = index(rest, "|")
          if (!p2) continue
          job_name[wfk, ++job_counts[wfk]] = substr(rest, 1, p2-1)
          job_key[wfk, job_counts[wfk]]    = substr(rest, p2+1)
        }
      }

      /^credentials:/ { in_creds=1; in_wf=0; print; if (state_yaml != "") print state_yaml; next }
      /^workflows:/   { if (in_creds) flush_cred(); in_wf=1; in_creds=0; print; next }
      /^[^ ]/         { if (in_creds) flush_cred(); if (in_wf) output_unmatched_workflows(); in_creds=0; in_wf=0; cred_skip=0 }
      END             { if (in_wf) output_unmatched_workflows() }

      in_creds && /^  [^ ]/ {
        flush_cred()
        orig_key = $0; sub(/^  /, "", orig_key); sub(/:.*/, "", orig_key)
        cred_skip = !(orig_key in keep)
        if (!cred_skip) buf_key = orig_key
        next
      }
      in_creds && !cred_skip && /^    name: /  { buf_name  = $0; sub(/^    name: /,  "", buf_name);  next }
      in_creds && !cred_skip && /^    owner: / { buf_owner = $0; sub(/^    owner: /, "", buf_owner); next }
      in_creds { next }

      in_wf && /^  [^ ]/ {
        pending_wf_key = $0; sub(/^  /, "", pending_wf_key); sub(/:.*/, "", pending_wf_key)
        in_wf_jobs = 0; delete job_key_map
        next
      }

      in_wf && pending_wf_key && /^    name: / {
        app_wf_name = $0; sub(/^    name: /, "", app_wf_name)
        matched = match_wf_by_name(app_wf_name)
        cur_wf  = (matched != "") ? matched : pending_wf_key
        if (cur_wf != pending_wf_key)
          print "[update] workflow \"" app_wf_name "\" key: \"" pending_wf_key "\" -> \"" cur_wf "\"" > "/dev/stderr"
        emitted_wf_key[cur_wf] = 1
        print "  " cur_wf ":"
        print "    name: " app_wf_name
        pending_wf_key = ""
        next
      }

      in_wf && /^    jobs:/ { in_wf_jobs = 1; print; next }
      in_wf && /^    [^ ]/  { in_wf_jobs = 0 }

      in_wf && in_wf_jobs && /^      [^ ]/ {
        pending_job_key = $0; sub(/^      /, "", pending_job_key); sub(/:.*/, "", pending_job_key)
        next
      }

      in_wf && in_wf_jobs && pending_job_key && /^        name: / {
        app_job_name = $0; sub(/^        name: /, "", app_job_name)
        matched_job  = match_job_by_name(app_job_name, cur_wf)
        mapped_job   = (matched_job != "") ? matched_job : pending_job_key
        if (mapped_job != pending_job_key) {
          job_key_map[pending_job_key] = mapped_job
          print "[update]   job \"" app_job_name "\" key: \"" pending_job_key "\" -> \"" mapped_job "\"" > "/dev/stderr"
        }
        emitted_job_key[cur_wf, mapped_job] = 1
        print "      " mapped_job ":"
        print "        name: " app_job_name
        pending_job_key = ""
        next
      }

      in_wf && !in_wf_jobs && (index($0, "->") || /source_job|target_job/) {
        for (nk in job_key_map)
          if (index($0, nk)) $0 = str_replace($0, nk, job_key_map[nk])
      }

      /credential: / && $2 != "null" && ($2 in cred_key_map) {
        sub(/credential: [^ ]+/, "credential: " cred_key_map[$2])
      }
      { print }
    ' > "$project_file"

  log "  Written: ${project_file}"

  # ── Step 4: Deploy ────────────────────────────────────────────────────────
  log "  Deploying '${project_name}'..."
  if OPENFN_API_KEY="${!api_key_var}" openfn deploy -c "$project_config" --no-confirm; then
    log "  Deployed."
    echo "ok" >> "$_status_file"
    # ── Step 5: Pull again to sync server-assigned IDs ────────────────────
    log "  Syncing from server..."
    OPENFN_API_KEY="${!api_key_var}" openfn pull "$project_id" -c "$project_config" --no-confirm || true
  else
    log "  Deploy failed for '${project_name}'."
    echo "failed" >> "$_status_file"
    if [[ "$DEBUG" == "1" ]]; then
      debug_file="${project_file}.debug"
      cp "$project_file" "$debug_file"
      log "  Debug file saved: ${debug_file}"
    fi
    cp "$backup_file" "$project_file"
    log "  Restored backup."
  fi

  rm -f "$backup_file"
  ) || { log "  Unexpected error processing '$project_config', continuing."; echo "failed" >> "$_status_file"; }
done

_ok=$(grep -c "^ok$" "$_status_file" 2>/dev/null || true)
_failed=$(grep -c "^failed$" "$_status_file" 2>/dev/null || true)
_skipped=$(grep -c "^skipped$" "$_status_file" 2>/dev/null || true)
rm -f "$_status_file"

log ""
log "Done — deployed: ${_ok}, failed: ${_failed}, skipped: ${_skipped}."
