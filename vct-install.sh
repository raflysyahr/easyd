#!/usr/bin/env bash
# VCT remote installer. Publish this file in your GitHub repository, then run:
# curl -fsSL 'https://raw.githubusercontent.com/USER/REPO/BRANCH/vct-install.sh' | bash
set -Eeuo pipefail

APP_NAME='VCT - Video Compression Transfer'
VERSION='1.1.0'
INSTALL_DIR="${VCT_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_PATH="$INSTALL_DIR/vct"
TMP_APP=''

cleanup() {
  if [[ -n "$TMP_APP" && -f "$TMP_APP" ]]; then
    rm -f -- "$TMP_APP"
  fi
  return 0
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

confirm_tty() {
  local prompt="${1:-Lanjutkan?}" answer=''
  if [[ "${VCT_YES:-0}" == '1' ]]; then return 0; fi
  if [[ ! -r /dev/tty ]]; then
    warn 'Terminal interaktif tidak tersedia; pilihan default adalah tidak.'
    return 1
  fi
  IFS= read -r -p "$prompt [Y/n]: " answer </dev/tty || return 1
  answer="${answer,,}"
  [[ -z "$answer" || "$answer" == 'y' || "$answer" == 'yes' ]]
}

run_with_privileges() {
  local manager="$1"; shift
  if [[ "$manager" == 'pkg' ]]; then
    pkg "$@"
  elif [[ "$(id -u)" -eq 0 ]]; then
    "$manager" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$manager" "$@"
  else
    warn "Perlu root atau sudo untuk menjalankan $manager."
    return 1
  fi
}

install_missing_dependencies() {
  local missing=() cmd manager=''
  local required=(zstd sha256sum curl yt-dlp ffmpeg ffprobe)
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} == 0)); then
    ok 'Semua dependency tersedia: zstd, sha256sum, curl, yt-dlp, ffmpeg, ffprobe.'
    return 0
  fi

  info "Dependency yang belum ditemukan: ${missing[*]}"
  if [[ "${VCT_INSTALL_DEPS:-}" == '0' ]]; then
    warn 'VCT_INSTALL_DEPS=0; melewati instalasi dependency.'
    return 0
  fi
  if ! confirm_tty "Pasang dependency yang hilang sekarang?"; then
    warn 'Instalasi dependency dilewati. VCT akan menawarkan pemasangan saat dijalankan.'
    return 0
  fi

  local packages=(zstd coreutils curl yt-dlp ffmpeg)
  if [[ -n "${TERMUX_VERSION:-}" ]] || { command -v pkg >/dev/null 2>&1 && [[ -d /data/data/com.termux ]]; }; then
    manager='pkg'
    pkg update -y
    pkg install -y "${packages[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    manager='apt-get'
    run_with_privileges "$manager" update
    run_with_privileges "$manager" install -y --no-install-recommends "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    manager='dnf'
    run_with_privileges "$manager" install -y "${packages[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    manager='pacman'
    run_with_privileges "$manager" -Sy --needed --noconfirm "${packages[@]}"
  elif command -v apk >/dev/null 2>&1; then
    manager='apk'
    run_with_privileges "$manager" add "${packages[@]}"
  else
    warn "Package manager tidak dikenali; pasang secara manual: ${packages[*]}"
    return 0
  fi

  local still_missing=()
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
  done
  if ((${#still_missing[@]} == 0)); then
    ok 'Dependency berhasil dipasang.'
  else
    warn "Sebagian dependency belum tersedia: ${still_missing[*]}"
    warn 'VCT tetap terpasang, tetapi beberapa fitur mungkin belum berfungsi.'
  fi
}

info "Memasang $APP_NAME v$VERSION"
mkdir -p -- "$INSTALL_DIR"
if [[ -e "$INSTALL_PATH" ]]; then
  if ! confirm_tty "'$INSTALL_PATH' sudah ada. Ganti dengan versi ini?"; then
    say 'Instalasi dibatalkan.'
    exit 1
  fi
fi
TMP_APP="$(mktemp "${INSTALL_PATH}.tmp.XXXXXX")"
cat > "$TMP_APP" <<'__VCT_APP_PAYLOAD__'
#!/usr/bin/env bash
# VCT - Video Compression Transfer
# Bash-based helper for downloading files, losslessly compressing them with Zstandard,
# transferring the .zst + .sha256 files, then restoring and verifying on the receiver.
#
# Note: Zstandard compresses the file bytes losslessly, but already-compressed video
# formats (MP4/WebM/MKV) often shrink very little or may grow. The script keeps a
# compressed artifact only when it is strictly smaller than the original.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="VCT - Video Compression Transfer"
VERSION="1.1.0"
DOWNLOAD_DIR="downloads"
CURRENT_TMP=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN=""
fi

cleanup() {
  if [[ -n "${CURRENT_TMP:-}" && -e "$CURRENT_TMP" ]]; then
    rm -f -- "$CURRENT_TMP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

say()   { printf '%s\n' "$*"; }
ok()    { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
error() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
info()  { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }

confirm() {
  local prompt="${1:-Continue?}" answer=""
  read -r -p "$prompt [Y/n]: " answer || return 1
  answer="${answer,,}"
  [[ -z "$answer" || "$answer" == "y" || "$answer" == "yes" ]]
}

confirm_no_default() {
  local prompt="${1:-Continue?}" answer=""
  read -r -p "$prompt [y/N]: " answer || return 1
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

pause() {
  printf '\n'
  read -r -p 'Tekan Enter untuk kembali ke menu...' _ || true
}

expand_path() {
  local p="$1"
  case "$p" in
    '~') p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
  esac
  printf '%s' "$p"
}

command_to_package() {
  case "$1" in
    zstd) printf '%s' 'zstd' ;;
    sha256sum) printf '%s' 'coreutils' ;;
    curl) printf '%s' 'curl' ;;
    yt-dlp) printf '%s' 'yt-dlp' ;;
    ffmpeg|ffprobe) printf '%s' 'ffmpeg' ;;
    *) return 1 ;;
  esac
}

list_missing_commands() {
  local cmd
  for cmd in zstd sha256sum curl yt-dlp ffmpeg ffprobe; do
    command -v "$cmd" >/dev/null 2>&1 || printf '%s\n' "$cmd"
  done
}

install_packages() {
  local packages=("$@")
  ((${#packages[@]})) || return 0

  if [[ -n "${TERMUX_VERSION:-}" ]] || { command -v pkg >/dev/null 2>&1 && [[ -d /data/data/com.termux ]]; }; then
    info "Menggunakan package manager Termux: ${packages[*]}"
    pkg update -y && pkg install -y "${packages[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      apt-get update && apt-get install -y --no-install-recommends "${packages[@]}"
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update && sudo apt-get install -y --no-install-recommends "${packages[@]}"
    else
      error "apt-get tersedia, tetapi butuh root atau sudo untuk memasang dependency."
      return 1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      dnf install -y "${packages[@]}"
    elif command -v sudo >/dev/null 2>&1; then
      sudo dnf install -y "${packages[@]}"
    else
      error "dnf tersedia, tetapi butuh root atau sudo untuk memasang dependency."
      return 1
    fi
  elif command -v pacman >/dev/null 2>&1; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      pacman -Sy --needed --noconfirm "${packages[@]}"
    elif command -v sudo >/dev/null 2>&1; then
      sudo pacman -Sy --needed --noconfirm "${packages[@]}"
    else
      error "pacman tersedia, tetapi butuh root atau sudo untuk memasang dependency."
      return 1
    fi
  else
    error "Package manager tidak dikenali. Install dependency secara manual: ${packages[*]}"
    return 1
  fi
}

check_dependencies() {
  local missing_cmds=() packages=() cmd pkg_name answer
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] && missing_cmds+=("$cmd")
  done < <(list_missing_commands)

  if ((${#missing_cmds[@]} == 0)); then
    ok "Semua dependency tersedia: zstd, sha256sum, curl, yt-dlp, ffmpeg, ffprobe."
    return 0
  fi

  warn "Dependency belum ditemukan: ${missing_cmds[*]}"
  for cmd in "${missing_cmds[@]}"; do
    pkg_name="$(command_to_package "$cmd")" || continue
    local already=0 p
    for p in "${packages[@]}"; do [[ "$p" == "$pkg_name" ]] && already=1; done
    (( already )) || packages+=("$pkg_name")
  done

  if ((${#packages[@]} == 0)); then
    error "Tidak dapat memetakan dependency yang hilang ke paket sistem."
    return 1
  fi

  if confirm "Pasang dependency yang hilang sekarang (${packages[*]})?"; then
    if install_packages "${packages[@]}"; then
      local still_missing=()
      while IFS= read -r cmd; do
        [[ -n "$cmd" ]] && still_missing+=("$cmd")
      done < <(list_missing_commands)
      if ((${#still_missing[@]} == 0)); then
        ok "Instalasi dependency selesai."
        return 0
      fi
      error "Masih ada dependency yang belum tersedia: ${still_missing[*]}"
      return 1
    else
      error "Instalasi dependency gagal. Periksa koneksi atau izin sistem."
      return 1
    fi
  else
    warn "Instalasi dilewati. Fitur yang memerlukan dependency tersebut belum bisa digunakan."
    return 1
  fi
}

require_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
  error "Perintah '$cmd' belum terpasang."
  check_dependencies || true
  command -v "$cmd" >/dev/null 2>&1
}

human_size() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s bytes' "$bytes"
  else
    printf '%s bytes' "$bytes"
  fi
}

file_size_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

get_download_dir() {
  local answer=""
  read -r -p "Folder download [${DOWNLOAD_DIR}]: " answer || return 1
  [[ -n "$answer" ]] && DOWNLOAD_DIR="$(expand_path "$answer")"
  mkdir -p -- "$DOWNLOAD_DIR"
}

safe_prepare_destination() {
  local dest="$1"
  local parent
  parent="$(dirname -- "$dest")"
  mkdir -p -- "$parent" || return 1
  if [[ -e "$dest" ]]; then
    if ! confirm_no_default "File '$dest' sudah ada. Timpa?"; then
      warn "Dibatalkan; file yang ada tidak diubah."
      return 1
    fi
  fi
}

suggest_filename_from_url() {
  local url="$1" cleaned name
  cleaned="${url%%\#*}"
  cleaned="${cleaned%%\?*}"
  name="${cleaned##*/}"
  [[ -n "$name" && "$name" != "/" ]] || name="download.bin"
  printf '%s' "$name"
}

download_direct() {
  require_command curl || return 1
  local url suggested output temp
  read -r -p 'URL langsung (http/https): ' url || return 1
  [[ "$url" =~ ^https?:// ]] || { error "URL harus dimulai dengan http:// atau https://"; return 1; }
  get_download_dir || return 1
  suggested="$(suggest_filename_from_url "$url")"
  read -r -p "Nama/path output [${DOWNLOAD_DIR}/${suggested}]: " output || return 1
  output="$(expand_path "${output:-$DOWNLOAD_DIR/$suggested}")"
  safe_prepare_destination "$output" || return 1

  temp="$(mktemp "${output}.part.XXXXXX")" || { error "Tidak bisa membuat file sementara."; return 1; }
  CURRENT_TMP="$temp"
  info "Mengunduh ke file sementara, lalu memindahkannya setelah berhasil..."
  if curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 --output "$temp" "$url"; then
    mv -f -- "$temp" "$output"
    CURRENT_TMP=""
    ok "Download selesai: $output ($(human_size "$(file_size_bytes "$output")"))"
    info "Berikutnya, pilih menu kompresi lossless jika ingin menguji apakah ukuran bisa diperkecil."
  else
    error "Download gagal. File sementara akan dibersihkan."
    return 1
  fi
}

download_with_ytdlp() {
  require_command yt-dlp || return 1
  local url
  read -r -p 'URL video yang didukung yt-dlp: ' url || return 1
  [[ "$url" =~ ^https?:// ]] || { error "URL harus dimulai dengan http:// atau https://"; return 1; }
  get_download_dir || return 1
  info "Mengunduh satu video (bukan seluruh playlist) ke: $DOWNLOAD_DIR"
  warn "Gunakan hanya konten yang kamu berhak unduh. Script ini tidak melewati DRM atau pembatasan akses."
  yt-dlp --no-playlist --newline --paths "$DOWNLOAD_DIR" -o '%(title).180B [%(id)s].%(ext)s' "$url"
}

download_dash_mpd() {
  require_command ffmpeg || return 1
  require_command ffprobe || return 1

  local url output probe_output line item key value idx typ codec width height bitrate
  local best_video_idx="" best_video_area=-1 best_video_rate=-1
  local best_audio_idx="" best_audio_rate=-1
  local selected_video_idx="" choice pos area rate
  local tmp
  local -a video_indices=() audio_indices=() parts=() ffargs=()
  local -A stream_type=() stream_codec=() stream_width=() stream_height=() stream_rate=()

  read -r -p 'URL manifest DASH/MPD (URL boleh tidak berakhiran .mpd): ' url || return 1
  [[ "$url" =~ ^https?:// ]] || { error "URL harus dimulai dengan http:// atau https://"; return 1; }
  get_download_dir || return 1
  read -r -p "Nama/path output [${DOWNLOAD_DIR}/video.mkv]: " output || return 1
  output="$(expand_path "${output:-$DOWNLOAD_DIR/video.mkv}")"
  if [[ "$output" != *.mkv ]]; then
    warn 'Output DASH/MPD akan disimpan dalam kontainer Matroska agar stream video/audio bisa disalin tanpa encoding ulang.'
    output="${output}.mkv"
    info "Nama output disesuaikan menjadi: $output"
  fi
  safe_prepare_destination "$output" || return 1

  info 'Membaca manifest dan daftar representasi dengan ffprobe...'
  if ! probe_output="$(ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,bit_rate -of compact=p=0:nk=0 "$url" 2>&1)"; then
    error 'Tidak bisa membaca manifest MPD. URL mungkin kedaluwarsa, dibatasi server, atau bukan manifest yang didukung FFmpeg.'
    say 'Pesan ffprobe:'
    say "$probe_output"
    return 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    idx=''; typ=''; codec=''; width='0'; height='0'; bitrate='0'
    IFS='|' read -r -a parts <<< "$line"
    for item in "${parts[@]}"; do
      key="${item%%=*}"
      value="${item#*=}"
      case "$key" in
        index) idx="$value" ;;
        codec_type) typ="$value" ;;
        codec_name) codec="$value" ;;
        width) width="$value" ;;
        height) height="$value" ;;
        bit_rate) bitrate="$value" ;;
      esac
    done
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    [[ "$width" =~ ^[0-9]+$ ]] || width='0'
    [[ "$height" =~ ^[0-9]+$ ]] || height='0'
    [[ "$bitrate" =~ ^[0-9]+$ ]] || bitrate='0'
    stream_type["$idx"]="$typ"
    stream_codec["$idx"]="$codec"
    stream_width["$idx"]="$width"
    stream_height["$idx"]="$height"
    stream_rate["$idx"]="$bitrate"
    case "$typ" in
      video) video_indices+=("$idx") ;;
      audio) audio_indices+=("$idx") ;;
    esac
  done <<< "$probe_output"

  if ((${#video_indices[@]} == 0)); then
    error 'Manifest tidak menyediakan stream video yang bisa dibaca FFmpeg.'
    return 1
  fi

  for idx in "${video_indices[@]}"; do
    area=$(( ${stream_width[$idx]} * ${stream_height[$idx]} ))
    rate="${stream_rate[$idx]}"
    if (( area > best_video_area || (area == best_video_area && rate > best_video_rate) )); then
      best_video_idx="$idx"
      best_video_area="$area"
      best_video_rate="$rate"
    fi
  done
  for idx in "${audio_indices[@]}"; do
    rate="${stream_rate[$idx]}"
    if [[ -z "$best_audio_idx" ]] || (( rate > best_audio_rate )); then
      best_audio_idx="$idx"
      best_audio_rate="$rate"
    fi
  done

  say ''
  say 'Representasi video yang tersedia:'
  for pos in "${!video_indices[@]}"; do
    idx="${video_indices[$pos]}"
    local label="${stream_width[$idx]}x${stream_height[$idx]}"
    [[ "${stream_width[$idx]}" == '0' || "${stream_height[$idx]}" == '0' ]] && label='resolusi tidak diketahui'
    printf '  %d) %s | %s | %s kbps | stream index %s' \
      "$((pos + 1))" "$label" "${stream_codec[$idx]:-unknown}" "$(( ${stream_rate[$idx]} / 1000 ))" "$idx"
    [[ "$idx" == "$best_video_idx" ]] && printf '  [resolusi tertinggi]'
    printf '\n'
  done
  say '  0) Gunakan representasi dengan resolusi tertinggi (default)'
  read -r -p 'Pilih kualitas video [0]: ' choice || return 1
  choice="${choice:-0}"
  if [[ "$choice" == '0' ]]; then
    selected_video_idx="$best_video_idx"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#video_indices[@]} )); then
    selected_video_idx="${video_indices[$((choice - 1))]}"
  else
    error 'Pilihan kualitas tidak valid.'
    return 1
  fi

  info "Video dipilih: stream $selected_video_idx (${stream_width[$selected_video_idx]}x${stream_height[$selected_video_idx]}, ${stream_codec[$selected_video_idx]:-unknown})."
  if [[ -n "$best_audio_idx" ]]; then
    info "Audio otomatis dipilih dengan bitrate tertinggi yang terdeteksi: stream $best_audio_idx (${stream_codec[$best_audio_idx]:-unknown}, $(( ${stream_rate[$best_audio_idx]} / 1000 )) kbps)."
  else
    warn 'Manifest tidak menyediakan stream audio yang terdeteksi; output akan berisi video saja.'
  fi
  warn 'FFmpeg akan menyalin stream tanpa encoding ulang (remux). Ini bukan bypass DRM atau pembatasan akses; URL harus tetap valid dan memang dapat kamu akses.'

  tmp="$(mktemp "${output}.part.XXXXXX")" || { error 'Tidak bisa membuat file sementara.'; return 1; }
  CURRENT_TMP="$tmp"
  ffargs=(-hide_banner -nostdin -y -i "$url" -map "0:${selected_video_idx}")
  if [[ -n "$best_audio_idx" ]]; then
    ffargs+=(-map "0:${best_audio_idx}")
  fi
  ffargs+=(-c copy -f matroska "$tmp")

  info 'Mengunduh representasi dan menggabungkan audio/video...'
  if ! ffmpeg "${ffargs[@]}"; then
    error 'FFmpeg gagal mengunduh atau menggabungkan MPD. URL mungkin kedaluwarsa atau aksesnya ditolak.'
    return 1
  fi
  if [[ ! -s "$tmp" ]] || ! ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$tmp" >/dev/null 2>&1; then
    error 'Output tidak valid atau kosong; file tidak akan disimpan.'
    return 1
  fi
  mv -f -- "$tmp" "$output"
  CURRENT_TMP=''
  ok "Download MPD selesai: $output ($(human_size "$(file_size_bytes "$output")"))"
  info 'Kamu sekarang bisa memilih menu kompresi lossless untuk menguji apakah file MKV dapat diperkecil dengan Zstandard.'
}

download_menu() {
  local choice
  printf '\n%sDownload%s\n' "$C_BOLD" "$C_RESET"
  say '1) URL file langsung (curl)' 
  say '2) Situs yang didukung yt-dlp'
  say '3) Manifest DASH/MPD (FFmpeg; URL bisa tidak berakhiran .mpd)'
  say '0) Kembali'
  read -r -p 'Pilih: ' choice || return 0
  case "$choice" in
    1) download_direct ;;
    2) download_with_ytdlp ;;
    3) download_dash_mpd ;;
    0) return 0 ;;
    *) warn "Pilihan tidak dikenal." ;;
  esac
}

compress_lossless() {
  require_command zstd || return 1
  require_command sha256sum || return 1

  local src out sidecar level level_opt original_bytes compressed_bytes original_hash
  local tmp hash_tmp
  read -r -p 'Path file video yang akan dikompres: ' src || return 1
  src="$(expand_path "$src")"
  [[ -f "$src" ]] || { error "File tidak ditemukan: $src"; return 1; }
  out="${src}.zst"
  sidecar="${out}.sha256"

  say 'Level kompresi Zstd: 1 = cepat, 3 = seimbang, 9 = lebih kuat (lebih lambat).'
  read -r -p 'Pilih level [3]: ' level || return 1
  level="${level:-3}"
  [[ "$level" =~ ^(1|3|9)$ ]] || { error "Pilih hanya 1, 3, atau 9."; return 1; }
  level_opt="-$level"

  if [[ -e "$out" || -e "$sidecar" ]]; then
    if ! confirm_no_default "Output '$out' atau checksum-nya sudah ada. Ganti setelah kompresi berhasil?"; then
      warn "Dibatalkan."
      return 1
    fi
  fi

  original_bytes="$(file_size_bytes "$src")"
  original_hash="$(sha256sum -- "$src")"
  original_hash="${original_hash%% *}"
  info "Ukuran asli: $(human_size "$original_bytes")"
  info "Mengompres lossless dengan Zstd level $level. Untuk MP4/WebM/MKV, hasil bisa tidak lebih kecil."

  tmp="$(mktemp "${out}.tmp.XXXXXX")" || { error "Tidak bisa membuat file sementara."; return 1; }
  CURRENT_TMP="$tmp"
  if ! zstd -T0 "$level_opt" -k -f -o "$tmp" -- "$src"; then
    error "Kompresi gagal. File asli tidak diubah."
    return 1
  fi
  compressed_bytes="$(file_size_bytes "$tmp")"

  if (( compressed_bytes >= original_bytes )); then
    rm -f -- "$tmp"
    CURRENT_TMP=""
    warn "Hasil kompresi tidak lebih kecil ($(human_size "$compressed_bytes") vs $(human_size "$original_bytes"))."
    warn "File hasil dibuang; file asli tetap utuh. Gunakan file asli untuk transfer."
    return 0
  fi

  hash_tmp="$(mktemp "${sidecar}.tmp.XXXXXX")" || { error "Tidak bisa membuat file checksum sementara."; return 1; }
  printf '%s\n' "$original_hash" > "$hash_tmp"
  mv -f -- "$tmp" "$out"
  CURRENT_TMP=""
  mv -f -- "$hash_tmp" "$sidecar"

  local saved_bytes saved_percent
  saved_bytes=$((original_bytes - compressed_bytes))
  saved_percent=$((saved_bytes * 100 / original_bytes))
  ok "Kompresi lossless berhasil dan hasilnya lebih kecil."
  say "Asli       : $src ($(human_size "$original_bytes"))"
  say "Terkompresi: $out ($(human_size "$compressed_bytes"))"
  say "Hemat      : $(human_size "$saved_bytes") (${saved_percent}%)"
  say "Checksum   : $sidecar"
  warn "Transfer kedua file: '$out' DAN '$sidecar'. Sidecar diperlukan untuk verifikasi hasil pemulihan."
}

decompress_and_verify() {
  require_command zstd || return 1
  require_command sha256sum || return 1

  local src dest sidecar expected actual tmp answer
  read -r -p 'Path file .zst yang akan dipulihkan: ' src || return 1
  src="$(expand_path "$src")"
  [[ -f "$src" ]] || { error "File tidak ditemukan: $src"; return 1; }
  if [[ "$src" == *.zst ]]; then
    dest="${src%.zst}"
  else
    dest="${src}.restored"
    warn "Nama file tidak berakhiran .zst; output default menjadi '$dest'."
  fi
  read -r -p "Nama file hasil [$dest]: " answer || return 1
  [[ -n "$answer" ]] && dest="$(expand_path "$answer")"
  safe_prepare_destination "$dest" || return 1

  sidecar="${src}.sha256"
  expected=""
  if [[ -f "$sidecar" ]]; then
    IFS= read -r expected < "$sidecar" || true
    if [[ ! "$expected" =~ ^[a-fA-F0-9]{64}$ ]]; then
      error "File checksum ada tetapi formatnya tidak valid: $sidecar"
      return 1
    fi
  else
    warn "Sidecar checksum tidak ditemukan: $sidecar"
    if ! confirm_no_default "Lanjut tanpa verifikasi SHA-256 file asli?"; then
      return 1
    fi
  fi

  info "Memeriksa integritas stream Zstandard..."
  zstd -t -- "$src" || { error "File .zst rusak atau tidak valid."; return 1; }

  tmp="$(mktemp "${dest}.part.XXXXXX")" || { error "Tidak bisa membuat file sementara."; return 1; }
  CURRENT_TMP="$tmp"
  if ! zstd -d -T0 -f -o "$tmp" -- "$src"; then
    error "Dekompresi gagal. Output sementara akan dibersihkan."
    return 1
  fi

  if [[ -n "$expected" ]]; then
    actual="$(sha256sum -- "$tmp")"
    actual="${actual%% *}"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
      error "SHA-256 tidak cocok. File hasil tidak akan disimpan."
      return 1
    fi
    ok "SHA-256 cocok dengan file sumber saat kompresi."
  else
    warn "Tidak ada checksum sumber untuk dibandingkan; pemeriksaan Zstd saja berhasil."
  fi

  mv -f -- "$tmp" "$dest"
  CURRENT_TMP=""
  ok "Pemulihan selesai: $dest ($(human_size "$(file_size_bytes "$dest")"))"
}

verify_checksum() {
  require_command sha256sum || return 1
  local src sidecar expected actual
  read -r -p 'Path file yang ingin diverifikasi: ' src || return 1
  src="$(expand_path "$src")"
  [[ -f "$src" ]] || { error "File tidak ditemukan: $src"; return 1; }
  read -r -p 'Path file .sha256: ' sidecar || return 1
  sidecar="$(expand_path "$sidecar")"
  [[ -f "$sidecar" ]] || { error "File checksum tidak ditemukan: $sidecar"; return 1; }
  IFS= read -r expected < "$sidecar" || true
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { error "Isi checksum tidak valid."; return 1; }
  actual="$(sha256sum -- "$src")"
  actual="${actual%% *}"
  if [[ "${actual,,}" == "${expected,,}" ]]; then
    ok "SHA-256 cocok: file terverifikasi."
  else
    error "SHA-256 tidak cocok: file berbeda atau rusak."
    say "Expected: $expected"
    say "Actual  : $actual"
    return 1
  fi
}

compare_sizes() {
  local a b size_a size_b diff pct
  read -r -p 'Path file pertama (mis. video.mp4): ' a || return 1
  a="$(expand_path "$a")"
  read -r -p 'Path file kedua (mis. video.mp4.zst): ' b || return 1
  b="$(expand_path "$b")"
  [[ -f "$a" ]] || { error "File tidak ditemukan: $a"; return 1; }
  [[ -f "$b" ]] || { error "File tidak ditemukan: $b"; return 1; }
  size_a="$(file_size_bytes "$a")"
  size_b="$(file_size_bytes "$b")"
  say "File 1: $a — $(human_size "$size_a")"
  say "File 2: $b — $(human_size "$size_b")"
  if (( size_a > 0 )); then
    if (( size_b < size_a )); then
      diff=$((size_a - size_b))
      pct=$((diff * 100 / size_a))
      ok "File 2 lebih kecil sebesar $(human_size "$diff") (${pct}%)."
    elif (( size_b > size_a )); then
      diff=$((size_b - size_a))
      pct=$((diff * 100 / size_a))
      warn "File 2 lebih besar sebesar $(human_size "$diff") (${pct}% dari ukuran file 1)."
    else
      say 'Ukuran keduanya sama.'
    fi
  else
    warn 'File pertama kosong; persentase tidak dapat dihitung.'
  fi
}

install_current_script() {
  local source_path install_dir install_path
  source_path="${BASH_SOURCE[0]}"
  if [[ ! -f "$source_path" ]]; then
    error "Tidak dapat menemukan file sumber script ini. Jika menjalankan via curl | bash, gunakan vct-install.sh."
    return 1
  fi
  source_path="$(cd -- "$(dirname -- "$source_path")" && pwd)/$(basename -- "$source_path")"
  install_dir="${VCT_INSTALL_DIR:-$HOME/.local/bin}"
  install_path="$install_dir/vct"

  if [[ -e "$install_path" ]] && ! confirm_no_default "'$install_path' sudah ada. Timpa?"; then
    warn "Instalasi dibatalkan."
    return 1
  fi
  mkdir -p -- "$install_dir" || { error "Tidak bisa membuat folder instalasi: $install_dir"; return 1; }
  local tmp
  tmp="$(mktemp "${install_path}.tmp.XXXXXX")" || { error "Tidak bisa membuat file sementara."; return 1; }
  if ! cp -- "$source_path" "$tmp"; then
    rm -f -- "$tmp"
    error "Gagal menyalin script."
    return 1
  fi
  chmod 755 "$tmp"
  bash -n "$tmp" || { rm -f -- "$tmp"; error "File script gagal pemeriksaan sintaks Bash."; return 1; }
  mv -f -- "$tmp" "$install_path"
  ok "VCT terpasang: $install_path"
  case ":${PATH}:" in
    *":$install_dir:"*) ok "Folder instalasi sudah ada di PATH. Jalankan: vct" ;;
    *) warn "Folder $install_dir belum ada di PATH. Tambahkan dengan:"; say "  export PATH=\"\$HOME/.local/bin:\$PATH\""; say "Lalu jalankan: vct" ;;
  esac
}

uninstall_vct() {
  local install_path="${VCT_INSTALL_DIR:-$HOME/.local/bin}/vct"
  if [[ ! -f "$install_path" ]]; then
    warn "VCT tidak ditemukan di $install_path"
    return 1
  fi
  if confirm_no_default "Hapus VCT dari '$install_path'?"; then
    rm -f -- "$install_path"
    ok "VCT berhasil dihapus. File video dan hasil download tidak diubah."
  else
    warn "Penghapusan dibatalkan."
    return 1
  fi
}

show_help() {
  cat <<'HELP'
VCT - Video Compression Transfer

Penggunaan:
  ./vct.sh                 Buka menu interaktif
  ./vct.sh --install       Pasang sebagai perintah 'vct' di ~/.local/bin
  ./vct.sh --uninstall     Hapus perintah VCT dari ~/.local/bin
  ./vct.sh --version       Tampilkan versi
  ./vct.sh --help          Tampilkan bantuan

Untuk instalasi dari URL, gunakan vct-install.sh yang dipublikasikan ke repositori Anda:
  curl -fsSL '<URL_RAW_vct-install.sh>' | bash
HELP
}

show_menu() {
  printf '\n%s%s%s  %s\n' "$C_BOLD" "$APP_NAME" "$C_RESET" "$VERSION"
  say 'Kompresi lossless + checksum untuk transfer file.'
  say '------------------------------------------------------------'
  say '1) Download video/file'
  say '2) Kompres file secara lossless (Zstandard)'
  say '3) Pulihkan .zst dan verifikasi SHA-256'
  say '4) Verifikasi file menggunakan .sha256'
  say '5) Bandingkan ukuran dua file'
  say '6) Cek / install dependency'
  say '7) Install VCT sebagai perintah (vct)'
  say '0) Keluar'
}

main() {
  local choice
  say "${APP_NAME} v${VERSION}"
  say 'Tools Bash untuk download, MPD/DASH, kompresi lossless, dan pemulihan file.'
  say 'Catatan: video yang sudah terkompresi biasanya tidak banyak mengecil dengan Zstd.'
  check_dependencies || true

  while true; do
    printf '\n'
    show_menu
    read -r -p 'Pilih menu: ' choice || break
    case "$choice" in
      1) download_menu || true; pause ;;
      2) compress_lossless || true; pause ;;
      3) decompress_and_verify || true; pause ;;
      4) verify_checksum || true; pause ;;
      5) compare_sizes || true; pause ;;
      6) check_dependencies || true; pause ;;
      7) install_current_script || true; pause ;;
      0) say 'Selesai.'; break ;;
      *) warn 'Pilihan tidak valid.'; pause ;;
    esac
  done
}

case "${1:-}" in
  --install)
    install_current_script
    ;;
  --uninstall)
    uninstall_vct
    ;;
  --version|-V)
    printf '%s %s\n' "$APP_NAME" "$VERSION"
    ;;
  --help|-h)
    show_help
    ;;
  "")
    main
    ;;
  *)
    error "Argumen tidak dikenal: $1"
    show_help >&2
    exit 2
    ;;
esac

__VCT_APP_PAYLOAD__
chmod 755 "$TMP_APP"
if ! bash -n "$TMP_APP"; then
  warn 'Pemeriksaan sintaks gagal; instalasi dibatalkan.'
  exit 1
fi
mv -f -- "$TMP_APP" "$INSTALL_PATH"
TMP_APP=''
ok "VCT terpasang di: $INSTALL_PATH"

case ":${PATH}:" in
  *":$INSTALL_DIR:"*) say 'Jalankan perintah: vct' ;;
  *)
    warn "$INSTALL_DIR belum ada di PATH. Tambahkan baris berikut ke ~/.bashrc atau ~/.zshrc:"
    say 'export PATH="$HOME/.local/bin:$PATH"'
    say 'Setelah itu jalankan: vct'
    ;;
esac

install_missing_dependencies
say ''
say 'Selesai. Jalankan VCT dengan:'
say '  ~/.local/bin/vct'
say 'atau, jika ~/.local/bin ada di PATH:'
say '  vct'
