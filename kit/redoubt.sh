#!/bin/bash
# Redoubt kit v2.0: one command for your own private cloud, zero subscriptions.
#
# This installs Docker, then the whole stack: photos (immich), files
# (nextcloud), search (searxng), an https edge signed by your own local
# CA, and a netbird mesh so the phone reaches everything from any
# network. Nothing is exposed to the internet. The edge binds to the LAN
# only, and nothing dials out. No telemetry, no accounts, no third
# parties.
#
# Idempotent: re-running it (updates do) reuses everything and picks
# free ports on its own.
#
# Install it the easy way:
#   curl -fsSL https://install.tryredoubt.com/redoubt.sh | bash
# Or read it first. It is meant to be read.
set -u
umask 077
# debconf must never wait for an answer nobody can see: the on-demand
# installs run with their output swallowed, and a template prompt on a
# live tty blocks the whole pass forever (kbd did exactly that)
export DEBIAN_FRONTEND=noninteractive

# ---- single-runner lock: one install per machine ----
# A sentinel subshell holds an flock on the lock file for as long as it
# lives: the kernel guarantees exactly one holder, and the lock dies the
# instant the sentinel dies (even kill -9). The subshell opens its own
# fd and execs into the sleep, so the fd lives only inside the sentinel
# and no child of the install can inherit it and keep the lock alive
# after the run is gone. A fresh run stops a stuck previous one (its
# cmdline has to match the kit, so a recycled pid can never kill an
# innocent process): it kills the sentinel only (pkill -P -f, so the
# owner's real work is never touched), then the owner, then races for
# the flock and the kernel hands it to exactly one. The file lives in
# /run (tmpfs) and is never removed: removing a flock file lets a third
# process lock a new inode and run concurrently.
LOCK=/run/redoubt.lock
( exec 9>>"$LOCK"; flock -n 9 2>/dev/null || exit 1; exec sleep infinity ) &
CENT_PID=$!
sleep 1
if ! kill -0 "$CENT_PID" 2>/dev/null; then
  _TRY=0
  while [ "$_TRY" -lt 20 ]; do
    OLD_PID="$(head -1 "$LOCK" 2>/dev/null)"
    if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] \
       && kill -0 "$OLD_PID" 2>/dev/null; then
      OLD_CMD="$(tr '\0' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null)"
      case "$OLD_CMD" in
        *redoubt*)
          echo "Another install is running (pid $OLD_PID). Stopping it first..."
          pkill -P "$OLD_PID" -f "sleep infinity" 2>/dev/null || true
          kill "$OLD_PID" 2>/dev/null || true
          _T=0
          while [ "$_T" -lt 5 ] && kill -0 "$OLD_PID" 2>/dev/null; do
            sleep 1; _T=$((_T + 1))
          done
          kill -9 "$OLD_PID" 2>/dev/null || true
          ;;
      esac
    fi
    ( exec 9>>"$LOCK"; flock -n 9 2>/dev/null || exit 1; exec sleep infinity ) &
    CENT_PID=$!
    sleep 1
    if kill -0 "$CENT_PID" 2>/dev/null; then
      # line 1 is the main shell (a fresh run reads it to take over);
      # line 2 is the sentinel (the safety watchdog kills it to free
      # the lock after a rollback)
      printf '%s\n%s\n' "$$" "$CENT_PID" > "$LOCK"
      break
    fi
    _TRY=$((_TRY + 1))
  done
  if ! kill -0 "$CENT_PID" 2>/dev/null; then
    echo "Could not take over the running install. Try again in a moment."
    exit 1
  fi
else
  printf '%s\n%s\n' "$$" "$CENT_PID" > "$LOCK"
fi
trap 'kill "$CENT_PID" 2>/dev/null; [ -n "${ANIM_PID:-}" ] && kill "$ANIM_PID" 2>/dev/null; rm -f "/tmp/redoubt-compose-out.$$"' EXIT
trap 'kill "$CENT_PID" 2>/dev/null; [ -n "${ANIM_PID:-}" ] && kill "$ANIM_PID" 2>/dev/null; rm -f "/tmp/redoubt-compose-out.$$"; exit 130' INT TERM HUP

LOG=/var/log/redoubt-kit.log

cursor_hide() { printf '\033[?25l' >&3 2>/dev/null || true; }  # no blinking block while the pass runs
cursor_show() { printf '\033[?25h' >&3 2>/dev/null || true; }

log() {  # visible status line: clears the bar first, then tty + log.
  # The bar dies here on purpose: its 30fps redraw would repaint over
  # the line this milestone just wrote. draw_bar relaunches it below.
  [ -n "${ANIM_PID:-}" ] && kill -9 "$ANIM_PID" 2>/dev/null || true
  ANIM_PID=""
  printf '\r\033[K' >&3
  printf '%s\n' "$1" >&3
  printf '%s\n' "$1" >> "$LOG"
}
dbg() {  # technical detail: log only, never on the terminal
  printf '%s\n' "$1" >> "$LOG"
}

nb_cloud_linked() {  # the saved config, not the live status: a
  # disconnected agent prints no Management URL, but the machine still
  # belongs to the network the config names. A NeedsLogin config carries
  # the default management url with an empty peer Name and no session:
  # that is not a link, the join must still run.
  local _CFG
  for _CFG in /var/lib/netbird/default.json /etc/netbird/config.json /var/lib/netbird/config.json; do
    [ -f "$_CFG" ] || continue
    grep -q 'netbird\.io' "$_CFG" 2>/dev/null || continue
    # an unjoined agent keeps the default url but its Name is empty
    grep -q '"Name": ""' "$_CFG" 2>/dev/null && return 1
    return 0
  done
  return 1
}
nb_cloud_live() {  # the live link state, patient by design: the
  # daemon restarts during a pass and the status flickers through
  # Connecting states, so a single probe misjudges a linked machine
  # and sends it back to the key prompt. Give the daemon a few beats
  # (and a nudge if the service is stopped after a boot) before
  # judging. Only a state that stays unlinked counts as dead.
  # The binary resolves by absolute path: sudo runs the kit with a
  # restricted PATH that omits /usr/local/bin, so a bare 'netbird'
  # would read as a dead mesh on a perfectly linked machine.
  local _NB _S _T
  _NB=""
  for _C in /usr/local/bin/netbird /usr/bin/netbird /usr/sbin/netbird; do
    [ -x "$_C" ] && { _NB="$_C"; break; }
  done
  [ -n "$_NB" ] || return 1
  if command -v systemctl >/dev/null 2>&1 \
     && ! systemctl is-active --quiet netbird 2>/dev/null; then
    "$_NB" service start >/dev/null 2>&1 || true
  fi
  for _T in 1 2 3 4 5; do
    _S=$("$_NB" status 2>/dev/null | tr 'A-Z' 'a-z')
    printf '%s' "$_S" | grep -q 'connected' || { sleep 3; continue; }
    printf '%s' "$_S" | grep -q 'needslogin' && { sleep 3; continue; }
    return 0
  done
  return 1
}
exec 3<>/dev/tty 2>/dev/null || exec 3>&1   # fd 3: the real terminal, both ways

# ---- optional TUI screen (gum) -------------------------------------------
# One pinned, sha256-verified gum binary turns the whole install into
# a single clean progress screen; every raw line still lands in the
# LOG. REDOUBT_TUI=0 opts out. If the download fails we fall back to
# plain output, so no machine is ever left without an installer.
tui_setup() {
  TUI=0
  [ "${REDOUBT_TUI:-1}" = "0" ] && return 0
  command -v gum >/dev/null 2>&1 && { TUI=1; return 0; }
  # the VGA console cannot render gum's escapes (they leak as raw
  # symbols): the headless path keeps the native bar and palette while
  # the noise still routes to the log, so the screen stays clean. The
  # the gum TUI belongs to modern terminals only.
  if [ "$TERM" = "linux" ]; then
    TUI=1
    return 0
  fi
  case "$(uname -m)" in
    x86_64)  GUM_ARCH=x86_64; GUM_SHA=d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2 ;;
    aarch64) GUM_ARCH=arm64;  GUM_SHA=8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5 ;;
    *)       return 0 ;;
  esac
  GUM_VER=2.0.2
  GUM_TMP=$(mktemp -d)
  curl -fsSL --max-time 90 -o "$GUM_TMP/gum.tgz" \
    "https://github.com/charmbracelet/gum/releases/download/v${GUM_VER}/gum_${GUM_VER}_Linux_${GUM_ARCH}.tar.gz" \
    || { rm -rf "$GUM_TMP"; return 0; }
  printf '%s  %s\n' "$GUM_SHA" "$GUM_TMP/gum.tgz" | sha256sum -c - >/dev/null 2>&1 \
    || { rm -rf "$GUM_TMP"; return 0; }
  mkdir -p /usr/local/bin /opt/redoubt/bin
  find "$GUM_TMP" -name gum -type f -exec install -m 755 {} /usr/local/bin/gum \;
  cp /usr/local/bin/gum /opt/redoubt/bin/gum 2>/dev/null || true
  rm -rf "$GUM_TMP"
  TUI=1
  echo "[redoubt-kit] TUI: gum v$GUM_VER ready" >>"$LOG"
}
tui_setup

# TUI or plain: noise goes to the log, milestones come through fd 3.
exec >> "$LOG" 2>&1

echo "[redoubt-kit] $(date -u +%FT%TZ) boot"
[ "$(id -u)" -ne 0 ] && { echo "FAIL: root required" >&3; exit 1; }

# The mesh pieces resolve their latest official release on every pass:
# the GitHub API names it and the download urls carry the version. The
# pinned fallback only covers a dead API, never a silently stale one.
latest_netbird() {
  curl -fsSL --max-time 30 https://api.github.com/repos/netbirdio/netbird/releases/latest 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','v0.79.0').lstrip('v'))" 2>/dev/null \
    || echo 0.79.0
}

# Grab the kit's own sha now. The script cds into $STACKDIR mid-run, so
# a relative $0 lookup later would silently fail. An old self-update hook
# never installed anywhere for exactly this reason. readlink pins the
# path while it still exists.
KIT_SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
KIT_SELF_SHA=$(sha256sum "$KIT_SELF" 2>/dev/null | awk '{print $1}')
# the monotonic build counter: the updater refuses to roll this
# machine back to an older (even validly signed) kit
KIT_BUILD="44"

# Self-heal: a run that got killed can leave the DNS lockdown active while
# the resolver chain never came up on 127.0.0.1:53 (pi-hole fronts
# unbound). The box is then DNS-dead and
# nothing below can fetch anything. If the rules exist but nothing answers
# on 127.0.0.1:53, drop them before touching the network.
if command -v nft >/dev/null 2>&1 && nft list table inet redoubt-dns >/dev/null 2>&1; then
  if ! (exec 3<>/dev/tcp/127.0.0.1/53) 2>/dev/null; then
    nft delete table inet redoubt-dns 2>/dev/null || true
    systemctl stop redoubt-dns-fw 2>/dev/null || true
    dbg "recovered from a DNS lockdown left by an interrupted run"
  fi
fi

# A wiped box can keep the OLD resolver pin too: NetworkManager or a
# resolved drop-in still pointing the system DNS at 127.0.0.1:53, where
# the shield lives. On a fresh pass the stack does not exist yet, so
# every lookup (the mesh menu, the browser login, the pulls) would
# DNS-die with the pin intact. If the pin sits on a dead local 53,
# swing it to Quad9 for the pass; the DNS section re-pins the shield
# once the stack is up. A healthy box (shield answering) skips this.
if ! (exec 3<>/dev/tcp/127.0.0.1/53) 2>/dev/null; then
  if grep -q '^nameserver[[:space:]]*127\.0\.0\.1' /etc/resolv.conf 2>/dev/null \
     && command -v nmcli >/dev/null 2>&1; then
    for _CON in $(nmcli -t -f NAME connection show --active 2>/dev/null); do
      nmcli connection modify "$_CON" ipv4.dns "9.9.9.9, 149.112.112.112" ipv4.ignore-auto-dns yes >/dev/null 2>&1
    done
    nmcli connection up "$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)" >/dev/null 2>&1 || true
    dbg "recovered from a stale resolver pin (shield down, Quad9 for the pass)"
  fi
  for _DP in /etc/systemd/resolved.conf.d/*.conf; do
    [ -f "$_DP" ] || continue
    if grep -q 'DNS=127\.0\.0\.1' "$_DP" 2>/dev/null; then
      sed -i 's|^DNS=127\.0\.0\.1.*|DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net|' "$_DP"
      systemctl restart systemd-resolved >/dev/null 2>&1 || true
      dbg "recovered from a stale resolved pin (shield down, Quad9 for the pass)"
    fi
  done
fi

# 1) Figure out the package family. The code below speaks apt, pacman,
#    dnf and zypper; the gate accepts any distro whose ID or ID_LIKE maps
#    to one of them (Pop!_OS and Mint count as ubuntu, CachyOS/Manjaro/
#    Endeavour as arch, and so on).
. /etc/os-release
PKG_FAMILY=""
case "${ID_LIKE:-} $ID" in
  *debian*|*ubuntu*) PKG_FAMILY=apt ;;
  *arch*)            PKG_FAMILY=pacman ;;
  *fedora*|*rhel*)   PKG_FAMILY=dnf ;;
  *suse*)            PKG_FAMILY=zypper ;;
  *) echo "FAIL: unsupported distro: $ID" >&3; exit 2;;
esac
dbg "OK: distro $ID ${VERSION_ID:-rolling} (family: $PKG_FAMILY)"

# 1.5) The kit's ground rules.
# (a) No WSL. The kit must not cannibalize the
#     Windows installer; Windows customers have their own purchase path.
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  echo "FAIL: this is WSL (Windows Subsystem for Linux)." >&3
  echo "The Linux kit does not install inside Windows."
  echo "For Windows, use the Redoubt installer: https://tryredoubt.com"
  exit 7
fi

# (b) No age verification. Redoubt does not run where the age-
#     surveillance machinery lives (birthDate in the systemd userdb, the
#     attestation daemon). Receipts: agelesslinux.org and the community
#     tracker github.com/BryanLunduke/DoesItAgeVerify.
#     This targets age gates built into the OS. Parental controls
#     the owner turns on themselves (malcontent and friends) are their
#     own choice and never trip this check.
AGE_HIT=""
# (i) birthDate baked into systemd user records; checked for every user
if command -v userdbctl >/dev/null 2>&1; then
  while read -r U; do
    [ -z "$U" ] && continue
    if userdbctl user "$U" --output=json 2>/dev/null | grep -qiE '"birthDate"'; then
      AGE_HIT="birthDate present in systemd user records (user: $U)"
      break
    fi
  done <<EOF
$(userdbctl user --output=json 2>/dev/null | grep -oE '"userName"\s*:\s*"[^"]+"' | cut -d'"' -f4)
EOF
fi
# (ii) An age-verification daemon running as a process. Self-match guard:
#     walk our ancestors and exclude them. A wrapper invoking this kit may
#     legitimately contain these words in its own command line, while a
#     real daemon lives under PID 1, never under us.
if [ -z "$AGE_HIT" ] && command -v pgrep >/dev/null 2>&1; then
  SELF="$$"
  P=$PPID
  while [ -n "$P" ] && [ "$P" -gt 1 ]; do
    SELF="$SELF|$P"
    P=$(ps -o ppid= -p "$P" 2>/dev/null | tr -d ' ')
  done
  if pgrep -f 'age[-_ ]*(verif|gate|attest|assur)' 2>/dev/null | grep -qvE "^($SELF)$"; then
    AGE_HIT="age verification daemon process active"
  fi
fi
# (iii) An age-gate service registered with systemd
if [ -z "$AGE_HIT" ] && systemctl list-units --type=service --no-legend 2>/dev/null | grep -qiE 'age[-_ ]*(verif|gate|attest|assur)'; then
  AGE_HIT="age verification service registered in systemd"
fi
# (iv) An age-gate package installed (Debian/Ubuntu base)
if [ -z "$AGE_HIT" ] && command -v dpkg >/dev/null 2>&1 && dpkg -l 2>/dev/null | grep -qiE 'age[-_ ]*(verif|gate|attest|assur)'; then
  AGE_HIT="age verification package installed"
fi
if [ -n "$AGE_HIT" ]; then
  echo "FAIL: this machine has an age gate built into the system." >&3
  echo "Detected: $AGE_HIT" >&3
  echo "" >&3
  echo "Redoubt is a private cloud - a machine that gates its owner is the" >&3
  echo "opposite of what we build, so the kit stops here and changes nothing." >&3
  echo "" >&3
  echo "What you can do:" >&3
  echo "  - Install a distribution without an age gate:" >&3
  echo "    https://github.com/BryanLunduke/DoesItAgeVerify" >&3
  echo "  - Or use the Redoubt disk image: it ships a clean system." >&3
  echo "" >&3
  echo "Details: https://tryredoubt.com/principles" >&3
  exit 8
fi

# 1.6) The banner. A fresh install gets the full welcome, a re-run
#     (patching an existing cloud) the compact one. Plain ANSI colors:
#     terminals that ignore them just show the text.
# the VGA console has no truecolor and maps the emerald gradient to an
# off blue: hand it the native greens so the brand reads the same there
if [ "$TERM" = "linux" ]; then
  EM1=$'\033[32m'; EM2=$'\033[1;32m'; EM3=$'\033[1;37m'; EM1B=$'\033[1;32m'; ERR=$'\033[1;31m'; RESET=$'\033[0m'
else
  EM1=$'\033[38;2;52;211;153m'; EM2=$'\033[38;2;110;231;183m'; EM3=$'\033[38;2;167;243;208m'; EM1B=$'\033[1;38;2;52;211;153m'; ERR=$'\033[38;2;248;113;113m'; RESET=$'\033[0m'
fi
# Truncated labels must never carry a multibyte glyph onto the VGA
# console: it paints in CP437 mode there, where the ellipsis shows as
# junk. The desktop keeps the ellipsis, the console takes the tilde.
TRUNC='…'
[ "$TERM" = "linux" ] && TRUNC='~'
# The kernel's built-in console font has no block glyphs: the emerald
# wordmark would render as stray Latin-1 symbols. Load a console font
# that carries them (the classic sun16 set) so the original banner art
# draws with real blocks on the VGA console. Best effort: a console
# without kbd keeps the kernel font until the tools section installs it
# and the same loop below runs again.
if [ "$TERM" = "linux" ] && command -v setfont >/dev/null 2>&1; then
  for _F in lat0-sun16 latarcyrheb-sun16 LatArCyrHeb-16; do
    setfont "$_F" 2>/dev/null && break
  done
fi
# the kernel's console chatter (bridge/netfilter notices and the rest)
# must not bleed into the pass: keep the console at warnings and above,
# the dmesg buffer still keeps everything for the forensics
if command -v dmesg >/dev/null 2>&1; then
  dmesg -n 3 2>/dev/null || true
fi
print_bastion() {
  printf "${EM3}                            ..\n"
  printf "${EM3}                          .####.\n"
  printf "${EM3}                      .#..######..#.\n"
  printf "${EM3}                      ##############\n"
  printf "${EM3}               .      ##############     ..\n"
  printf "${EM3}             .###.    ..##########..    ####.\n"
  printf "${EM3}         .#..#####..#.  #########.  .#..#####..#.\n"
  printf "${EM3}         .#####..####.  ##########  .###..######.\n"
  printf "${EM3}         .#####.   .   .##########    .   .#####.\n"
  printf "${EM2}          .####     ..##############..    .###.\n"
  printf "${EM2}           .###   .########....########.   ###.\n"
  printf "${EM2}           ###.  .#####..        ..#####   ####\n"
  printf "${EM2}          .###.  .#..     .....     ####.  .###.\n"
  printf "${EM2}          ####.    ...##########    .###.  .####\n"
  printf "${EM2}         .####   .#####. .######.   .###.   ####.\n"
  printf "${EM2}         .###.   #####   .####..    .####   ####.\n"
  printf "${EM2}         ####.  .#####    .        .#####   .####\n"
  printf "${EM2}        .####.  .####.           .#####.    .####.\n"
  printf "${EM2}        #####   .####.    ...    .#####..    #####\n"
  printf "${EM1}       .#####   #####.   .####.    .#######..#####.\n"
  printf "${EM1}       #######..#####.   .#####.    .#############.\n"
  printf "${EM1}       .#############.   .#######.    ############.\n"
  printf "${EM1}          ..#########.    ########.    .######..\n"
  printf "${EM1}              .#########..#################.\n"
  printf "${EM1}                 ..####################..\n"
  printf "${EM1}                     .##############.\n"
  printf "${EM1}                        ..######..\n"
  printf "${EM1}                            ..\n"
}

REINSTALL=0
[ -f /etc/redoubt/redoubt.env ] && REINSTALL=1
# a screen on the machine flips the join to the NetBird app and changes
# the last lines of the reveal: keep the flag global with a headless
# default, the mesh menu and section 6b refine it with their own probes
HAS_GUI=0
# the probes run here, up front: a re-run skips the menu block where
# the old detection lived, and 6b only runs when the host key exists,
# so a desktop re-run would otherwise fall back to headless texts
if command -v loginctl >/dev/null 2>&1; then
  for S in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    T=$(loginctl show-session "$S" -p Type --value 2>/dev/null || true)
    case "$T" in x11|wayland) HAS_GUI=1; break ;; esac
  done
fi
if [ "$HAS_GUI" = "0" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  HAS_GUI=1
fi
if [ "$HAS_GUI" = "0" ]; then
  ls /usr/share/xsessions/*.desktop >/dev/null 2>&1 && HAS_GUI=1
  ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1 && HAS_GUI=1
fi
# The session's X authority cookie: a browser launch without it gets
# the X server's silent "cannot open display" (a fresh Parrot install
# ships the cookie; the first real launch then auto-creates the
# firefox profile, so no seeding step is needed). A missing cookie is
# harmless: the launch env below simply skips it.
_XACOOKIE=""
if [ "$HAS_GUI" = "1" ] && [ -n "${SUDO_USER:-}" ]; then
  for _XF in /run/user/*/xauth_*; do
    [ -f "$_XF" ] || continue
    [ "$(stat -c %U "$_XF" 2>/dev/null || true)" = "$SUDO_USER" ] || continue
    _XACOOKIE="$_XF"
    break
  done
fi
{
# The VGA console renders the original wordmark once a console font
# with block glyphs is loaded above (the kernel font would show stray
# Latin-1 symbols instead). Same art as the desktop banner, native
# greens. The desktop path never reaches this function, so the emerald
# art with truecolor stays untouched for real terminals.
print_banner_vga() {  # $1 = the tagline under the art
  printf "${EM1}██████╗ ███████╗██████╗  ██████╗ ██╗   ██╗██████╗ ████████╗${RESET}\n" >&3
  printf "${EM2}██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║   ██║██╔══██╗╚══██╔══╝${RESET}\n" >&3
  printf "${EM3}██████╔╝█████╗  ██║  ██║██║   ██║██║   ██║██████╔╝   ██║${RESET}\n" >&3
  printf "${EM2}██╔══██╗██╔══╝  ██║  ██║██║   ██║██║   ██║██╔══██╗   ██║${RESET}\n" >&3
  printf "${EM1}██║  ██║███████╗██████╔╝╚██████╔╝╚██████╔╝██████╔╝   ██║${RESET}\n" >&3
  printf "${EM3}╚═╝  ╚═╝╚══════╝╚═════╝  ╚═════╝  ╚═════╝ ╚═════╝    ╚═╝${RESET}\n" >&3
  # the tagline centers on the bastion's 56-column canvas above
  printf -v _TAGPAD '%*s' "$(( (56 - ${#1}) / 2 ))" ''
  printf "${EM2}%s%s${RESET}\n" "$_TAGPAD" "$1" >&3
}

# a rule with the banner gradient: three emerald tones, one line
print_rule() {
  printf '%s\n' "${EM1}══════════════════════════${EM2}══════════════════════════${EM3}══════════════════════════${RESET}"
}

# The real logo, traced to ASCII from the master PNG (56 columns):
# the bastion, emerald gradient top to bottom, over the wordmark.
print_bastion
printf "$EM1\n" >&3
if [ "$TERM" = "linux" ]; then
  if [ "$REINSTALL" = "1" ]; then
    print_banner_vga "repatch - your cloud gets an update"
  else
    print_banner_vga "your private cloud, installed by you"
  fi
else
  if [ "$REINSTALL" = "1" ]; then
    cat <<BANNER >&3
${EM1}██████╗ ███████╗██████╗  ██████╗ ██╗   ██╗██████╗ ████████╗${RESET}
${EM2}██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║   ██║██╔══██╗╚══██╔══╝${RESET}
${EM3}██████╔╝█████╗  ██║  ██║██║   ██║██║   ██║██████╔╝   ██║${RESET}
${EM2}██╔══██╗██╔══╝  ██║  ██║██║   ██║██║   ██║██╔══██╗   ██║${RESET}
${EM1}██║  ██║███████╗██████╔╝╚██████╔╝╚██████╔╝██████╔╝   ██║${RESET}
${EM3}╚═╝  ╚═╝╚══════╝╚═════╝  ╚═════╝  ╚═════╝ ╚═════╝    ╚═╝${RESET}

             ${EM2}repatch - your cloud gets an update${RESET}
BANNER
  else
    cat <<BANNER >&3
${EM1}██████╗ ███████╗██████╗  ██████╗ ██╗   ██╗██████╗ ████████╗${RESET}
${EM2}██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║   ██║██╔══██╗╚══██╔══╝${RESET}
${EM3}██████╔╝█████╗  ██║  ██║██║   ██║██║   ██║██████╔╝   ██║${RESET}
${EM2}██╔══██╗██╔══╝  ██║  ██║██║   ██║██║   ██║██╔══██╗   ██║${RESET}
${EM1}██║  ██║███████╗██████╔╝╚██████╔╝╚██████╔╝██████╔╝   ██║${RESET}
${EM3}╚═╝  ╚═╝╚══════╝╚═════╝  ╚═════╝  ╚═════╝ ╚═════╝    ╚═╝${RESET}

           ${EM2}your private cloud, installed by you${RESET}
BANNER
  fi
fi
printf "$RESET"
echo ""
} >&3

# One bar that climbs 0 to 100 with the real work, pacman style. Each
# step owns a segment of the bar; feeders map their real progress into
# that segment, so the bar moves as fast as the bytes do. The label
# changes in place as steps land. No resets, no dead bars.
STAGE=0
STAGES=8
# the docker install section feeds the bar before the first step() call,
# so the segment bounds have to exist from the start
SEG_START=0
SEG_END=10
BAR_PCT=0
BAR_LABEL=""
ANIM_PID=""
LAST_PCT=""
LAST_LABEL=""
BAR_STATE=$(mktemp /tmp/redoubt-bar.XXXXXX)
dot_f() {  # $1 = frame index, one braille frame, cycles 0..9
  case $(( $1 % 10 )) in
    0) printf '⠋' ;; 1) printf '⠙' ;; 2) printf '⠹' ;; 3) printf '⠸' ;; 4) printf '⠼' ;;
    5) printf '⠴' ;; 6) printf '⠦' ;; 7) printf '⠧' ;; 8) printf '⠇' ;; 9) printf '⠏' ;;
  esac
}
dot_frame() {  # wall-clock frame, ~30fps
  local micros
  micros=${EPOCHREALTIME#*.}
  # 10# forces base-10; "09" would otherwise be read as octal and blow up
  printf '%d' $(( 10#${micros:0:2} / 5 % 10 ))
}
# the VGA console has no unicode glyphs and no truecolor: the bar
# paints with raw CP437 block bytes (0xdb full, 0xb1 half) after leaving
# UTF-8 mode, the emerald brand maps to the VGA green, and the spinner
# is plain ascii. The desktop path never reaches this function.
draw_line_vga() {  # $1 = bar width, $2 = fill cells, $3 = pct, $4 = label
  local W=$1 F=$2 PCT=$3 LABEL=$4 f sp REST BODY
  f=$(dot_frame)
  case $(( f % 4 )) in 0) sp='-' ;; 1) sp='\\' ;; 2) sp='|' ;; 3) sp='/' ;; esac
  # the check glyph is UTF-8 only: hand the VGA console the plain "+"
  LABEL=${LABEL//✓/+}
  LABEL_MAX=$(( ${COLUMNS:-80} - W - 16 ))
  [ "$LABEL_MAX" -lt 8 ] && LABEL_MAX=8
  if [ ${#LABEL} -gt "$LABEL_MAX" ]; then
    LABEL="${LABEL:0:$((LABEL_MAX-1))}~"
  fi
  printf -v REST '%*s' "$(( W - F ))" ''
  REST=${REST// /-}
  if [ "$F" -gt 0 ]; then
    # bash swaps the multibyte block itself, so no tr (tr would work
    # byte-wise and mangle the UTF-8 under a non-utf locale)
    printf -v BODY '%*s' "$(( F - 1 ))" ''
    BODY=${BODY// /█}
    printf "${EM1}  %s${EM3}█${EM1}%s %3d%%  %s %s${RESET}\033[K\r" "$BODY" "$REST" "$PCT" "$LABEL" "$sp" >&3
  else
    printf "${EM1}  %s %3d%%  %s %s${RESET}\033[K\r" "$REST" "$PCT" "$LABEL" "$sp" >&3
  fi
}

draw_line() {  # Paints the current state. Only the animator loop calls this.
  local W F FILL REST BODY f sp
  # The animator runs in a forked child, so read the state the parent wrote.
  if [ -n "$BAR_STATE" ] && [ -f "$BAR_STATE" ]; then
    IFS='|' read -r BAR_PCT BAR_LABEL < "$BAR_STATE"
  fi
  case "$BAR_PCT" in ''|*[!0-9]*) BAR_PCT=0 ;; esac
  # The bar adapts to the terminal but always reserves 58 columns for the
  # label, step counter, % and dots, leaving 10..22 cells for the bar.
  # A line that hits exactly COLUMNS wraps, and a wrapped line breaks the
  # \r redraw, so the bar flickers. Hence the cap.
  W=$(( ${COLUMNS:-80} - 58 ))
  [ "$W" -gt 22 ] && W=22
  [ "$W" -lt 10 ] && W=10
  F=$(( BAR_PCT * W / 100 ))
  if [ "$TERM" = "linux" ]; then
    draw_line_vga "$W" "$F" "$BAR_PCT" "$BAR_LABEL"
    return
  fi
  if [ "${TUI:-0}" = "1" ]; then
    # the gum screen stays clean: no block glyphs (they
    # render as broken pieces on modern terminals), one
    # overwritten line with the spinner, the % and the label
    if [ -t 3 ]; then
      f=$(dot_frame)
      sp="$(dot_f "$f")"
      LABEL_MAX=$(( ${COLUMNS:-80} - 16 ))
      [ "$LABEL_MAX" -lt 8 ] && LABEL_MAX=8
      if [ ${#BAR_LABEL} -gt "$LABEL_MAX" ]; then
        BAR_LABEL="${BAR_LABEL:0:$((LABEL_MAX-1))}…"
      fi
      printf "${EM1B}  %3d%%  %s %s${RESET}\033[K\r" "$BAR_PCT" "$BAR_LABEL" "$sp" >&3
    fi
    return
  fi
  # printf %*s sets the width, then bash swaps spaces for glyphs at the
  # string level. tr would mangle the multibyte ▰ (it works on bytes, not
  # characters) and leave broken UTF-8 behind.
  printf -v FILL '%*s' "$F" ''
  FILL=${FILL// /▰}
  printf -v REST '%*s' "$(( W - F ))" ''
  REST=${REST// /▱}
  if [ -t 3 ]; then
    # One braille dot on the wall clock: a calm signal, no extra
    # animated noise. The animator repaints ~30 times a second, so the
    # dot spins on its own rhythm instead of waiting for bar updates.
    f=$(dot_frame)
    sp="$(dot_f "$f")"
    # The label gets its own budget (2 + bar + % + separators + dots).
    # Over budget it would wrap the line and break the \r redraw.
    LABEL_MAX=$(( ${COLUMNS:-80} - W - 16 ))
    [ "$LABEL_MAX" -lt 8 ] && LABEL_MAX=8
    if [ ${#BAR_LABEL} -gt "$LABEL_MAX" ]; then
      BAR_LABEL="${BAR_LABEL:0:$((LABEL_MAX-1))}…"
    fi
    # The fill is a clean emerald run with no decorative head cell
    # (the bright block at the start did nothing and was removed on
    # feedback). \033[K clears the rest of the line so a shorter label
    # never leaves the tail of the previous one behind.
    if [ "$F" -gt 0 ]; then
      printf -v BODY '%*s' "$F" ''
      BODY=${BODY// /▰}
      printf "${EM1B}  %s${EM1}%s %3d%%  %s %s${RESET}\033[K\r" "$BODY" "$REST" "$BAR_PCT" "$BAR_LABEL" "$sp" >&3
    else
      printf "${EM1B}  %s %3d%%  %s %s${RESET}\033[K\r" "$REST" "$BAR_PCT" "$BAR_LABEL" "$sp" >&3
    fi
  else
    # Non-tty (background runs, logs): print on state changes, not
    # 30 times a second.
    if [ "$BAR_PCT" != "$LAST_PCT" ] || [ "$BAR_LABEL" != "$LAST_LABEL" ]; then
      printf '  %d%%  %s\n' "$BAR_PCT" "$BAR_LABEL" >&3
      LAST_PCT=$BAR_PCT
      LAST_LABEL=$BAR_LABEL
    fi
  fi
}
bar_anim() {  # Single writer: repaints the line at ~30fps forever. Dots
  # run on the clock, the bar on the state file. Two rhythms, one line.
  while :; do
    draw_line
    sleep 0.033
  done
}
draw_bar() {  # $1 = pct, $2 = label. Writes the state for the animator.
  # Background & in bash forks, so the child never sees the parent's
  # variables. State travels through a small file instead.
  BAR_PCT=$1
  case "$BAR_PCT" in ''|*[!0-9]*) BAR_PCT=0 ;; esac
  BAR_LABEL=$2
  # the bar only moves forward: a step may discover more work than it
  # first counted (pull totals grow), and a backwards bar looks broken
  [ "$BAR_PCT" -lt "${LAST_BAR_PCT:-0}" ] && BAR_PCT=$LAST_BAR_PCT
  LAST_BAR_PCT=$BAR_PCT
  [ -n "$BAR_STATE" ] && printf '%s|%s\n' "$BAR_PCT" "$BAR_LABEL" > "$BAR_STATE"
  # Non-tty again: no animator on the other side, so print state changes
  # directly.
  if [ ! -t 3 ] && { [ "$BAR_PCT" != "$LAST_PCT" ] || [ "$BAR_LABEL" != "$LAST_LABEL" ]; }; then
    printf '  %d%%  %s\n' "$BAR_PCT" "$BAR_LABEL" >&3
    LAST_PCT=$BAR_PCT
    LAST_LABEL=$BAR_LABEL
  fi
  # a log() line above killed the painter: relaunch it on the tty so
  # the bar keeps walking after every milestone. The repatch hold
  # keeps it down until the mesh question is answered.
  if [ -t 3 ] && [ "${HOLD_BAR:-0}" != "1" ] \
     && { [ -z "${ANIM_PID:-}" ] || ! kill -0 "$ANIM_PID" 2>/dev/null; }; then
    bar_anim &
    ANIM_PID=$!
  fi
}
step() {  # $1 = label. Milestones land the bar at the segment start.
  STAGE=$((STAGE+1))
  SEG_START=$(( (STAGE-1)*100/STAGES ))
  SEG_END=$(( STAGE*100/STAGES ))
  draw_bar "$SEG_START" "$1 (step $STAGE/$STAGES)"
}

# Real progress, not decoration: a feeder reads the stream of a long step,
# counts the work items (docker layers, apt packages) and maps them into
# that step's segment of the global bar, pacman style.
apt_feed() {  # $1 = seg start, $2 = seg end, $3 = label. Package stream.
  # Transparency: each real package action prints as its own line, like a
  # pacman cascade, and the bar re-pins right below it. The client watches
  # each package land and the overall progress at the same time.
  # A 4th arg (quiet) keeps the cascade off the screen: the engine install
  # is a big one and its package flood reads as noise before the first
  # real question. The bar still lands on done at the end.
  local line DONE=0 P DETAIL="" QUIET="${4:-}"
  while IFS= read -r line; do
    echo "$line" >> "$LOG"
    case "$line" in
      *"Get:"*|*"npacking"*|*"Setting up"*|*"nstalling"*|*"reparing"*|*"Upgrading"*)
        DONE=$((DONE+1))
        DETAIL=$line
        case "$DETAIL" in
          *"Unpacking "*|*"Setting up "*|*"Installing "*|*"Preparing "*)
            if [ -z "$QUIET" ]; then
              # Only real milestones cascade (a package landing), never the
              # Get: flood. The client sees what installs, not a wall of
              # green noise.
              DETAIL=${DETAIL#"${DETAIL%%[A-Za-z]*}"}
              [ ${#DETAIL} -gt 60 ] && DETAIL="${DETAIL:0:57}${TRUNC}"
              printf "  ${EM2}%s\033[0m\n" "$DETAIL" >&3
              [ "$DONE" -gt 49 ] && DONE=49
              P=$(( $1 + ( $2 - $1 ) * DONE / 50 ))
              draw_bar "$P" "$3"
            fi
            ;;
        esac
        ;;
    esac
  done
  [ "$DONE" -eq 0 ] && draw_bar "$2" "$3"
  [ -n "$QUIET" ] && draw_bar "$2" "$3"
}
cursor_hide
{ echo "Building your Redoubt. This takes a few minutes."; echo ""; } >&3
# The line painter goes live here: one writer at ~30fps, dots on the
# clock, bar on the state. Killed right before the final reveal.
# On a repatch with a human at the console the mesh question comes
# first: a bar that flashes for a few seconds and then gets
# interrupted by a question looks broken, so the painter stays down
# until the answer (the menu block clears the flag and launches it).
# The flag also tames draw_bar's self-heal, which would relaunch the
# painter on the first step and recreate the same flash.
HOLD_BAR=0
if [ -t 3 ] && [ "${REINSTALL:-0}" != "1" ]; then
  bar_anim &
  ANIM_PID=$!
elif [ -t 3 ]; then
  HOLD_BAR=1
fi

# The kernel's console loglevel sprays docker's bridge churn over the
# install screen (br-xxx: port N(veth) entered ... state and friends,
# KERN_INFO on every network the stack creates). Quiet the console for
# the pass: the messages still land in dmesg and the journal, and the
# level is restored before the final reveal. Only errors break through.
QUIET_PK=""
if [ -r /proc/sys/kernel/printk ]; then
  # The value separates its four numbers with TABS, not spaces, so a
  # space pattern here would never match and the console would stay
  # loud. Read it, keep it verbatim for the restore, and write the
  # quiet level straight (the write is a harmless no-op in a jail).
  QUIET_PK=$(cat /proc/sys/kernel/printk 2>/dev/null || true)
  if [ -n "$QUIET_PK" ]; then
    sysctl -w kernel.printk="4 4 1 7" >/dev/null 2>&1 || true
  fi
fi
dbg "OK: principles: no WSL, no age verification"

# 2) Minimum disk / RAM
#    Golden images grow the disk before the guard: the image ships tight
#    (docker blobs eat the bake disk), the customer brings a bigger disk,
#    and growpart has to run before we measure.
if [ "${REDOUBT_GOLDEN_BOOT:-0}" = "1" ]; then
  ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null)
  ROOTDEV=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | head -1)
  if [ -n "$ROOTDEV" ] && [ -b "/dev/$ROOTDEV" ]; then
    growpart "/dev/$ROOTDEV" 1 2>/dev/null && resize2fs "$ROOTSRC" 2>/dev/null \
      && echo "OK: disk grown to full size" \
      || echo "WARNING: could not grow the disk"
  fi
fi
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
RAM_MB=$(free -m | awk '/Mem:/{print $2}')
dbg "free disk: ${DISK_GB}G | ram: ${RAM_MB}MB"
[ "$DISK_GB" -lt 5 ] && { echo "FAIL: disk < 5G" >&3; exit 3; }
[ "$RAM_MB" -lt 3500 ] && { echo "FAIL: ram < 3.5G (the full stack needs ~4G)" >&3; exit 4; }

# 3) Docker from the official repos. The podman shim counts as "no
#    docker": Parrot and friends ship a docker-cli emulated by podman,
#    which answers 'docker version' but can't run the stack. Install the real engine.
if ! command -v docker >/dev/null 2>&1 || docker info 2>&1 | grep -qi podman; then
  dbg "installing docker..."
  case "$PKG_FAMILY" in
    apt)
      apt-get update -y 2>&1 | apt_feed "$SEG_START" "$SEG_END" "base packages (downloading lists)" ; apt-get install -y ca-certificates curl gnupg 2>&1 | apt_feed "$SEG_START" "$SEG_END" "base packages"
      install -m 0755 -d /etc/apt/keyrings
      # The docker repo is named after the family, not the distro: Pop!_OS
      # and Mint publish under ubuntu, Raspberry Pi OS under debian, etc.
      case "$ID ${ID_LIKE:-}" in
        *ubuntu*) DOCKER_REPO=ubuntu ;;
        *)        DOCKER_REPO=debian ;;
      esac
      # The codename docker wants: Ubuntu-based distros carry the Ubuntu
      # codename they are built on; Debian carries its own.
      DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      # Distros that publish under their own codename (Parrot: lory, ...)
      # are not on download.docker.com, so fall back to the Debian release
      # the box is built on. /etc/debian_version is the authority here.
      if ! curl -fsSI --max-time 15 "https://download.docker.com/linux/${DOCKER_REPO}/dists/${DOCKER_CODENAME}/Release" >/dev/null 2>&1; then
        DEBVER=$(cut -d. -f1 /etc/debian_version 2>/dev/null)
        case "$DEBVER" in
          13) DOCKER_CODENAME=trixie ;;
          12) DOCKER_CODENAME=bookworm ;;
          11) DOCKER_CODENAME=bullseye ;;
        esac
        dbg "docker repo has no '$DOCKER_CODENAME', using $DOCKER_CODENAME (Debian $DEBVER)"
      fi
      # The podman emulation package conflicts with the real engine. Drop it.
      dpkg -l podman-docker >/dev/null 2>&1 && apt-get remove -y -qq podman-docker
      curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO}/gpg" -o /etc/apt/keyrings/docker.asc
      # The trust anchor for every docker package must match Docker's
      # published fingerprint. No TOFU on the key that signs the engine.
      # gpg prints the fingerprint with spaces; strip them before matching.
      if ! gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc 2>/dev/null | tr -d ' ' | grep -qi '9DC858229FC7DD38854AE2D88D81803C0EBFCD88'; then
        dbg "WARNING: docker gpg key fingerprint mismatch - not adding the repo"
        rm -f /etc/apt/keyrings/docker.asc
      fi
      # the repo only goes in with its verified key next to it: a
      # machine without gpg (Debian cloud images) must never end up
      # with a half-added repo pointing at a missing key
      if [ -f /etc/apt/keyrings/docker.asc ]; then
        chmod a+r /etc/apt/keyrings/docker.asc 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_REPO} ${DOCKER_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
        chmod 644 /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
        apt-get update -y 2>&1 | apt_feed "$SEG_START" "$SEG_END" "docker engine (packages)" quiet ; apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>&1 | apt_feed "$SEG_START" "$SEG_END" "docker engine (packages)" quiet
      else
        echo "FAIL: docker repo key missing - the engine stays out (no key, no repo)" >&3
        exit 5
      fi
      # Removing podman-docker can take the docker group with it, and
      # docker.socket chowns to that group. Recreate it, or the engine
      # dies with a GROUP error right after a clean install.
      getent group docker >/dev/null 2>&1 || groupadd -f docker
      systemctl restart docker.socket 2>/dev/null || true
      ;;
    pacman)
      # Arch family: docker and the compose v2 plugin live in the official repos.
      pacman -Sy --noconfirm --needed docker docker-compose 2>&1 | apt_feed "$SEG_START" "$SEG_END" "docker engine (packages)"
      ;;
    dnf)
      # Drop the .repo file straight into yum.repos.d. dnf config-manager
      # changed syntax on newer Fedoras; this path works on all of them.
      # Order matters: Rocky/Alma ID_LIKE carries "rhel centos fedora", so
      # the RHEL-alikes must match BEFORE the fedora pattern or they land
      # in the fedora repo and dnf 404s on the repomd. RHEL-alikes take
      # the rhel repo (Rocky/Alma are built against the RHEL packages).
      case "$ID ${ID_LIKE:-}" in
        *rhel*|*centos*|*rocky*|*alma*) DOCKER_REPO=rhel ;;
        *fedora*)                       DOCKER_REPO=fedora ;;
        *)                              DOCKER_REPO=rhel ;;
      esac
      curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO}/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
      dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>&1 | apt_feed "$SEG_START" "$SEG_END" "docker engine (packages)" quiet
      ;;
    zypper)
      zypper --non-interactive install docker docker-compose >> "$LOG" 2>&1 || true
      ;;
    *)
      echo "FAIL: unsupported distro '$ID' - docker needs Debian/Ubuntu, Arch, the Fedora family or openSUSE" >&3
      exit 5
      ;;
  esac
  systemctl enable --now docker
  # the owner drives docker through the 'redoubt' CLI without sudo: the
  # group is docker's gate, and the next login picks the membership up
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
  fi
fi
docker version --format 'OK docker {{.Server.Version}}' >> "$LOG" 2>&1 || { echo "FAIL: docker not responding" >&3; exit 5; }
# the headless console paints QRs on the framebuffer: the painter tools
# ride the base install now, so the QR itself is instant when it shows
# up later. GUI machines and ssh sessions never reach this branch.
if [ "$TERM" = "linux" ]; then
  { command -v qrencode >/dev/null 2>&1 && command -v fbi >/dev/null 2>&1 \
    && command -v openvt >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1 \
    && python3 -c 'import PIL' >/dev/null 2>&1; } \
    || case "$PKG_FAMILY" in
      apt) apt-get install -y -qq qrencode fbi kbd python3-pil >/dev/null 2>&1 || true ;;
      pacman) pacman -S --noconfirm --needed qrencode fbida kbd python-pillow >/dev/null 2>&1 || true ;;
      dnf) dnf install -y -q epel-release >/dev/null 2>&1 || true
           dnf install -y -q qrencode kbd python3-pillow >/dev/null 2>&1 || true
           dnf install -y -q fbida >/dev/null 2>&1 || true ;;
      zypper) zypper --non-interactive install qrencode kbd python3-Pillow >/dev/null 2>&1 || true ;;
    esac
  if { command -v qrencode >/dev/null 2>&1 && command -v fbi >/dev/null 2>&1 \
       && command -v openvt >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; }; then
    dbg "OK: qr painter tools ready (headless console)"
    # kbd may have just landed on a fresh box: the banner above drew
    # without the block font, so load it now for every later pass
    if [ "$TERM" = "linux" ] && command -v setfont >/dev/null 2>&1; then
      for _F in lat0-sun16 latarcyrheb-sun16 LatArCyrHeb-16; do
        setfont "$_F" 2>/dev/null && break
      done
    fi
  else
    # technical detail, not for the screen: the codes go out as links
    dbg "painter tools unavailable, the codes go out as text links"
  fi
fi
step "docker engine ready"

# 3b) No credentials needed. A free install runs the full product on the
#     legacy tunnel identity. A redeemed license (or the golden image)
#     drops its credentials in later; everything else stays the same.
if [ -z "${REDOUBT_PREAUTH_KEY:-}" ] && [ -z "${REDOUBT_BOOTSTRAP_URL:-}" ] && [ -z "${REDOUBT_LICENSE_URL:-}" ]; then
  dbg "free mode - no license linked; the mesh uses the legacy identity"
fi

# 3c) Golden mode: first boot at the customer's home. The kit
# ships pre-baked in the image, stack and images included. From here on
# it's disk growth, the license code, and everything else unattended.
if [ "${REDOUBT_GOLDEN_BOOT:-0}" = "1" ]; then
  # (The disk already grew in section 2, before the guard.)
  if [ -z "${REDOUBT_PREAUTH_KEY:-}" ] && [ -n "${REDOUBT_LICENSE_URL:-}" ] && { [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; }; then
    LIC=""
    printf 'Enter your Redoubt license code: ' >&3
    stty echo icanon <&3 2>/dev/null || true
    cursor_show
    read -r LIC <&3 2>/dev/null || true
    cursor_hide
    # the server only mints codes of letters and digits; anything else
    # can never be valid, so drop it before it reaches the json body
    LIC="$(printf '%s' "$LIC" | tr -cd 'A-Za-z0-9')"
    if [ -n "${LIC:-}" ]; then
      KEY=$(curl -s --max-time 30 -X POST "${REDOUBT_LICENSE_URL%/api/v1/*}/api/v1/license/redeem" \
        -H "Content-Type: application/json" -d "{\"code\":\"$LIC\"}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('preauth_key',''))" 2>/dev/null)
      [ -n "$KEY" ] && REDOUBT_PREAUTH_KEY="$KEY" || echo "WARNING: invalid code or key server unreachable"
    fi
  fi
  log "=== Redoubt: your private cloud is getting ready (do not turn off this machine) ==="
fi

# 4) The private stack (Immich + Nextcloud + SearXNG). Binds on 127.0.0.1, data under /var/lib/redoubt.
STACKDIR=/opt/redoubt
mkdir -p "$STACKDIR" /opt/redoubt/dockge/data /var/lib/redoubt/{immich,immich-db,nextcloud,nextcloud-db,searxng,caddy-local,netbird,dockge} /var/lib/redoubt/nextcloud/{config,data} /opt/stacks

# SELinux enforcing: every bind the stack mounts is born with the
# wrong type (the umask 077 dirs are not labeled by docker, which
# never relabels bind mounts), so the containers that own them die
# with EACCES and the stack crash-loops. Give the whole data tree plus
# the dockge binds the svirt type docker expects, before the first
# compose up.
if [ -d /sys/fs/selinux ] && [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ] && command -v chcon >/dev/null 2>&1; then
  chcon -Rt svirt_sandbox_file_t /var/lib/redoubt /opt/redoubt/dockge /opt/stacks 2>/dev/null || true
  dbg "OK: SELinux relabeled the data dirs for docker (enforcing host)"
fi

# 4a) Generated credentials. The customer creates nothing; that's the promise.
genpass() { tr -dc 'A-Za-z0-9!@#%*_+-' < /dev/urandom | head -c 22; }
mkdir -p /etc/redoubt
if [ -f /etc/redoubt/redoubt.env ]; then
  # Re-runs reuse the credentials. Never regenerate: that would break the DBs.
  . /etc/redoubt/redoubt.env
  RERUN=1
  # one vault: dockge always follows the owner password, whatever
  # an older env file stored
  DOCKGE_PASS="$OWNER_PASS"
fi
if [ -z "${OWNER_PASS:-}" ]; then
  # No credentials in the env (golden flags or a fresh file): generate them.
  [ -f /etc/redoubt/redoubt.env ] && _HAD_ENV=1 || _HAD_ENV=0
  OWNER_USER="$(printf '%s' "${REDOUBT_OWNER_USER:-owner}" | tr -cd 'A-Za-z0-9._-' | cut -c1-24)"
  [ -n "$OWNER_USER" ] || OWNER_USER="owner"
  OWNER_PASS=$(genpass)
  IMMICH_DB_PASS=$(genpass)
  NC_DB_PASS=$(genpass)
  SEARXNG_SECRET=$(openssl rand -hex 32 2>/dev/null || genpass)
  IMMICH_PASS="$OWNER_PASS"
  DOCKGE_PASS="$OWNER_PASS"
  IMMICH_EMAIL="owner@redoubt.local"
  # The client's own NetBird coordinator secrets. The auth secret signs
  # login tokens, the cookie key encrypts sessions, and the store key
  # (32 bytes, base64; the coordinator decodes it and needs exactly 32)
  # encrypts the mesh database.
  MESH_AUTH_SECRET=$(tr -dc 'A-Za-z0-9!@#%*_+-' < /dev/urandom | head -c 32)
  MESH_COOKIE_KEY=$(tr -dc 'A-Za-z0-9!@#%*_+-' < /dev/urandom | head -c 32)
  MESH_STORE_KEY=$(openssl rand -base64 32 2>/dev/null | tr -d '\n')
  # the panel (homarr) encrypts its stored secrets with this key, and
  # the auth secret signs its login sessions. 64 hex chars each.
  HOMARR_SECRET=$(openssl rand -hex 32 2>/dev/null || genpass)
  HOMARR_AUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || genpass)
  cat >> /etc/redoubt/redoubt.env <<EOF
OWNER_USER="$OWNER_USER"
OWNER_PASS="$OWNER_PASS"
IMMICH_DB_PASS="$IMMICH_DB_PASS"
NC_DB_PASS="$NC_DB_PASS"
SEARXNG_SECRET="$SEARXNG_SECRET"
IMMICH_PASS="$IMMICH_PASS"
IMMICH_EMAIL="$IMMICH_EMAIL"
DOCKGE_PASS="$DOCKGE_PASS"
MESH_AUTH_SECRET="$MESH_AUTH_SECRET"
MESH_COOKIE_KEY="$MESH_COOKIE_KEY"
MESH_STORE_KEY="$MESH_STORE_KEY"
HOMARR_SECRET="$HOMARR_SECRET"
HOMARR_AUTH_SECRET="$HOMARR_AUTH_SECRET"
EOF
  chmod 600 /etc/redoubt/redoubt.env
  dbg "credentials generated"
else
  dbg "reusing existing credentials"
fi
# A fresh credentials set over an orphaned data tree is a broken
# marriage: the old database passwords died with the old env, so the
# containers would crash-loop on auth (seen on Rocky: immich edge
# 502 with "password authentication failed"). Quarantine the orphan
# instead of leaving a half-broken stack; nothing is deleted, the old
# tree just moves aside for whoever wants to dig it out.
if [ "${_HAD_ENV:-1}" = "0" ] && [ -d /var/lib/redoubt ] && [ -n "$(ls -A /var/lib/redoubt 2>/dev/null)" ]; then
  _STALE="/var/lib/redoubt.stale-$(date +%Y%m%d-%H%M%S)"
  mv /var/lib/redoubt "$_STALE" 2>/dev/null || true
  dbg "orphaned data tree quarantined to $_STALE (its passwords died with the old env)"
fi
# Dockge's credential was added after the rest, so machines that predate
# it get one generated here. Persist it so re-runs reuse the same one.
if [ -z "${DOCKGE_PASS:-}" ]; then
  DOCKGE_PASS="$OWNER_PASS"
  echo "DOCKGE_PASS=\"$DOCKGE_PASS\"" >> /etc/redoubt/redoubt.env
  chmod 600 /etc/redoubt/redoubt.env
fi
# pre-paperless builds stored the search secret under the old name:
# carry it over once and write the current one, so both sides of the
# rename read the same value on the next pass
if [ -z "${SEARXNG_SECRET:-}" ] && [ -n "${PAPERLESS_SECRET:-}" ]; then
  SEARXNG_SECRET="$PAPERLESS_SECRET"
  echo "SEARXNG_SECRET=\"$SEARXNG_SECRET\"" >> /etc/redoubt/redoubt.env
  chmod 600 /etc/redoubt/redoubt.env
fi
# machines that predate the panel get its two secrets here, same idiom
if [ -z "${HOMARR_SECRET:-}" ]; then
  HOMARR_SECRET=$(openssl rand -hex 32 2>/dev/null || genpass)
  echo "HOMARR_SECRET=\"$HOMARR_SECRET\"" >> /etc/redoubt/redoubt.env
  chmod 600 /etc/redoubt/redoubt.env
fi
if [ -z "${HOMARR_AUTH_SECRET:-}" ]; then
  HOMARR_AUTH_SECRET=$(openssl rand -hex 32 2>/dev/null || genpass)
  echo "HOMARR_AUTH_SECRET=\"$HOMARR_AUTH_SECRET\"" >> /etc/redoubt/redoubt.env
  chmod 600 /etc/redoubt/redoubt.env
fi
# Legacy envs can hold mesh secrets with YAML-hostile characters. A
# backslash in a double-quoted string either corrupts the value silently
# (\f is a form feed) or kills the parse (\. is an unknown escape); that
# was the netbird crash loop in the lab. They only guard the coordinator's
# auth, so regenerate whenever one leaves the safe set, and persist it.
for _mk in MESH_AUTH_SECRET MESH_COOKIE_KEY; do
  _mv=${!_mk-}
  case "$_mv" in
    *[!A-Za-z0-9!@#%*+_-]*)
      printf -v "$_mk" '%s' "$(tr -dc 'A-Za-z0-9!@#%*_+-' < /dev/urandom | head -c 32)"
      sed -i "s|^$_mk=.*|$_mk=\"${!_mk}\"|" /etc/redoubt/redoubt.env
      dbg "regenerated legacy $_mk (unsafe charset)"
      ;;
  esac
done
# 4b) Port pre-flight. Never start an install that will die mid-way on a
#     busy port. Defaults are the standard ports; anything taken gets a
#     random free one. Chosen ports persist in redoubt.env, so re-runs
#     keep the same addresses.
PORT_IMMICH="${PORT_IMMICH:-2283}"
PORT_NEXTCLOUD="${PORT_NEXTCLOUD:-8080}"
PORT_SEARXNG="${PORT_SEARXNG:-8081}"
PORT_EDGE1="${PORT_EDGE1:-8443}"
PORT_EDGE2="${PORT_EDGE2:-8444}"
PORT_EDGE3="${PORT_EDGE3:-8445}"
PORT_NETBIRD="${PORT_NETBIRD:-8390}"
PORT_NETBIRD_MGMT="${PORT_NETBIRD_MGMT:-33073}"
PORT_DASH="${PORT_DASH:-8448}"
PORT_EDGE4="${PORT_EDGE4:-8446}"
PORT_EDGE5="${PORT_EDGE5:-8447}"
PORT_EDGE_CDN="${PORT_EDGE_CDN:-443}"
PORT_DOCKGE="${PORT_DOCKGE:-8901}"

port_busy() { (echo >/dev/tcp/127.0.0.1/"$1") 2>/dev/null; }
pick_free() {
  local lo=$1 hi=$2 n
  for _ in $(seq 1 40); do
    n=$((lo + RANDOM % (hi - lo)))
    port_busy "$n" || { echo "$n"; return 0; }
  done
  return 1
}

PORTS_CHANGED=""
for spec in "IMMICH 2283" "NEXTCLOUD 8080" "SEARXNG 8081" "EDGE1 8443" "EDGE2 8444" "EDGE3 8445" "NETBIRD 8390" "NETBIRD_MGMT 33073" "DASH 8448" "EDGE4 8446" "EDGE5 8447" "EDGE_CDN 443" "DOCKGE 8901"; do
  set -- $spec
  NAME=$1; PN=PORT_$NAME; CUR=${!PN-}
  if port_busy "$CUR" && [ "${RERUN:-0}" != "1" ]; then
    NEW=$(pick_free 8400 9499) || { echo "FAIL: no free port found for $NAME" >&3; exit 9; }
    printf -v "PORT_$NAME" '%s' "$NEW"
    dbg "port $CUR is busy, $NAME now uses $NEW"
    PORTS_CHANGED="$PORTS_CHANGED PORT_$NAME=$NEW"
  elif port_busy "$CUR"; then
    # Update pass: the busy port is our own stack being replaced. Freeze
    # it, so the phone QRs stay valid across updates (same as the Windows exe).
    dbg "port $CUR busy but kept for $NAME (update pass, the phone QRs stay valid)"
  fi
done
if [ -n "$PORTS_CHANGED" ]; then
  sed -i '/^PORT_/d' /etc/redoubt/redoubt.env 2>/dev/null || true
  {
    echo "PORT_IMMICH=$PORT_IMMICH"
    echo "PORT_NEXTCLOUD=$PORT_NEXTCLOUD"
    echo "PORT_SEARXNG=$PORT_SEARXNG"
    echo "PORT_EDGE1=$PORT_EDGE1"
    echo "PORT_EDGE2=$PORT_EDGE2"
    echo "PORT_EDGE3=$PORT_EDGE3"
    echo "PORT_NETBIRD=$PORT_NETBIRD"
    echo "PORT_NETBIRD_MGMT=$PORT_NETBIRD_MGMT"
    echo "PORT_EDGE4=$PORT_EDGE4"
    echo "PORT_EDGE5=$PORT_EDGE5"
    echo "PORT_EDGE_CDN=$PORT_EDGE_CDN"
    echo "PORT_DOCKGE=$PORT_DOCKGE"
  } >> /etc/redoubt/redoubt.env
  chmod 600 /etc/redoubt/redoubt.env
  dbg "chosen ports saved to /etc/redoubt/redoubt.env"
fi
dbg "ports in use: immich $PORT_IMMICH, nextcloud $PORT_NEXTCLOUD, searxng $PORT_SEARXNG, edge $PORT_EDGE1/$PORT_EDGE2/$PORT_EDGE3, netbird $PORT_NETBIRD/$PORT_NETBIRD_MGMT, panel $PORT_EDGE4, ad shield $PORT_EDGE5, dockge $PORT_DOCKGE"

# The LAN address the phone has to use. localhost only works on the
# machine itself. Detected once here, then reused by the stack, the edge
# and the welcome guide.
LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[ -z "$LAN_IP" ] && LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.10"
dbg "LAN address: $LAN_IP"
# the split-DNS name: every surface (panel, tiles, apps) uses
# redoubt.lan, so the same links work at home (the local pi-hole
# resolves it to this LAN address) and away (the mesh zone resolves
# it to the mesh address). The box itself pins it in /etc/hosts.
LAN_CIDR=$(ip -o -4 addr show 2>/dev/null | awk -v ip="$LAN_IP" 'index($4, ip "/") == 1 {print $4; exit}')
[ -z "$LAN_CIDR" ] && LAN_CIDR="$LAN_IP/24"
sed -i '/[[:space:]]redoubt\.lan[[:space:]]*$/d' /etc/hosts 2>/dev/null || true
printf '%s\t%s\n' "$LAN_IP" "redoubt.lan" >> /etc/hosts 2>/dev/null || true

# the two faces of the box, defined once and used everywhere: the stack
# compose and the management config need them early (before the reveal
# section re-derives the remote one for cloud), and 'set -u' turns a
# late definition into an aborted heredoc with an empty compose
LAN_HOST="redoubt.lan"
REMOTE_HOST="redoubt.remote"

# 4c) Mesh identity, stable per machine. The same id survives a reinstall:
#     it is derived from /etc/machine-id (the Linux twin of the Windows
#     MachineGuid). The tunnel token and STUN port come from a redeemed
#     license when present; legacy values cover free installs.
MESH_ID_FILE=/etc/redoubt/mesh-id.txt
if [ -f "$MESH_ID_FILE" ] && [ "$(wc -c < "$MESH_ID_FILE")" -eq 9 ]; then
  MESH_ID=$(cat "$MESH_ID_FILE")
else
  MESH_ID=""
  if [ -r /etc/machine-id ]; then
    H=$(printf '%s' "redoubt-mesh:$(cat /etc/machine-id)" | sha256sum | cut -d' ' -f1)
    CHARS="abcdefghjkmnpqrstuvwxyz23456789"
    for i in 0 2 4 6 8 10 12 14; do
      B=${H:$i:2}
      V=$((16#$B % 32))
      MESH_ID="$MESH_ID${CHARS:$V:1}"
    done
  fi
  [ -z "$MESH_ID" ] && MESH_ID=$(tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' < /dev/urandom | head -c 8)
  printf '%s\n' "$MESH_ID" > "$MESH_ID_FILE"
  chmod 600 "$MESH_ID_FILE"
fi
STUN_PORT=40002
dbg "mesh id: $MESH_ID"

# Mesh mode, chosen up front: cloud (NetBird's servers broker the
# handshake; the phone works from any network with the user's own setup
# key) or selfhost (the kit runs the coordinator here, LAN-first). The
# paid tunnel is exe-only; the Linux kit never dials the meet point.
MESH_MODE="${MESH_MODE:-selfhost}"
# redoubt mesh-local passes REDOUBT_MESH_MODE: honor it over any
# saved value
if [ -n "${REDOUBT_MESH_MODE:-}" ]; then
  MESH_MODE="$REDOUBT_MESH_MODE"
fi
# both retired: a legacy install keeps running as cloud -
# the coordinator was already off in both since the setup-key flow,
# so nothing changes under it
[ "$MESH_MODE" = "both" ] && MESH_MODE="cloud"
if [ -n "${NETBIRD_SETUP_KEY:-}" ]; then
  MESH_MODE="cloud"
fi
# fd 3 is the real terminal, captured before the TUI routing: fds 0-2
# are the curl pipe and the log at this point, so only fd 3 can tell
# whether a human is watching
# Whatever the owner pasted (a key, a one-click link, or a PAT), resolve
# it to a plain setup key. A PAT mints the key through the account api;
# the kit also keeps the PAT itself (root-only, in /etc/redoubt) to
# publish the redoubt.remote zone in the owner account. A plain setup
# key cannot create zones: those machines keep the mesh address in
# their texts.
resolve_netbird_key() {
  local IN="$1" OUT=""
  IN="$(printf '%s' "$IN" | sed 's|.*setup-key/||' | tr -cd 'A-Za-z0-9_-')"
  case "$IN" in
    nbp_*)
      # the PAT is the key to the cloud split-DNS: keep it for the
      # zone publication after the join (a setup key cannot do it)
      mkdir -p /etc/redoubt
      printf '%s\n' "$IN" > /etc/redoubt/cloud-pat.txt
      chmod 600 /etc/redoubt/cloud-pat.txt
      KEY_TYPE="one-off"
      KEY_EXPIRES=86400
      if [ -t 3 ]; then
        printf 'Key type: one-off (safe, for one device) or reusable (unlimited)? [o/R]: ' >&3
        stty echo icanon <&3 2>/dev/null || true
        cursor_show
        read -r KEY_CHOICE <&3 2>/dev/null || true
        cursor_hide
        case "$KEY_CHOICE" in
          [Rr]*) KEY_TYPE="reusable"; KEY_EXPIRES=315360000 ;;
        esac
      fi
      OUT="$(curl -s --max-time 20 -X POST "https://api.netbird.io/api/setup-keys" \
        -H "Authorization: Token $IN" -H "Content-Type: application/json" \
        -d "{\"name\":\"redoubt-kit\",\"type\":\"$KEY_TYPE\",\"expires_in\":$KEY_EXPIRES}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null)"
      ;;
    *)
      # the real shape is a uuid: 32 hex chars printed in 8-4-4-4-12
      # groups. strip every separator the user typed and rebuild the
      # canonical form, so a handwritten key (inverted caps, missing or
      # extra dashes) still lands right. anything that is not 32 hex
      # chars stays empty and the caller asks again.
      # a stuck shift turns the digits into their symbols: map them
      # back before the hex filter, so a key typed under an inverted
      # caps/shift state still lands
      OUT="$(printf '%s' "$IN" | tr '!@#$%^&*()' '0123456789' | tr -cd '0-9A-Fa-f' | tr 'a-z' 'A-Z')"
      case "${#OUT}" in
        32) OUT="$(printf '%s-%s-%s-%s-%s' "${OUT:0:8}" "${OUT:8:4}" "${OUT:12:4}" "${OUT:16:4}" "${OUT:20:12}")" ;;
        *) OUT="" ;;
      esac
      ;;
  esac
  printf '%s' "$OUT"
}

# the paste of a key can land half-eaten on a bare console (vnc
# clipboards, timing): ask again with a clear nudge instead of silently
# falling back to self-hosted
show_cloud_link_qr() {
  local QR_URL="https://app.netbird.io/team/service-users" QRP
  # The browser lands straight on the Service Users page: the token
  # flow is the automatic path (one paste provisions the key, the
  # enrollment and the mesh nameserver). The QR exists only to carry
  # this console link to a phone for the same page - never for a
  # device sign-in. A desktop gets the owner browser; a bare console
  # gets the scan.
  if [ "${HAS_GUI:-0}" = "1" ] && [ -n "${SUDO_USER:-}" ]; then
    _UIDN=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f3)
    _GD="${DISPLAY:-}"
    _WD="${WAYLAND_DISPLAY:-}"
    for _W in "/run/user/$_UIDN"/wayland-*; do
      [ -S "$_W" ] || continue
      _WD="wayland-${_W##*-}"
      break
    done
    for _GS in /tmp/.X11-unix/X*; do
      [ -S "$_GS" ] || continue
      [ "$(stat -c %U "$_GS" 2>/dev/null || true)" = "$SUDO_USER" ] || continue
      _GD=":${_GS#/tmp/.X11-unix/X}"
      break
    done
    [ -n "$_GD" ] || _GD=":0"
    [ -n "$_WD" ] || _WD="wayland-0"
    echo "The browser opens your Service Users page: create one (admin) and copy its token (link: $QR_URL)" >&3 2>/dev/null || true
    # The real binaries fire first: xdg-open hands the url to a wrapper
    # chain that some desktops ship broken and silent (Parrot's
    # firefox-selector chain died exactly like that, and the kit sat
    # waiting on nothing). A direct launch opens the browser right away
    # on every desktop; xdg-open stays as the fallback for boxes that
    # ship a browser none of the known names cover.
    _FFHOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    for _BROWSE_BIN in firefox-esr firefox chromium chromium-browser brave-browser google-chrome; do
      command -v "$_BROWSE_BIN" >/dev/null 2>&1 || continue
      sudo -u "$SUDO_USER" env DISPLAY="$_GD" \
        WAYLAND_DISPLAY="$_WD" \
        XDG_RUNTIME_DIR="/run/user/$_UIDN" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$_UIDN/bus" \
        XAUTHORITY="${_XACOOKIE:-}" \
        nohup "$_BROWSE_BIN" "$QR_URL" >/dev/null 2>&1 &
      # Detection, not a timer: the browser announces itself two ways
      # (its process comes alive, and a first run creates the profile
      # file). The sensor reads those markers every beat and breaks the
      # instant one fires; the cap only stops a hung launch, it never
      # waits the full span on a healthy one.
      _BROWSE_BEAT=0
      _BROWSE_UP=0
      while [ "$_BROWSE_BEAT" -lt 16 ]; do
        sleep 0.25
        _BROWSE_BEAT=$((_BROWSE_BEAT+1))
        if pgrep -u "$SUDO_USER" -f '[f]irefox|[f]irefox-esr|[c]hromium|[c]hrome|[b]rave' >/dev/null 2>&1 \
           || [ -s "$_FFHOME/.mozilla/firefox/profiles.ini" ]; then
          _BROWSE_UP=1
          break
        fi
      done
      if [ "$_BROWSE_UP" = "1" ]; then
        dbg "OK: browser is up ($_BROWSE_BIN, detected in ~$((_BROWSE_BEAT)) beats)"
      else
        dbg "WARN: no $_BROWSE_BIN process detected after the launch"
      fi
      return 0
    done
    dbg "no known browser binary; trying xdg-open as the fallback"
    sudo -u "$SUDO_USER" env DISPLAY="$_GD" \
      WAYLAND_DISPLAY="$_WD" \
      XDG_RUNTIME_DIR="/run/user/$_UIDN" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$_UIDN/bus" \
      XAUTHORITY="${_XACOOKIE:-}" \
      nohup xdg-open "$QR_URL" >/dev/null 2>&1 &
    return 0
  fi
  if [ "$TERM" = "linux" ] && [ -e /dev/fb0 ] \
     && command -v qrencode >/dev/null 2>&1 && command -v fbi >/dev/null 2>&1 \
     && command -v openvt >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; then
    echo "scan the code to open your NetBird Service Users on the phone" >&3
    echo "log in, create a service user (admin), copy its token and paste it below" >&3
    QRP=/tmp/redoubt-setupkeys.png
    if qrencode -o "$QRP" -s 8 -m 4 --foreground=34D399 --background=D4D4D8 "$QR_URL" 2>/dev/null; then
      openvt -s -- fbi -a --noverbose "$QRP" >/dev/null 2>&1 || true
      sleep 30
      pkill -x fbi 2>/dev/null || true
      chvt 1 2>/dev/null || true
      rm -f "$QRP"
      return 0
    fi
  fi
  # the framebuffer QR carries the confirmation code in a strip under
  # the matrix, so one screen holds everything the phone asks for: code
  # printed above would scroll away or hide behind the painter anyway
  if [ "$TERM" = "linux" ] && [ -t 3 ]; then
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSI256 -s 2 -m 1 "$QR_URL" >&3 2>/dev/null || true
    fi
    echo "or open this on the phone: $QR_URL" >&3
    return 0
  fi
  echo "open this on your phone or another machine: $QR_URL" >&3
  echo "sign in there, create a key, then paste it below" >&3
}

join_cloud_with_key() {
  # a rejected key is not the end of the world: ask for the real one
  # again right here and retry the join, up to two rounds, before the
  # honest fallback
  local _KT=0 _DT=0 _i
  # a stale identity would swallow the new credential: clear it first
  nb_reset_stale_identity
  while [ "$_KT" -lt 2 ]; do
    _KT=$((_KT+1))
    # the daemon must answer before the up: right after the
    # state cleanup it is still waking and the up dies with a
    # reset connection that is NOT a key rejection
    for _i in $(seq 1 30); do
      "$NBEXE" status >/dev/null 2>&1 && break
      sleep 1
    done
    _DT=0
    while [ "$_DT" -lt 3 ]; do
      printf '%s' "$NETBIRD_SETUP_KEY" > "$STACKDIR/.join-key.tmp"
      chmod 600 "$STACKDIR/.join-key.tmp"
      NBUPE=$(timeout -k 5 120 "$NBEXE" up --management-url "https://api.netbird.io" --disable-dns --setup-key-file "$STACKDIR/.join-key.tmp" 2>&1 || true)
      echo "cloud join attempt: $(printf '%s' "$NBUPE" | tr '\n' ' ' | head -c 200)" >> "$LOG"
      rm -f "$STACKDIR/.join-key.tmp"
      case "$NBUPE" in
        *"unable to get daemon status"*|*"reset connection"*|*"default.json"*|*"config file"*)
          _DT=$((_DT+1))
          for _i in $(seq 1 30); do
            "$NBEXE" status >/dev/null 2>&1 && break
            sleep 1
          done
          continue
          ;;
      esac
      break
    done
    case "$NBUPE" in
      *"unable to get daemon status"*|*"reset connection"*|*"default.json"*|*"config file"*)
        # the daemon was still down or mid-restart: kick it and retry
        # the whole round. This is never a key rejection (the
        # rpc error string matched the broad "error" pattern and the
        # customer saw a wrong rejection with a perfectly good key).
        systemctl restart netbird >/dev/null 2>&1 || true
        for _i in $(seq 1 30); do
          "$NBEXE" status >/dev/null 2>&1 && break
          sleep 1
        done
        [ "$_KT" -lt 2 ] && continue
        JOIN_WAIT=0
        ;;
      *"invalid"*|*"unauthorized"*|*"expired"*|*"revoked"*|*"not found"*|*"already used"*)
        echo "key rejected - wrong, from another account, or already used" >&3
        if [ "$_KT" -lt 2 ]; then
          read_setup_key
          [ -n "${NETBIRD_SETUP_KEY:-}" ] && continue
        fi
        JOIN_WAIT=0
        ;;
      *)
        JOIN_WAIT=1
        break
        ;;
    esac
  done
  if [ "$JOIN_WAIT" = "1" ]; then
    arm_mesh_nameserver
  fi
}

# anything queued on the tty (blind typing, half-eaten pastes) must
# never feed the next prompt: swallow the queue so one answer lands
# on exactly one question
drain_tty() {
  while read -r -t 0 _ <&3 2>/dev/null; do :; done
}
read_setup_key() {
  local _K="" _T=0
  while [ "$_T" -lt 2 ]; do
    _T=$((_T+1))
    printf 'Type your NetBird Setup Key (or its link): ' >&3
    # two minutes is plenty to paste a key; without the timeout a box
    # with nobody at the keyboard stalls the whole install right here
    stty echo icanon <&3 2>/dev/null || true
    cursor_show
    read -r -t 120 _K <&3 2>/dev/null || true
    cursor_hide
    drain_tty
    echo "setup key input: attempt $_T, got ${#_K} chars, bytes: $(printf '%s' "$_K" | od -An -tx1 | tr -d ' \n')" >> "$LOG"
    _K="$(resolve_netbird_key "$_K")"
    [ -n "$_K" ] && { NETBIRD_SETUP_KEY="$_K"; return 0; }
    echo "that did not look like a key - one more try" >&3
  done
  NETBIRD_SETUP_KEY=""
}

# Token path: the customer pastes ONE api token (service user, admin)
# and the kit provisions the whole cloud: it mints a one-off setup key
# via the management API for the enrollment and, once the machine is
# linked, arms the nameserver pointing at the pi-hole's mesh address.
# The token lives in a 600 file for the span of the pass and is
# destroyed the moment the nameserver is confirmed: nothing is left on
# the box for a later compromise to harvest, and the flow never runs
# again because the next pass sees the live link and skips it.
nb_token_flow() {
  _NB_TOKFILE="$STACKDIR/.nb-token.tmp"
  printf '%s' "Authorization: Token $1" > "$_NB_TOKFILE"
  chmod 600 "$_NB_TOKFILE"
  _NB_API="https://api.netbird.io"
  # proof of life: the token must be able to list setup keys. Log the
  # real answer (code + short body) so a rejection is diagnosable from
  # the kit log instead of a guess. The code alone is the verdict: an
  # empty key list is a perfectly valid answer ("[]") and must not
  # read as a rejection (the quote check did exactly that).
  _NB_PROBE=$(curl -s --max-time 20 --retry 2 -o /tmp/redoubt-probe.json -w '%{http_code}' -H "@$_NB_TOKFILE" "$_NB_API/api/setup-keys" 2>/dev/null || true)
  _NB_PROBE_BODY=$(head -c 300 /tmp/redoubt-probe.json 2>/dev/null | tr '\n' ' ')
  rm -f /tmp/redoubt-probe.json
  echo "token probe: http ${_NB_PROBE:-none}, body: $(printf '%s' "$_NB_PROBE_BODY" | head -c 200)" >> "$LOG"
  if [ "$_NB_PROBE" != "200" ]; then
    rm -f "$_NB_TOKFILE"
    echo "token rejected (the role must be ADMIN) - paste a valid one" >&3 2>/dev/null || true
    return 1
  fi
  _NB_NAME="redoubt $(hostname 2>/dev/null | cut -c1-32)"
  _NB_BODY=$(printf '{"name":"%s","type":"one-off","expires_in":31536000,"auto_groups":[],"usage_limit":1,"ephemeral":false,"allow_extra_dns_labels":false}' "$_NB_NAME")
  _NB_RESP=$(curl -s --max-time 30 --retry 2 -X POST -o /tmp/redoubt-key.json -w '%{http_code}' -H "@$_NB_TOKFILE" -H 'Content-Type: application/json' --data-raw "$_NB_BODY" "$_NB_API/api/setup-keys" 2>/dev/null || true)
  _NB_KEY=$(sed -n 's/.*"key":"\([^"]*\)".*/\1/p' /tmp/redoubt-key.json 2>/dev/null)
  # the minted key is a live enrollment credential until it is spent:
  # mask it in the log body copy, it must never sit in plain text
  _NB_ERR=$(head -c 300 /tmp/redoubt-key.json 2>/dev/null | sed 's/"key":"[^"]*"/"key":"***"/' | tr '\n' ' ')
  rm -f /tmp/redoubt-key.json
  echo "token mint: http ${_NB_RESP:-none}, body: $(printf '%s' "$_NB_ERR" | head -c 200)" >> "$LOG"
  if [ -z "$_NB_KEY" ]; then
    rm -f "$_NB_TOKFILE"
    echo "rejected: the service user must be ADMIN (user is read-only) - paste again" >&3 2>/dev/null || true
    return 1
  fi
  NETBIRD_SETUP_KEY="$_NB_KEY"
  echo "key minted for this machine - the token dies once the shield is armed" >&3 2>/dev/null || true
  return 0
}

# A stale identity means the local agent still holds a config file but
# the peer is gone from the account (deleted in the dashboard): the
# agent will never connect again on its own and a fresh join with a new
# key gets silently ignored while the old config lives. Clear it before
# any enrollment attempt so the new credential actually lands.
nb_reset_stale_identity() {
  if nb_cloud_linked && ! nb_cloud_live; then
    for _NB in $(command -v netbird 2>/dev/null) /usr/local/bin/netbird /usr/bin/netbird /usr/sbin/netbird; do
      [ -x "$_NB" ] || continue
      "$_NB" down >/dev/null 2>&1 || true
      break
    done
    # NetBird 0.79+ keeps the identity PER PROFILE (/var/lib/netbird/
    # <profile>/config.json), not at the top level: a partial rm leaves
    # the old enrollment alive and the new key gets ignored. Clear the
    # whole state dir (the daemon recreates it on the next up) plus the
    # older layout path.
    rm -rf /var/lib/netbird/* /etc/netbird/config.json 2>/dev/null || true
    # the down above leaves the daemon parked: restart it so the join
    # right after this never fights a dead daemon (the join reads that
    # as a key rejection otherwise; seen on Rocky)
    systemctl restart netbird >/dev/null 2>&1 || true
    echo "mesh: stale cloud identity cleared - enrolling fresh" >> "$LOG"
  fi
}

# After a successful cloud join, arm the mesh nameserver: the pi-hole's
# mesh address becomes the primary resolver of the whole account, so
# every peer (the phone included) blocks ads on the go through the
# encrypted mesh with nothing exposed to the internet. Runs once: the
# token file only exists on the pass that minted it, and the nameserver
# check is idempotent for any later pass that still finds the file.
arm_mesh_nameserver() {
  [ -f "$STACKDIR/.nb-token.tmp" ] || return 0
  _NB_TOKFILE="$STACKDIR/.nb-token.tmp"
  _NB_API="https://api.netbird.io"
  # the mesh address arrives a beat after the join: wait for it
  _NB_MESH_IP=""
  for _i in $(seq 1 15); do
    for _NB in $(command -v netbird 2>/dev/null) /usr/local/bin/netbird /usr/bin/netbird /usr/sbin/netbird; do
      [ -x "$_NB" ] || continue
      _NB_MESH_IP="$("$_NB" status 2>/dev/null | sed -n 's/^NetBird IP: //p' | head -1)"
      break
    done
    [ -n "$_NB_MESH_IP" ] && break
    sleep 1
  done
  if [ -z "$_NB_MESH_IP" ]; then
    dbg "no mesh address yet - nameserver skipped (next pass arms it)"
    return 0
  fi
  # the status line carries the CIDR prefix (100.125.57.157/16): the
  # nameserver API wants the bare address and rejects the prefix as
  # "invalid ns servers format" (seen twice on Rocky)
  _NB_MESH_IP="${_NB_MESH_IP%%/*}"
  # idempotent: a nameserver on the same address is already armed
  _NB_EXIST=$(curl -fsS --max-time 20 -H "@$_NB_TOKFILE" "$_NB_API/api/dns/nameservers" 2>/dev/null | grep -c "\"ip\":\"$_NB_MESH_IP\"") || true
  if [ -n "$_NB_EXIST" ] && [ "$_NB_EXIST" -gt 0 ]; then
    rm -f "$_NB_TOKFILE" /etc/redoubt/mesh-ns-pending
    return 0
  fi
  # a nameserver group must target at least one peer group: take the
  # account's built-in "All" group (every account ships one) so the
  # shield covers every peer, phones included (groups:[] died
  # with a 422 because a shield nobody receives is invalid)
  _NB_GROUP_ID=$(curl -fsS --max-time 20 -H "@$_NB_TOKFILE" "$_NB_API/api/groups" 2>/dev/null \
    | python3 -c 'import json,sys
try:
  gs=json.load(sys.stdin)
  for g in gs:
    if g.get("name","").lower()=="all":
      print(g.get("id","")); break
except Exception:
  pass' 2>/dev/null)
  if [ -z "$_NB_GROUP_ID" ]; then
    dbg "nameserver arm skipped - the account has no peer group to target"
    rm -f "$_NB_TOKFILE"
    touch /etc/redoubt/mesh-ns-pending 2>/dev/null || true
    return 0
  fi
  # The wire shape is the NameServerGroup: a list of nameserver items
  # (ip/ns_type/port), primary=true with empty domains = catch-all
  # resolver for the whole account (the flat "ip" body died
  # with a 422 on the current API).
  _NB_NS_BODY=$(printf '{"name":"Redoubt Shield","description":"pi-hole on the mesh - ad blocking anywhere","nameservers":[{"ip":"%s","ns_type":"udp","port":53}],"enabled":true,"groups":["%s"],"primary":true,"domains":[],"search_domains_enabled":false}' "$_NB_MESH_IP" "$_NB_GROUP_ID")
  _NB_NS_CODE=$(curl -s --max-time 30 --retry 2 -X POST -o /tmp/redoubt-ns.json -w '%{http_code}' -H "@$_NB_TOKFILE" -H 'Content-Type: application/json' --data-raw "$_NB_NS_BODY" "$_NB_API/api/dns/nameservers" 2>/dev/null || true)
  _NB_NS_OK=0
  if [ "$_NB_NS_CODE" = "200" ]; then
    _NB_NS_OK=1
  else
    _NB_NS_ERR=$(head -c 400 /tmp/redoubt-ns.json 2>/dev/null | tr '\n' ' ')
    # a reinstall enrolls with a fresh mesh address while the account
    # still holds a shield with the same name (the API's uniqueness
    # check is case-insensitive): update the existing group's
    # nameserver instead of failing, or the phone keeps a dead address
    # (seen on Rocky: 422 already exist twice, old IP in the wire)
    if printf '%s' "$_NB_NS_ERR" | grep -qi "already exist"; then
      _NB_NS_ID=$(curl -fsS --max-time 20 -H "@$_NB_TOKFILE" "$_NB_API/api/dns/nameservers" 2>/dev/null \
        | python3 -c 'import json,sys
try:
  gs=json.load(sys.stdin)
  for g in gs:
    if g.get("name","").lower()=="redoubt shield":
      print(g.get("id","")); break
except Exception:
  pass' | head -1)
      if [ -n "$_NB_NS_ID" ]; then
        _NB_NS_CODE=$(curl -s --max-time 30 --retry 2 -X PUT -o /tmp/redoubt-ns.json -w '%{http_code}' -H "@$_NB_TOKFILE" -H 'Content-Type: application/json' --data-raw "$_NB_NS_BODY" "$_NB_API/api/dns/nameservers/$_NB_NS_ID" 2>/dev/null || true)
        [ "$_NB_NS_CODE" = "200" ] && _NB_NS_OK=1
        _NB_NS_ERR=$(head -c 400 /tmp/redoubt-ns.json 2>/dev/null | tr '\n' ' ')
      fi
    fi
  fi
  if [ "$_NB_NS_OK" = "1" ]; then
    # same family as the rest of the pass: emerald, no glyph, and no
    # raw mesh address on the pretty line (the log keeps the IP)
    printf '  %bmesh DNS shield armed: Home & Remote%b\n' "$EM2" "$RESET" >&3 2>/dev/null || true
    dbg "OK: mesh nameserver armed on $_NB_MESH_IP"
    rm -f /etc/redoubt/mesh-ns-pending
    # the private resolver serves cdn.jsdelivr.net for the CDN mirror:
    # after the join the record must carry the mesh address (the phone
    # cannot reach the LAN address over the mesh), then the resolver
    # restarts with the new record.
    if [ -f "$STACKDIR/unbound.conf" ]; then
      sed -i "s/cdn\.jsdelivr\.net\. 300 IN A [^\"]*/cdn.jsdelivr.net. 300 IN A $_NB_MESH_IP/" "$STACKDIR/unbound.conf"
      docker compose -f "$STACKDIR/docker-compose.yml" restart dns >/dev/null 2>&1 || true
      dbg "OK: private resolver record pointed at the mesh address"
    fi
  else
    # log the exact wire answer: the body carries the real reason and
    # a code alone would keep this a guessing game (seen twice)
    dbg "nameserver arm failed (code ${_NB_NS_CODE:-none}; sent: $(printf '%s' "$_NB_NS_BODY" | head -c 220); answer: $(printf '%s' "$_NB_NS_ERR" | head -c 300))"
    touch /etc/redoubt/mesh-ns-pending 2>/dev/null || true
  fi
  rm -f /tmp/redoubt-ns.json
  # the token's job is done either way: nothing stays on the box
  rm -f "$_NB_TOKFILE"
  return 0
}

mint_edge_cert() {
  # One static cert with every address in its SANs: browsers send no
  # SNI for IP literals, so caddy would otherwise serve the first
  # address cert to every request and the tiles get a cert that names
  # the wrong IP.
  EDGE_SANS="IP:$LAN_IP,IP:$NETBIRD_IP,IP:127.0.0.1,DNS:redoubt.lan,DNS:redoubt.remote,DNS:cdn.jsdelivr.net"
  if [ -f /var/lib/redoubt/caddy-local/caddy/pki/authorities/local/intermediate.key ]; then
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout /var/lib/redoubt/caddy-local/edge-key.pem \
      -out /var/lib/redoubt/caddy-local/edge.csr \
      -subj "/CN=Redoubt Edge" \
      -addext "subjectAltName=$EDGE_SANS" >/dev/null 2>&1
    openssl x509 -req -in /var/lib/redoubt/caddy-local/edge.csr \
      -CA /var/lib/redoubt/caddy-local/caddy/pki/authorities/local/intermediate.crt \
      -CAkey /var/lib/redoubt/caddy-local/caddy/pki/authorities/local/intermediate.key \
      -CAcreateserial -days 397 \
      -extfile <(printf "subjectAltName=%s" "$EDGE_SANS") \
      -out /var/lib/redoubt/caddy-local/edge-cert.pem >/dev/null 2>&1 \
    && cat /var/lib/redoubt/caddy-local/edge-cert.pem \
         /var/lib/redoubt/caddy-local/caddy/pki/authorities/local/intermediate.crt \
         > /var/lib/redoubt/caddy-local/edge-chain.pem \
    && sed -i 's|tls internal|tls /data/edge-chain.pem /data/edge-key.pem|g' \
         "$STACKDIR/local-caddy.Caddyfile" \
    && EDGE_BOUNCE=1
    rm -f /var/lib/redoubt/caddy-local/edge.csr
  fi
}
publish_remote_zone() {
  # $1 = api base url, $2 = auth header, $3 = label for the logs. One
  # zone, one A record, both get-or-create: a re-run refreshes the
  # mesh address instead of stacking duplicates.
  _ZONE_API=$1; _ZONE_AUTH=$2; _ZONE_LABEL=$3
  _ZONE_GROUP=$(curl -s --max-time 20 "$_ZONE_API/api/groups" -H "$_ZONE_AUTH" \
    | python3 -c "import sys,json; print(next((g.get('id','') for g in json.load(sys.stdin) if g.get('name')=='All'), ''))" 2>/dev/null)
  if [ -z "$_ZONE_GROUP" ]; then
    return 0
  fi
  _ZONE_ID=$(curl -s --max-time 20 "$_ZONE_API/api/dns/zones" -H "$_ZONE_AUTH" \
    | python3 -c "import sys,json; print(next((z.get('id','') for z in json.load(sys.stdin) if z.get('domain')=='redoubt.remote'), ''))" 2>/dev/null)
  if [ -z "$_ZONE_ID" ]; then
    _ZONE_ID=$(curl -s --max-time 20 -X POST "$_ZONE_API/api/dns/zones" \
      -H "$_ZONE_AUTH" -H "Content-Type: application/json" \
      -d "{\"name\":\"Redoubt mesh\",\"domain\":\"redoubt.remote\",\"enabled\":true,\"enable_search_domain\":false,\"distribution_groups\":[\"$_ZONE_GROUP\"]}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  fi
  if [ -z "$_ZONE_ID" ]; then
    dbg "WARN: the $_ZONE_LABEL zone did not publish (check the token), remote links keep the mesh address"
    return 0
  fi
  _ZONE_REC=$(curl -s --max-time 20 "$_ZONE_API/api/dns/zones/$_ZONE_ID" -H "$_ZONE_AUTH" \
    | python3 -c "import sys,json; print(next((r.get('id','') for r in json.load(sys.stdin).get('records',[]) if r.get('name')=='redoubt.remote'), ''))" 2>/dev/null)
  if [ -n "$_ZONE_REC" ]; then
    curl -s --max-time 20 -X PUT "$_ZONE_API/api/dns/zones/$_ZONE_ID/records/$_ZONE_REC" \
      -H "$_ZONE_AUTH" -H "Content-Type: application/json" \
      -d "{\"name\":\"redoubt.remote\",\"type\":\"A\",\"content\":\"$NETBIRD_IP\",\"ttl\":300}" >/dev/null 2>&1 || true
  else
    curl -s --max-time 20 -X POST "$_ZONE_API/api/dns/zones/$_ZONE_ID/records" \
      -H "$_ZONE_AUTH" -H "Content-Type: application/json" \
      -d "{\"name\":\"redoubt.remote\",\"type\":\"A\",\"content\":\"$NETBIRD_IP\",\"ttl\":300}" >/dev/null 2>&1 || true
  fi
  sed -i '/[[:space:]]redoubt\\.remote[[:space:]]*$/d' /etc/hosts 2>/dev/null || true
  printf '%s\t%s\n' "$NETBIRD_IP" "redoubt.remote" >> /etc/hosts 2>/dev/null || true
  dbg "OK: $_ZONE_LABEL zone redoubt.remote points at $NETBIRD_IP"
}
nb_fetch() {
  # $1 = release asset, $2 = checksums file, $3 = work dir. Downloads
  # both from the vendor release and verifies the asset against the
  # vendor checksum list before anything else touches it.
  _NB_ASSET=$1; _NB_CKSUM=$2; _NB_DIR=$3
  curl -fsSL -o "$_NB_DIR/$_NB_ASSET" "https://github.com/netbirdio/netbird/releases/download/v${NBVER}/${_NB_ASSET}" \
    && curl -fsSL -o "$_NB_DIR/nb-checksums.txt" "https://github.com/netbirdio/netbird/releases/download/v${NBVER}/${_NB_CKSUM}" \
    && grep "$_NB_ASSET" "$_NB_DIR/nb-checksums.txt" > "$_NB_DIR/${_NB_ASSET}.sha256" \
    && (cd "$_NB_DIR" && sha256sum -c "${_NB_ASSET}.sha256" >/dev/null 2>&1)
}
nb_fetch_latest() {
  # $1 = asset, $2 = checksums file, $3 = work dir. Same discipline
  # as nb_fetch but against the NBLATEST release with dynamic asset
  # names: the downloaded hash is grepped straight out of the vendor
  # checksum list.
  _NB_ASSET=$1; _NB_CKSUM=$2; _NB_DIR=$3
  curl -fsSL -o "$_NB_DIR/$_NB_ASSET" "https://github.com/netbirdio/netbird/releases/download/v${NBLATEST}/$_NB_ASSET" \
    && curl -fsSL -o "$_NB_DIR/nb-checksums.txt" "https://github.com/netbirdio/netbird/releases/download/v${NBLATEST}/$_NB_CKSUM" \
    && grep -q "$(sha256sum "$_NB_DIR/$_NB_ASSET" | cut -d' ' -f1)" "$_NB_DIR/nb-checksums.txt"
}
read_cloud_key() {
  # one pasted credential on the TUI. Console clipboards wrap and pad
  # pastes, so every whitespace is stripped before the shape is
  # judged; the log keeps chars + head only, never the secret.
  _RKEY_PROMPT=${1:-'Type your NetBird Setup Key (or API token): '}
  printf '%s' "$_RKEY_PROMPT" >&3
  stty -echo <&3 2>/dev/null || true
  cursor_show
  read -r _K <&3 2>/dev/null || true
  cursor_hide
  stty echo <&3 2>/dev/null || true
  printf '\n' >&3 2>/dev/null || true
  drain_tty
  _K=$(printf '%s' "$_K" | tr -d '[:space:]')
  echo "cloud credential input: ${#_K} chars, head: $(printf '%s' "$_K" | cut -c1-12)" >> "$LOG"
}
cloud_key_flow() {
  # the primary cloud link is a setup key: NetBird expires SSO logins
  # after 24 hours by default, a key carries no session expiry and the
  # machine stays linked across reboots with nothing to re-approve.
  # The cloud waits for the key with no timeout and no LAN fallback:
  # a cloud machine stays in cloud until its key lands.
  if command -v netbird >/dev/null 2>&1 && nb_cloud_linked; then
    echo "mesh: cloud session already linked, keeping it" >> "$LOG"
    # Say it on screen too: the identity survives kit wipes (it lives in
    # /var/lib/netbird, outside the stack), so a wiped machine reuses its
    # first enrollment and a freshly pasted key stays unused in the
    # dashboard. Silence here read as "the peer never enrolled".
    # NBEXE is defined later in the file: resolve the binary right here,
    # across the paths the installer has used over the releases.
    _NB_FQDN=""
    for _NB in $(command -v netbird 2>/dev/null) /usr/local/bin/netbird /usr/bin/netbird /usr/sbin/netbird; do
      [ -x "$_NB" ] || continue
      _NB_FQDN="$("$_NB" status 2>/dev/null | sed -n 's/^FQDN: //p')"
      [ -n "$_NB_FQDN" ] && break
    done
    if nb_cloud_live; then
      if [ -f /etc/redoubt/mesh-ns-pending ]; then
        echo "Cloud link live, but the nameserver did not arm in the previous run" >&3 2>/dev/null || true
        echo "paste a fresh token below to arm it now (it dies right after)" >&3 2>/dev/null || true
      else
        [ -n "$_NB_FQDN" ] && echo "this machine is already enrolled as $_NB_FQDN - no key needed" >&3 2>/dev/null || true
        return 0
      fi
    fi
    # the identity file survives but the peer is gone from the account
    # (deleted in the dashboard): the agent will never connect on its
    # own, so fall through and ask for a fresh credential. The join
    # block clears the stale identity before enrolling again.
    echo "cloud link went stale - link it again below" >&3 2>/dev/null || true
  fi
  echo "the browser opens at Service Users: create one (admin), copy its 1-day token" >&3 2>/dev/null || true
  echo "and paste it below - the kit destroys it right after use" >&3 2>/dev/null || true
  echo "(no token? paste a reusable setup key instead)" >&3 2>/dev/null || true
  # the console opens AFTER the message: the prompt stays on screen
  # and the browser (or QR) is the key factory right next to it
  show_cloud_link_qr
  while :; do
    read_cloud_key
    case "$_K" in
      *nbp_*)
        if nb_token_flow "$_K"; then
          return 0
        fi
        ;;
      *)
        _K="$(resolve_netbird_key "$_K")"
        if [ -n "$_K" ]; then
          NETBIRD_SETUP_KEY="$_K"
          return 0
        fi
        echo "not a key - paste it again (the cloud waits)" >&3 2>/dev/null || true
        ;;
    esac
  done
}
if [ -z "${NETBIRD_SETUP_KEY:-}" ] && [ -z "${REDOUBT_MESH_MODE:-}" ] && [ -t 3 ]; then
  # the bar painter repaints ~30 times a second: stop it while the
  # question is on screen, or its carriage-return redraws shred the text
  if [ -n "${ANIM_PID:-}" ]; then
    kill -9 "$ANIM_PID" 2>/dev/null || true
  fi
  printf '\r\033[K' >&3
  if [ "${RERUN:-0}" = "1" ]; then
    # a decision already lives on this machine: a single yes/no, never
    # the whole menu again. Except the broken-cloud case: the machine
    # is set to cloud but the agent never linked, so the key block
    # below owns the flow and this question would only delay it.
    if [ "$MESH_MODE" = "cloud" ] && ! nb_cloud_live; then
      SHOW_MENU=0
    else
      # a yes/no gate must be strict: junk must never fall through to
      # a default and keep the pass running (typing 'clear' means the
      # customer wants out, not 'no'). Valid answers decide, cancel
      # words stop the run, everything else asks again.
      while :; do
        printf 'Your mesh is already set to %s. Change it? (y/N): ' "$MESH_MODE" >&3
        stty echo icanon <&3 2>/dev/null || true
        cursor_show
        read -r CHANGE <&3 2>/dev/null || true
        cursor_hide
        drain_tty
        case "$CHANGE" in
          "") SHOW_MENU=0; break ;;
          [yY]|[yY][eE][sS]|[sS]|[sS][iI]) SHOW_MENU=1; break ;;
          [nN]|[nN][oO]) SHOW_MENU=0; break ;;
          [cC]lear|[cC]ancel|[eE]xit|[qQ]uit|[aA]bort|[sS]top|[sS]alir)
            printf 'Run cancelled - nothing was changed.\n' >&3
            exit 0
            ;;
          *) printf 'Answer y or n, or type cancel to stop: ' >&3 ;;
        esac
      done
    fi
  else
    SHOW_MENU=1
  fi
  if [ "$SHOW_MENU" = "1" ]; then
    echo "" >&3
    echo "Your mesh, your rules:" >&3
    echo "  1) NetBird cloud (recommended) - one admin token; the kit mints" >&3
    echo "     the key, arms the shield, destroys the token. Any device works" >&3
    echo "     from any network; at home the same links run over wifi." >&3
    echo "  2) Self-hosted - the coordinator runs here, zero third parties" >&3
    # same strict gate as the repatch question: junk asks again,
    # cancel words stop the run cleanly before anything else moves
    while :; do
      printf 'Choose 1 or 2 [1]: ' >&3
      stty echo icanon <&3 2>/dev/null || true
      cursor_show
      read -r MESH_CHOICE <&3 2>/dev/null || true
      cursor_hide
      drain_tty
      case "$MESH_CHOICE" in
        ""|1|2) break ;;
        [cC]lear|[cC]ancel|[eE]xit|[qQ]uit|[aA]bort|[sS]top|[sS]alir)
          printf 'Run cancelled - nothing was changed.\n' >&3
          exit 0
          ;;
        *) printf 'Choose 1 or 2, or type cancel to stop: ' >&3 ;;
      esac
    done
  # A desktop links the machine through the app's own sign-in, the exe
  # way: no key to paste, the account does the work. A terminal-only box
  # still takes the setup key.
  KIT_HAS_GUI=0
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] \
     || ls /usr/share/xsessions/*.desktop >/dev/null 2>&1 \
     || ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1; then
    KIT_HAS_GUI=1
  fi
  # the join and the final reveal read this too: a desktop machine
  # takes the app sign-in over the QR, so the answer must survive
  # this menu block on every mode
  [ "$KIT_HAS_GUI" = "1" ] && HAS_GUI=1
  case "${MESH_CHOICE:-1}" in
    2) MESH_MODE="selfhost" ;;
    *)
      cloud_key_flow
      MESH_MODE="cloud"
      ;;
  esac
  fi
  # the answer is in: bring the painter back on the current state
  if [ -t 3 ]; then
    bar_anim &
    ANIM_PID=$!
  fi
fi

# The painter must exist past the menu on every path: a repatch held
# it back until the question, and a run that skipped the menu (the
# mesh mode pinned by env) still needs it for the rest of the pass.
HOLD_BAR=0
if [ -t 3 ] && { [ -z "${ANIM_PID:-}" ] || ! kill -0 "$ANIM_PID" 2>/dev/null; }; then
  bar_anim &
  ANIM_PID=$!
fi

# Persist the choice. The auto-update re-runs the kit and has to land on
# the same mesh, never back on a default.
if grep -qs '^MESH_MODE=' /etc/redoubt/redoubt.env 2>/dev/null; then
  sed -i "s|^MESH_MODE=.*|MESH_MODE=$MESH_MODE|" /etc/redoubt/redoubt.env
else
  echo "MESH_MODE=$MESH_MODE" >> /etc/redoubt/redoubt.env
fi

# A cloud machine that never linked must not keep running unlinked: it
# waits right here for the key, no timeout, no fallback to the LAN
# addresses. The gate is the live agent state: a
# NeedsLogin agent means cloud failed and the key owns the flow. When
# the agent exists the join runs on the spot; otherwise the key is
# stored and the cloud section below installs the agent and joins.
if [ "$MESH_MODE" = "cloud" ] && [ -t 3 ] && [ -z "${NETBIRD_SETUP_KEY:-}" ] \
   && ! nb_cloud_live; then
  NBEXE=$(command -v netbird 2>/dev/null || echo /usr/local/bin/netbird)
  [ -n "${ANIM_PID:-}" ] && kill -9 "$ANIM_PID" 2>/dev/null || true
  printf '\r\033[K' >&3
  echo "Mesh set to cloud, but the link is not alive." >&3
  show_cloud_link_qr
  while :; do
    read_cloud_key
    case "$_K" in
      *nbp_*)
        if nb_token_flow "$_K"; then
          _K="$NETBIRD_SETUP_KEY"
        else
          continue
        fi
        ;;
      *)
        _K="$(resolve_netbird_key "$_K")"
        if [ -z "$_K" ]; then
          echo "that did not look like a key - paste it again (the cloud waits)" >&3
          continue
        fi
        ;;
    esac
    NETBIRD_SETUP_KEY="$_K"
    if [ ! -x "$NBEXE" ]; then
      echo "key stored - the mesh agent installs and joins below" >> "$LOG"
      break
    fi
    # the daemon must answer before the up: right after a restart it is
    # still waking and the up dies with a reset connection
    for _i in $(seq 1 30); do
      "$NBEXE" status >/dev/null 2>&1 && break
      sleep 1
    done
    # a stale identity would swallow the new credential: clear it first
    nb_reset_stale_identity
    printf '%s' "$NETBIRD_SETUP_KEY" > "$STACKDIR/.join-key.tmp"
    chmod 600 "$STACKDIR/.join-key.tmp"
    NBUPE=$(timeout -k 5 120 "$NBEXE" up --management-url "https://api.netbird.io" --disable-dns --setup-key-file "$STACKDIR/.join-key.tmp" 2>&1 || true)
    rm -f "$STACKDIR/.join-key.tmp"
    case "$NBUPE" in
      *"invalid"*|*"failed"*|*"error"*|*"unauthorized"*|*"expired"*|*"revoked"*|*"not found"*)
        echo "key rejected - paste the right one (the cloud waits)" >&3
        NETBIRD_SETUP_KEY=""
        continue
        ;;
    esac
    echo "cloud joined with the setup key" >> "$LOG"
    arm_mesh_nameserver
    break
  done
  bar_anim &
  ANIM_PID=$!
fi

# The cloud link is key-only: a desktop never falls back to the app
# sign-in, the key flow below is the one and only path.

# The coordinator's public face is the owner's own LAN, always. The paid
# tunnel is exe-only; the Linux kit never touches the tryredoubt.com edge
# for the mesh. Defined up here because the compose below references it
# in the netbird service environment.
MESH_BASE="http://${LAN_IP}:${PORT_NETBIRD}"

# the panel base: the anchor of the panel login. Selfhost is a
# full-NB NAS now: the tiles and the reveal point at the mesh name, so
# the callback must anchor there too or the login loops behind the
# proxy. Cloud rides the remote name once the owner pasted a PAT (the
# zone is published and the callback resolves on the phone from
# anywhere); without a PAT the callback stays on the LAN address
# like before, because a first pass always lands here: the PAT
# arrives after the compose is written
PANEL_BASE="https://redoubt.remote:${PORT_EDGE4}"
if [ "$MESH_MODE" != "selfhost" ]; then
  if [ -f /etc/redoubt/cloud-pat.txt ]; then
    PANEL_BASE="https://redoubt.remote:${PORT_EDGE4}"
  else
    PANEL_BASE="https://${LAN_IP}:${PORT_EDGE4}"
  fi
fi

NBVER="$(latest_netbird)"
# the console door on the edge is selfhost-only: cloud has no local
# dashboard, so its edge keeps the original ports untouched
CADDY_DASH_PORT=""
[ "$MESH_MODE" = "selfhost" ] && CADDY_DASH_PORT="      - \"0.0.0.0:${PORT_DASH}:8448\""
cat > "$STACKDIR/docker-compose.yml" <<COMPOSE
name: redoubt
services:
  dns:
    image: klutchell/unbound:latest
    container_name: redoubt-dns-1
    restart: unless-stopped
    command: ["-d"]
    volumes:
      - "$STACKDIR/unbound.conf:/etc/unbound/unbound.conf:ro"
      - "dns-root:/var/unbound"
    networks:
      default:
        ipv4_address: 172.28.0.53
  pihole:
    # the ad shield and the LAN side of the split-DNS: it owns the
    # box port 53 and answers redoubt.lan with the LAN address at
    # home. Its only upstream is the stack unbound, so every query
    # still leaves over Quad9 DoT. The admin UI rides the edge like
    # every other app.
    image: pihole/pihole:2026.10.1
    container_name: redoubt-pihole-1
    hostname: redoubt
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    depends_on:
      - dns
    networks:
      default:
        ipv4_address: 172.28.0.54
    environment:
      FTLCONF_dns_upstreams: "172.28.0.53#53"
      FTLCONF_dns_listeningMode: "ALL"
      FTLCONF_dns_hosts: "${LAN_IP} redoubt.lan"
      FTLCONF_webserver_api_password: "${OWNER_PASS}"
    ports:
      # bound to the LAN address and loopback only: the mesh address
      # keeps the agent DNS listener and any other local 53 holder,
      # so a broad bind would collide and the container would never
      # start (a broad bind would collide and the container never starts)
      - "${LAN_IP}:53:53/udp"
      - "${LAN_IP}:53:53/tcp"
      - "127.0.0.1:53:53/udp"
      - "127.0.0.1:53:53/tcp"
    volumes:
      - pihole-data:/etc/pihole
      - pihole-dnsmasq:/etc/dnsmasq.d
  immich-server:
    # floating tags are digest-pinned (see the release notes): to update,
    # bump the tag AND the digest together - docker buildx imagetools
    # inspect <image>:<tag> --format '{{.Manifest.Digest}}'
    image: ghcr.io/immich-app/immich-server:release
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    volumes:
      - /var/lib/redoubt/immich:/usr/src/app/upload
    env_file:
      - .env-immich
    ports:
      - "127.0.0.1:${PORT_IMMICH}:2283"
    depends_on:
      - immich-redis
      - immich-db
  immich-redis:
    image: redis:alpine
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20
  immich-db:
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    environment:
      POSTGRES_USER: immich
      POSTGRES_PASSWORD: "${IMMICH_DB_PASS}"
      POSTGRES_DB: immich
    volumes:
      - /var/lib/redoubt/immich-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U immich"]
      interval: 5s
      timeout: 3s
      retries: 20
  nextcloud:
    # the official "stable" tag lags a major behind (it served 34 while
    # 35.0.2 was out): pin the current major, its patches follow it
    image: nextcloud:35-apache
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    environment:
      POSTGRES_HOST: nextcloud-db
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC_DB_PASS}"
      NEXTCLOUD_ADMIN_USER: "${OWNER_USER}"
      NEXTCLOUD_ADMIN_PASSWORD: "${OWNER_PASS}"
      NEXTCLOUD_TRUSTED_DOMAINS: "${LAN_IP} ${LAN_IP}:${PORT_EDGE2} localhost 127.0.0.1 redoubt.lan redoubt.lan:${PORT_EDGE2} redoubt.remote redoubt.remote:${PORT_EDGE2}"
    volumes:
      # core lives in a named docker volume (internal fs, fast): first
      # boot copies the ~10k files in minutes instead of hours over the
      # Windows 9p/drvfs mount. Only config and user data live under
      # /var/lib/redoubt: the core is code, not data.
      - nc-core:/var/www/html
      - /var/lib/redoubt/nextcloud/config:/var/www/html/config
      - /var/lib/redoubt/nextcloud/data:/var/www/html/data
    ports:
      - "127.0.0.1:${PORT_NEXTCLOUD}:80"
    depends_on:
      - nextcloud-db
  nextcloud-db:
    image: postgres:16-alpine
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    environment:
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: "${NC_DB_PASS}"
    volumes:
      - /var/lib/redoubt/nextcloud-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nextcloud"]
      interval: 5s
      timeout: 3s
      retries: 20
  searxng:
    image: searxng/searxng:latest
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_SEARXNG}:8080"
    environment:
      SEARXNG_BASE_URL: "https://$LAN_IP:$PORT_EDGE3"
      SEARXNG_SECRET: "${SEARXNG_SECRET}"
    volumes:
      - /var/lib/redoubt/searxng:/etc/searxng
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
  glances:
    # the health feed for the panel's system widget: cpu, ram and disk
    # of the HOST (pid: host), not of a container. No host ports: only
    # the panel reaches it over the stack network.
    image: docker.io/nicolargo/glances:latest
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    environment:
      GLANCES_OPT: "-w"
    pid: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
  homarr:
    # the client's dashboard: one page with a tile per app. No host ports,
    # it is only reachable through the local edge (the panel site), so it
    # lives behind the same perimeter as every other app. The admin, the
    # tiles and the branding are seeded by the kit after the first boot.
    image: ghcr.io/homarr-labs/homarr:latest
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    environment:
      # homarr v2 refuses to boot without this key: it encrypts the
      # secrets stored in its database (64-char hex, generated once)
      SECRET_ENCRYPTION_KEY: "${HOMARR_SECRET}"
      # the panel login: the auth secret signs the sessions and the base
      # url anchors the callback. Without both the login loops behind
      # the proxy (the callback resolves to the wrong host).
      AUTH_SECRET: "${HOMARR_AUTH_SECRET}"
      BASE_URL: "${PANEL_BASE}"
      # the login background fetches the icon wall from cdn.jsdelivr.net,
      # which the local resolver points at this box: node needs the local
      # CA on top of its bundled store or the fetch dies on the cert and
      # the animated background stays empty. The dir mount survives the
      # case where the CA file lands a moment after the container starts.
      NODE_EXTRA_CA_CERTS: "/redoubt-certs/root-ca.crt"
    volumes:
      - homarr-data:/appdata
      - /var/lib/redoubt/caddy-local/cert-share:/redoubt-certs:ro
  edge-local:
    image: caddy:alpine
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    depends_on:
      immich-server:
        condition: service_started
      nextcloud:
        condition: service_started
      searxng:
        condition: service_started
      homarr:
        condition: service_started
      pihole:
        condition: service_started
    volumes:
      - "$STACKDIR/local-caddy.Caddyfile:/etc/caddy/Caddyfile:ro"
      - /var/lib/redoubt/caddy-local:/data
    ports:
      - "0.0.0.0:${PORT_EDGE1}:8443"
      - "0.0.0.0:8086:80"
      - "0.0.0.0:${PORT_EDGE2}:8444"
      - "0.0.0.0:${PORT_EDGE3}:8445"
      - "0.0.0.0:${PORT_EDGE4}:8446"
      - "0.0.0.0:${PORT_EDGE5}:8447"
$CADDY_DASH_PORT
      - "0.0.0.0:${PORT_EDGE_CDN}:443"
  netbird:
    profiles: ["selfhost"]
    image: netbirdio/netbird-server:${NBVER}
    dns: [172.28.0.53, 127.0.0.11]
    container_name: redoubt-netbird-1
    restart: unless-stopped
    environment:
      NB_SETUP_PAT_ENABLED: "true"
      # the coordinator never phones home for anything: geolocation is
      # cosmetic (city labels in the dashboard) and its database download
      # would leak a connection to a third party from this machine
      NB_DISABLE_GEOLOCATION: "true"
    ports:
      - "0.0.0.0:${PORT_NETBIRD}:80"
      - "127.0.0.1:${PORT_NETBIRD_MGMT}:33073"
      - "0.0.0.0:${STUN_PORT}:${STUN_PORT}/udp"
    volumes:
      - /var/lib/redoubt/netbird:/var/lib/netbird
      - /var/lib/redoubt/netbird-config.yaml:/etc/netbird/config.yaml
    command: ["--config", "/etc/netbird/config.yaml"]
  dockge:
    image: louislam/dockge:latest
    container_name: redoubt-dockge-1
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_DOCKGE}:5001"
    environment:
      DOCKGE_STACKS_DIR: /opt/stacks
      # upstream disabled the console in v1.5; re-enable it here - the
      # kit-generated dockge login gates it
      DOCKGE_ENABLE_CONSOLE: "true"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - "$STACKDIR/dockge/data:/app/data"
      - /opt/stacks:/opt/stacks
  dashboard:
    profiles: ["selfhost"]
    image: netbirdio/dashboard:latest
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    depends_on:
      netbird:
        condition: service_started
    environment:
      # the dashboard is a browser app: it lives on the edge (https,
      # local CA) and talks to the management on that same origin, the
      # consolidated layout from the NetBird docs. The gRPC origin is
      # the management's own URL because the enroll modal prints it for
      # the netbird CLI on other machines, which reach the box directly
      NETBIRD_MGMT_API_ENDPOINT: "https://${REMOTE_HOST}:${PORT_DASH}"
      NETBIRD_MGMT_GRPC_API_ENDPOINT: "http://${LAN_IP}:${PORT_NETBIRD}"
      USE_AUTH0: "false"
      AUTH_AUTHORITY: "https://${REMOTE_HOST}:${PORT_DASH}/oauth2"
      AUTH_CLIENT_ID: "netbird-dashboard"
      AUTH_AUDIENCE: "netbird-dashboard"
      AUTH_SUPPORTED_SCOPES: "openid profile email groups"
      AUTH_REDIRECT_URI: "/nb-auth"
      AUTH_SILENT_REDIRECT_URI: "/nb-silent-auth"
      NETBIRD_TOKEN_SOURCE: "accessToken"
      NGINX_SSL_PORT: "80"
  mesh-router:
    profiles: ["selfhost"]
    image: nginx:alpine
    dns: [172.28.0.53, 127.0.0.11]
    restart: unless-stopped
    depends_on:
      netbird:
        condition: service_started
      dashboard:
        condition: service_started
    volumes:
      - "$STACKDIR/mesh-router.conf:/etc/nginx/conf.d/default.conf:ro"
      - "$STACKDIR/nginx-main.conf:/etc/nginx/nginx.conf:ro"
      - /var/lib/redoubt:/data
  mesh-wait:
    profiles: ["selfhost"]
    image: busybox:latest
    dns: [172.28.0.53, 127.0.0.11]
    command: ["sh", "-c", "i=0; while [ \$\$i -lt 300 ] && [ ! -f /markers/mesh-ready.txt ]; do sleep 2; i=\$\$((i+1)); done; exit 0"]
    restart: "no"
    volumes:
      - "$STACKDIR:/markers"
volumes:
  nc-core:
  dns-root:
  homarr-data:
  pihole-data:
  pihole-dnsmasq:
networks:
  default:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
COMPOSE
# dockge owns a synced copy so the panel shows the stack as managed;
# the kit file stays the truth and refreshes this on every pass
mkdir -p /opt/stacks/redoubt
cp "$STACKDIR/docker-compose.yml" /opt/stacks/redoubt/docker-compose.yml

# rolling tags pull fresh versions on every pass, and the old ones
# linger eating the disk. Prune before pulling so the new images have
# room (the running stack's images are in use and stay).
docker image prune -af >/dev/null 2>&1 || true

cat > "$STACKDIR/.env-immich" <<ENV
IMMICH_VERSION=release
IMMICH_HOST=0.0.0.0
HOST=0.0.0.0
DB_HOSTNAME=immich-db
DB_USERNAME=immich
DB_PASSWORD="${IMMICH_DB_PASS}"
DB_DATABASE_NAME=immich
REDIS_HOSTNAME=immich-redis
ENV

# The phone reaches the apps through the edge-local caddy over https on
# the home wifi, with the machine's own local CA. No tailnet, no third party.
cat > "$STACKDIR/local-caddy.Caddyfile" <<CADDY
{
	default_sni $LAN_IP
	log {
		output file /data/caddy.log {
			roll_size 5mb
			roll_keep 3
		}
		level DEBUG
	}
	pki {
		ca local {
			name "Redoubt Local CA"
		}
	}
}

# photos (immich)
http://:80 {
	# the trust anchor alone rides plain http: the phone fetches the
	# CA before it can trust the https edge, so this bootstrap download
	# must not depend on the very cert it installs. nothing else is
	# served here.
	handle /ca {
		redir * /root-ca.crt 301
	}
	handle /root-ca.crt {
		root * /data/cert-share
		file_server
		header Content-Type application/x-x509-ca-cert
	}
	handle {
		redir * https://{host}:8443 307
	}
}

https://$LAN_IP:8443, https://127.0.0.1:8443 {
	tls internal
	# the phone fetches its trust anchor over https too: the CA cert
	# rides the same encrypted channel it authenticates. Only the cert
	# is ever served - it lives alone in a dedicated share dir, the key
	# is never in a file_server root
	handle /ca {
		redir * /root-ca.crt 301
	}
	handle /root-ca.crt {
		root * /data/cert-share
		file_server
		header Content-Type application/x-x509-ca-cert
	}
	reverse_proxy immich-server:2283
}

# files (nextcloud)
https://$LAN_IP:8444, https://127.0.0.1:8444 {
	tls internal
	reverse_proxy nextcloud:80
}

# search (searxng)
https://$LAN_IP:8445, https://127.0.0.1:8445 {
	tls internal
	reverse_proxy searxng:8080
}

# ad shield (pi-hole admin). Same perimeter as every app: only the
# edge reaches the container, and the mesh address joins the site on
# the post-join pass like the others.
https://$LAN_IP:8447, https://127.0.0.1:8447 {
	tls internal
	reverse_proxy pihole:80
}

# local mirror for the panel login background icons: cdn.jsdelivr.net
# resolves to this box through the local resolver, so the frontend
# hardcoded CDN urls never leave the house
https://cdn.jsdelivr.net {
	tls internal
	root * /data/cdn
	handle /gh/* {
		@simpleicons path_regexp simpleicons ^/gh/simple-icons/simple-icons@[^/]+/icons/(.+)$
		handle @simpleicons {
			rewrite * /simpleicons/{re.simpleicons.1}
			file_server
		}
		@variant path_regexp variant ^/gh/([^/]+)/([^/]+)@[^/]+/(.+)\.(svg|png|webp)-[0-9]+\\?$
		handle @variant {
			rewrite * /gh/{re.variant.1}/{re.variant.2}/{re.variant.3}.{re.variant.4}
			file_server
		}
		@trailing path_regexp trailing ^/gh/([^/]+)/([^/]+)@[^/]+/(.+)\.(svg|png|webp)\\$
		handle @trailing {
			rewrite * /gh/{re.trailing.1}/{re.trailing.2}/{re.trailing.3}.{re.trailing.4}
			file_server
		}
		@repo path_regexp repo ^/gh/([^/]+)/([^/]+)@[^/]+/(.+)$
		handle @repo {
			rewrite * /gh/{re.repo.1}/{re.repo.2}/{re.repo.3}
			file_server
		}
	}
	handle {
		file_server
	}
}

# panel (homarr). The branding rides the client's own edge: a logo url
# on the public site would serve the anti-bot challenge page to the
# dashboard, so the logo, favicon and tile icons ship with the stack.
https://$LAN_IP:8446, https://127.0.0.1:8446 {
	tls internal
	# the connection badge: which family of address reached the panel
	@home remote_ip $LAN_CIDR
	handle /whereami {
		respond @home "<!doctype html><html><body style='background:#000000;color:#6ee7b7;font-family:ui-monospace,monospace;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;font-size:22px'>🏠 HOME WIFI</body></html>" 200
		respond "<!doctype html><html><body style='background:#000000;color:#6ee7b7;font-family:ui-monospace,monospace;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;font-size:22px'>🛰️ AWAY</body></html>" 200
		header Content-Type "text/html; charset=utf-8"
	}
	handle /icons/* {
		root * /data
		file_server
	}
	handle /cdn/* {
		root * /data
		file_server
	}
	handle /logo.png {
		root * /data
		file_server
	}
	handle /favicon.ico {
		root * /data
		file_server
	}
	handle /gh/* {
		@simpleicons path_regexp simpleicons ^/gh/simple-icons/simple-icons@[^/]+/icons/(.+)$
		handle @simpleicons {
			rewrite * /cdn/simpleicons/{re.simpleicons.1}
			root * /data
			file_server
		}
		@variant path_regexp variant ^/gh/([^/]+)/([^/]+)@[^/]+/(.+)\.(svg|png|webp)-[0-9]+\\?$
		handle @variant {
			rewrite * /cdn/gh/{re.variant.1}/{re.variant.2}/{re.variant.3}.{re.variant.4}
			root * /data
			file_server
		}
		@trailing path_regexp trailing ^/gh/([^/]+)/([^/]+)@[^/]+/(.+)\.(svg|png|webp)\\$
		handle @trailing {
			rewrite * /cdn/gh/{re.trailing.1}/{re.trailing.2}/{re.trailing.3}.{re.trailing.4}
			root * /data
			file_server
		}
		@repo path_regexp repo ^/gh/([^/]+)/([^/]+)@[^/]+/(.+)$
		handle @repo {
			rewrite * /cdn/gh/{re.repo.1}/{re.repo.2}/{re.repo.3}
			root * /data
			file_server
		}
	}
	handle {
		reverse_proxy homarr:7575
	}
}
CADDY

# the mesh console rides the same edge and the same local CA as every
# app, so the owner's browser gets the padlock instead of a plain-http
# warning. selfhost only: cloud has no local dashboard to serve.
if [ "$MESH_MODE" = "selfhost" ]; then
  cat >> "$STACKDIR/local-caddy.Caddyfile" <<CONSOLE

# mesh console (NetBird dashboard)
https://$LAN_IP:$PORT_DASH, https://127.0.0.1:$PORT_DASH {
	tls internal
	reverse_proxy mesh-router:80
}
CONSOLE
fi

# every site also answers by its split-DNS name: the same links work
# from home without the mesh (the pi-hole or /etc/hosts resolve
# redoubt.lan). On re-runs the running edge must reload the new file
sed -i "s|https://127.0.0.1:\([0-9][0-9]*\)|https://redoubt.lan:\1, https://redoubt.remote:\1, https://127.0.0.1:\1|g" "$STACKDIR/local-caddy.Caddyfile"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx redoubt-edge-local-1; then
  docker restart redoubt-edge-local-1 >/dev/null 2>&1 || true
fi

# The client's own NetBird coordinator config. Everything listens inside
# the stack; no third party ever learns the mesh exists (metrics and geo
# updates are off, but the combined server ships with both on by default).
# a fresh box may not have the stack dir yet (re-runs do): make it first
mkdir -p /var/lib/redoubt 2>/dev/null || true
cat > /var/lib/redoubt/netbird-config.yaml <<MESHCFG
server:
  # 0.80 binds the management http on [::] only; the docker port proxy
  # dials IPv4, so the mgmt must bind IPv4 explicitly or every probe
  # and every agent gets a dead port
  listenAddress: "0.0.0.0:80"
  exposedAddress: "${MESH_BASE}"
  stunPorts:
    - ${STUN_PORT}
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  disableAnonymousMetrics: true

  authSecret: "${MESH_AUTH_SECRET}"
  dataDir: "/var/lib/netbird"
  auth:
    issuer: "https://${REMOTE_HOST}:${PORT_DASH}/oauth2"
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "${MESH_COOKIE_KEY}"
    dashboardRedirectURIs:
      # https-only: the window origin is always https, so the legacy
      # http redirect variants are gone. Nothing ever sent them once
      # the http console died; they left with it.
      - "https://${REMOTE_HOST}:${PORT_DASH}/nb-auth"
      - "https://${REMOTE_HOST}:${PORT_DASH}/nb-silent-auth"
      - "https://${LAN_IP}:${PORT_DASH}/nb-auth"
      - "https://${LAN_IP}:${PORT_DASH}/nb-silent-auth"
      - "https://${LAN_HOST}:${PORT_DASH}/nb-auth"
      - "https://${LAN_HOST}:${PORT_DASH}/nb-silent-auth"
    dashboardPostLogoutRedirectURIs:
      - "${MESH_BASE}/"
      - "https://${REMOTE_HOST}:${PORT_DASH}/"
      - "https://${LAN_HOST}:${PORT_DASH}/"
      - "https://${LAN_IP}:${PORT_DASH}/"
    cliRedirectURIs:
      - "http://localhost:53000/"
  store:
    engine: "sqlite"
    encryptionKey: "${MESH_STORE_KEY}"
MESHCFG

# the management loads its config once at start: a re-run that rewrites
# the file (new redirects, new issuer) must bounce the container or the
# dashboard keeps authenticating against the stale copy. The snapshot
# makes the bounce conditional: identical configs skip it (the mesh
# stays untouched on every plain update pass).
if ! cmp -s /var/lib/redoubt/netbird-config.yaml /var/lib/redoubt/netbird-config.yaml.prev 2>/dev/null; then
  docker compose -f "$STACKDIR/docker-compose.yml" restart netbird >/dev/null 2>&1 || true
  cp /var/lib/redoubt/netbird-config.yaml /var/lib/redoubt/netbird-config.yaml.prev
fi

# Private DNS: the box's own resolver, locked to Quad9 over TLS. No plain
# DNS ever leaves this machine, and no megacorp sees the queries.
cat > "$STACKDIR/unbound.conf" <<'UNBOUND'
# Redoubt private resolver, Quad9 over TLS only, DNSSEC validated.
# No plain DNS ever leaves this machine, and Quad9 keeps no records.
server:
    verbosity: 1
    interface: 0.0.0.0
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 172.16.0.0/12 allow
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
    identity: "quad9"
    version: "quad9"
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    harden-algo-downgrade: yes
    use-caps-for-id: yes
    qname-minimisation: yes
    aggressive-nsec: yes
    rrset-roundrobin: yes
    minimal-responses: yes
    prefetch: yes
    cache-min-ttl: 300
    cache-max-ttl: 86400
    val-clean-additional: yes
    unwanted-reply-threshold: 10000000
    auto-trust-anchor-file: "/var/unbound/root.key"
    tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"

# the panel promises zero third-party CDNs: jsDelivr (Homarr's icon
# catalog) resolves to nothing here, so no runtime fetch ever leaves
local-zone: "jsdelivr.net" always_nxdomain
local-zone: "data.jsdelivr.com" always_nxdomain
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-addr: 149.112.112.112@853#dns.quad9.net
remote-control:
    control-enable: no
UNBOUND
# the panel login background fetches 8 icons from cdn.jsdelivr.net:
# the edge mirrors them locally, so the domain resolves to this box
# and the fetch never leaves the house. The rest of jsdelivr stays dead.
# The record must carry the MESH address when the box is enrolled: the
# phone resolves over the mesh and cannot reach the LAN address (the
# login background died exactly like this on a headless box).
_MESH_DNS_IP="$LAN_IP"
_NB_BIN=$(command -v netbird 2>/dev/null || echo /usr/local/bin/netbird)
if [ -x "$_NB_BIN" ]; then
  _MESH_TMP=$("$_NB_BIN" status 2>/dev/null | sed -n 's/^NetBird IP: //p' | head -1)
  [ -n "$_MESH_TMP" ] && _MESH_DNS_IP="${_MESH_TMP%%/*}"
fi
printf 'server:\nlocal-zone: "cdn.jsdelivr.net" redirect\nlocal-data: "cdn.jsdelivr.net. 300 IN A %s"\n' "$_MESH_DNS_IP" >> "$STACKDIR/unbound.conf"
dbg "OK: private resolver config written (Quad9 over TLS)"
  # a re-run rewrites the resolver file; the container reads it only
  # at boot, so bounce it when it is already up
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx redoubt-dns-1; then
    docker restart redoubt-dns-1 >/dev/null 2>&1 || true
  fi
step "stack files written"

# The mesh router: the SPA, management API, OIDC and the client's own
# root CA (for the phone) share one public host; this tiny nginx splits
# them apart. The CA is served from a bind mount, and workers run as root
# because a Windows-made bind can arrive unreadable. It's the client's
# own router, not a public service.
cat > "$STACKDIR/mesh-router.conf" <<'ROUTER'
server {
    listen 80;
    resolver 127.0.0.11 valid=10s ipv6=off;
    set $netbird_backend http://netbird:80;
    set $dashboard_backend http://dashboard:80;

    location /api {
        proxy_pass $netbird_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /oauth2 {
        proxy_pass $netbird_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location = /root-ca.crt {
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition "attachment; filename=Redoubt-Root-CA.crt";
        alias /data/caddy-local/caddy/pki/authorities/local/root.crt;
    }
    location = /root-ca.crt/ {
        rewrite ^ /root-ca.crt last;
    }

    location /relay {
        proxy_pass $netbird_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location /ws-proxy/ {
        proxy_pass $netbird_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location / {
        proxy_pass $dashboard_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
ROUTER

cat > "$STACKDIR/nginx-main.conf" <<'NGINXMAIN'
user root;
worker_processes auto;
events {
    worker_connections 1024;
}
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    error_log /data/nginx-error.log warn;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

cd "$STACKDIR" || exit 1
step "containers pulling and starting"
log "deploying stack..."
# Pull the stack images with a live progress bar. The cloud and
# selfhost branches differ only in the compose profile that builds
# the image list; the caller sets IMGS and N_IMG, everything else
# is identical.
pull_stack() {
  IMGDONE=$(mktemp /tmp/redoubt-pull-done.XXXXXX)
  IMGTOTAL=$(mktemp /tmp/redoubt-pull-total.XXXXXX)
  IMGIMGS=$(mktemp /tmp/redoubt-pull-imgs.XXXXXX)
  IMGACTIVE=$(mktemp /tmp/redoubt-pull-active.XXXXXX)
  pull_one() {  # $1 = image. Pulls it, counts its layer events.
    local IMG=$1 line TRY=0
    echo "S:${IMG##*/}" >> "$IMGACTIVE"
    while [ "$TRY" -lt 3 ]; do
      TRY=$((TRY + 1))
      # a throttled registry can hang a pull forever: the timeout
      # turns the hang into a retry instead of a frozen install
      timeout 480 docker pull "$IMG" 2>&1 | while IFS= read -r line; do
        echo "$line" >> "$LOG"
        case "$line" in
          *"Pull complete"*|*"Already exists"*) echo 1 >> "$IMGDONE" ;;
          *"Pulling fs layer"*|*"Waiting"*|*"Extracting"*) echo 1 >> "$IMGTOTAL" ;;
        esac
      done
      if docker image inspect "$IMG" >/dev/null 2>&1; then
        echo "D:${IMG##*/}" >> "$IMGACTIVE"
        echo "${IMG##*/}" >> "$IMGIMGS"
        return 0
      fi
      [ "$TRY" -lt 3 ] && sleep 8
    done
    echo "D:${IMG##*/}" >> "$IMGACTIVE"
    echo "${IMG##*/} (registry stalled after retries)" >> "$IMGIMGS"
  }
  export -f pull_one
  # xargs children are separate processes, so the counters and the log
  # path must be exported. Otherwise they write to empty paths and the
  # cascade and the bar never move.
  export IMGDONE IMGTOTAL IMGIMGS IMGACTIVE LOG
  echo "$IMGS" | tr ' ' '\n' | xargs -P 3 -I{} bash -c 'pull_one "$1"' _ {} &
  PULL_PID=$!
  # a repatch verifies the cached images quietly: one clean label
  # instead of a burst of registry names
  if [ "${RERUN:-0}" = "1" ]; then
    draw_bar "$SEG_START" "stack images (cached)"
  fi
  # The hybrid: three images download at once, the bar maps real layer
  # completions, and the label counts finished images.
  LAST_N=0
  while kill -0 "$PULL_PID" 2>/dev/null; do
    D=$(wc -l < "$IMGDONE" 2>/dev/null || echo 0)
    T=$(wc -l < "$IMGTOTAL" 2>/dev/null || echo 0)
    N=$(wc -l < "$IMGIMGS" 2>/dev/null || echo 0)
    # per-image lines go straight to the TTY so the bar label stays intact
    if [ "$N" -gt "$LAST_N" ]; then
      sed -n "$((LAST_N+1)),${N}p" "$IMGIMGS" 2>/dev/null | while IFS= read -r nm; do
        case "$nm" in *@sha256:*) nm=${nm%%@sha256:*} ;; esac
        # a repatch has the images cached: the per-image cascade is
        # just technical noise then, so it stays in the log only
        if [ "${RERUN:-0}" != "1" ]; then
          [ ${#nm} -gt 44 ] && nm="${nm:0:41}${TRUNC}"
          printf '\r\033[K' >&3
          printf "  ${EM2}image done: %s\033[0m\n" "$nm" >&3
        fi
      done
      LAST_N=$N
    fi
    if [ "$T" -gt 0 ] && [ "${RERUN:-0}" != "1" ]; then
      [ "$D" -gt "$T" ] && D=$T
      # the label names what is actually downloading right now: the
      # workers mark starts and finishes in an append-only file, and
      # the last open start wins (a finished image must never read
      # as "pulling" while its "done" line sits right above)
      LIMG=$(awk '{n=substr($0,3); if ($1 ~ /^S:/) {c[n]++; last=n} else {c[n]--; if (n==last && c[n]<=0) last=""}} END{print last}' "$IMGACTIVE" 2>/dev/null)
      case "$LIMG" in *@sha256:*) LIMG=${LIMG%%@sha256:*} ;; esac
      [ ${#LIMG} -gt 30 ] && LIMG="${LIMG:0:27}${TRUNC}"
      if [ -n "$LIMG" ]; then
        draw_bar "$(( SEG_START + ( SEG_END - SEG_START ) * D / T ))" "pulling $LIMG - $N/$N_IMG"
      else
        draw_bar "$(( SEG_START + ( SEG_END - SEG_START ) * D / T ))" "pulling images - $N/$N_IMG"
      fi
    fi
    sleep 0.5
  done
  wait "$PULL_PID" 2>/dev/null || true
  rm -f "$IMGDONE" "$IMGTOTAL" "$IMGIMGS" "$IMGACTIVE"
  draw_bar "$SEG_END" "stack pulled - $N_IMG/$N_IMG images"
}

case "$MESH_MODE" in
  cloud)
    dbg "OK: mesh mode cloud (NetBird brokers the handshake)"
    IMGS=$(docker compose config --images 2>/dev/null)
    N_IMG=$(echo "$IMGS" | wc -w)
    pull_stack
    # a jump from selfhost to cloud must not leave the coordinator
    # containers orphaned behind the cloud stack: stop and remove
    # them so only the cloud set runs
    docker compose --profile selfhost rm -sf netbird dashboard mesh-router mesh-wait >> "$LOG" 2>&1 || true
    COMP_OUT=/tmp/redoubt-compose-out.$$
    docker compose up -d 2>&1 | tee -a "$COMP_OUT" >> "$LOG"
    ;;
  selfhost)
    IMGS=$(docker compose --profile selfhost config --images 2>/dev/null)
    N_IMG=$(echo "$IMGS" | wc -w)
    pull_stack
    COMP_OUT=/tmp/redoubt-compose-out.$$
    docker compose --profile selfhost up -d 2>&1 | tee -a "$COMP_OUT" >> "$LOG"
    ;;
esac
# the count is mode-aware: the other mode's containers must never leak
# into the number (a jump used to read 16/16 while the mesh-wait helper
# was still standing). One stack, the active mode's services only.
if [ "$MESH_MODE" = "cloud" ]; then
  _STACK_PS=$(docker compose ps --format '{{.Name}} {{.State}}' | grep -vE 'redoubt-(netbird|dashboard|mesh-router|mesh-wait)-1')
else
  _STACK_PS=$(docker compose ps --format '{{.Name}} {{.State}}' | grep -v 'redoubt-mesh-wait-1')
fi
printf '%s' "$_STACK_PS" >> "$LOG"
_STACK_SUM=$(printf '%s' "$_STACK_PS" | awk -v c="$EM2" '$2=="running"{up++} END{printf "  %sstack: %d/%d containers running\033[0m", c, up, NR}')
log "$_STACK_SUM"
# a container whose layer a power cut corrupted reads as a scary docker
# error while compose re-creates it on the spot. If the final count is
# full, say the recovery out loud: the owner saw the red error and needs
# the verdict, not silence
_STACK_UP=$(printf '%s' "$_STACK_PS" | awk '$2=="running"{n++} END{print n+0}')
_STACK_TOT=$(printf '%s' "$_STACK_PS" | wc -l)
if [ "$_STACK_UP" = "$_STACK_TOT" ] && [ "${_STACK_TOT:-0}" -gt 0 ] \
   && grep -q 'unexpectedly nil' "$COMP_OUT" 2>/dev/null; then
  log "OK: stack back up (a container had a stale layer from an interrupted run)"
fi
# the same stale layer can also leave a container DOWN: compose refuses
# to reuse the corrupt record, so the corpse blocks every later pass.
# Drop it, bring the stack back up and say so: the owner saw the red
# error and needs the verdict, not silence. The gate is strict: only a
# genuinely dead container (exited/dead) with the nil error in the
# compose output is a corpse. A container still starting must never be
# touched, or the repair would kill it while it is being born.
_STACK_DOWN=$(printf '%s' "$_STACK_PS" | awk '$2=="exited"||$2=="dead"{print $1}' | head -1)
if [ -n "$_STACK_DOWN" ] && grep -q 'unexpectedly nil' "$COMP_OUT" 2>/dev/null; then
  docker rm -f "$_STACK_DOWN" >/dev/null 2>&1 || true
  docker compose up -d >> "$LOG" 2>&1 || true
  log "OK: stack rebuilt ($_STACK_DOWN had a stale layer)"
  # the verdict must match what the owner sees: recount after the heal
  _STACK_PS2=$(docker compose ps --format '{{.Name}} {{.State}}' | grep -vE 'redoubt-(netbird|dashboard|mesh-router|mesh-wait)-1')
  _STACK_SUM2=$(printf '%s' "$_STACK_PS2" | awk -v c="$EM2" '$2=="running"{up++} END{printf "  %sstack: %d/%d containers running\033[0m", c, up, NR}')
  log "$_STACK_SUM2"
fi
rm -f "$COMP_OUT"

# 5) MTU/MSS hardening. ISPs with WAN MTU under 1500 break Go's fat TLS hellos (e.g. PQ MLKEM).
WANIF=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -n "$WANIF" ]; then
  ip link set dev "$WANIF" mtu 1400 2>/dev/null || true
  dbg "OK: WAN MTU ($WANIF) -> 1400"
fi

# 6) Mesh. Two paths, chosen up front:
#    selfhost: the kit runs the client's own NetBird coordinator here,
#    LAN-first; the customer's own NetBird account carries any-network access.
#    cloud: NetBird's servers broker the handshake with the user's setup
#    key. The phone works from any network; no servers of ours involved.
# a hard-killed agent leaves its wireguard interface behind, and the
# next start makes wt1, then wt2: drop every stale one first so the
# applet always shows a single clean tunnel
for _WT in $(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'); do
  ip link delete dev "$_WT" 2>/dev/null || true
done
if [ "$MESH_MODE" = "selfhost" ]; then
if [ -z "${OWNER_PASS:-}" ]; then
  dbg "WARNING: no owner password, mesh stays LAN-only"
else
  dbg "waiting for the coordinator..."
  PAT=""
  READY=""
  for i in $(seq 1 30); do
    READY=$(curl -s --max-time 5 "http://127.0.0.1:${PORT_NETBIRD}/api/setup" 2>/dev/null | head -c 40)
    case "$READY" in *setup*|*email*|*404*|"*not found*") break ;; esac
    sleep 2
  done
  if [ -z "$READY" ]; then
    dbg "WARNING: coordinator not answering, mesh stays LAN-only"
  else
    PAT=""
    if [ -f "$STACKDIR/mesh-pat.txt" ]; then
      PAT=$(cat "$STACKDIR/mesh-pat.txt")
    else
      R=$(curl -s --max-time 30 -X POST "http://127.0.0.1:$PORT_NETBIRD/api/setup" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"owner@redoubt.local\",\"name\":\"$OWNER_USER\",\"password\":\"$OWNER_PASS\",\"create_pat\":true,\"pat_expire_in\":365}")
      PAT=$(printf '%s' "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('personal_access_token',''))" 2>/dev/null)
      if [ -z "$PAT" ] && printf '%s' "$R" | grep -q 'already completed'; then
        # Setup already ran (an older pass or a lost PAT file). With no
        # PAT on disk the mesh is unmanageable, so rebuild the coordinator
        # state and set it up again; the phone scans the fresh key
        # in the welcome folder.
        # Coordinator state lives in the compose volume, not the config
        # dir. The datastore is /var/lib/redoubt/netbird.
        docker stop redoubt-netbird-1 >/dev/null 2>&1
        rm -rf /var/lib/redoubt/netbird
        docker start redoubt-netbird-1 >/dev/null 2>&1
        sleep 5
        R=$(curl -s --max-time 30 -X POST "http://127.0.0.1:$PORT_NETBIRD/api/setup" \
          -H "Content-Type: application/json" \
          -d "{\"email\":\"owner@redoubt.local\",\"name\":\"$OWNER_USER\",\"password\":\"$OWNER_PASS\",\"create_pat\":true,\"pat_expire_in\":365}")
        PAT=$(printf '%s' "$R" | python3 -c "import sys,json; print(json.load(sys.stdin).get('personal_access_token',''))" 2>/dev/null)
        # If setup is still claimed after a fresh coordinator, this was
        # not an old pass of this kit: someone else took the mesh. Say it
        # loud. Never silently leave the user with a mesh that answers to
        # a stranger.
        if [ -z "$PAT" ] && printf '%s' "$R" | grep -q 'already completed'; then
          echo "WARNING: the mesh is claimed by a third party. Not you? Wipe this machine." >&3
        fi
      fi
    fi
      if [ -n "$PAT" ]; then
        printf '%s\n' "$PAT" > "$STACKDIR/mesh-pat.txt"
        chmod 600 "$STACKDIR/mesh-pat.txt"
        dbg "OK: coordinator bootstrapped"
      fi
    fi
    if [ -n "$PAT" ]; then
      # Enrollment keys: reuse the saved pair while the coordinator still
      # lists it as valid (minting on every pass piles up live one-off
      # keys). The host key rotates after its window and the old one is
      # revoked, so a leaked but unused key dies with it. The host key
      # also tags the enrolling peer with the machine's identity group:
      # the coordinator knows which peer belongs to this host.
      LISTK=$(mktemp /tmp/nb-keys.XXXXXX)
      curl -s --max-time 30 "http://127.0.0.1:$PORT_NETBIRD/api/setup-keys" -H "Authorization: Bearer $PAT" > "$LISTK" 2>/dev/null
      # the identity group must exist before the host key references it:
      # the coordinator rejects unknown auto groups, and the reference is
      # the group's ID, not its name (the name lookup 422s). Create the
      # group once, idempotently, and keep its id.
      HOST_GROUP_ID=$(curl -s --max-time 20 "http://127.0.0.1:$PORT_NETBIRD/api/groups" -H "Authorization: Bearer $PAT" \
        | python3 -c "import sys,json; print(next((g.get('id','') for g in json.load(sys.stdin) if g.get('name')=='host-$MESH_ID'), ''))" 2>/dev/null)
      if [ -z "$HOST_GROUP_ID" ]; then
        HOST_GROUP_ID=$(curl -s --max-time 20 -X POST "http://127.0.0.1:$PORT_NETBIRD/api/groups" \
          -H "Content-Type: application/json" -H "Authorization: Bearer $PAT" \
          -d "{\"name\":\"host-$MESH_ID\"}" \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
      fi
      # the list endpoint masks the key value (first 5 chars + stars), so
      # a saved key can never be matched against it. The id is stable and
      # unmasked: the id file is the reliable handle, the key file feeds
      # the join. Both are written by the mint and reused while the
      # coordinator still lists the id as valid and unrevoked.
      is_live_id() {
        python3 -c "
import sys, json
want = sys.argv[1]
for k in json.load(open(sys.argv[2])):
    if k.get('id') == want and not k.get('revoked') and k.get('valid', True):
        print('ok'); break
" "$1" "$LISTK" 2>/dev/null
      }
      mint_host_key() {
        curl -s --max-time 30 -X POST "http://127.0.0.1:$PORT_NETBIRD/api/setup-keys" \
          -H "Content-Type: application/json" -H "Authorization: Bearer $PAT" \
          -d "{\"name\":\"host\",\"type\":\"one-off\",\"expires_in\":315360000,\"auto_groups\":[\"$HOST_GROUP_ID\"]}" \
          | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('key', ''))
print(d.get('id', ''))
" 2>/dev/null
      }
      mint_mobile_key() {
        curl -s --max-time 30 -X POST "http://127.0.0.1:$PORT_NETBIRD/api/setup-keys" \
          -H "Content-Type: application/json" -H "Authorization: Bearer $PAT" \
          -d "{\"name\":\"mobile\",\"type\":\"one-off\",\"expires_in\":2592000}" \
          | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('key', ''))
print(d.get('id', ''))
" 2>/dev/null
      }
      revoke_key_id() {
        # the update endpoint wants the full key object, not a bare flag
        OLD_JSON=$(python3 -c "
import sys, json
for k in json.load(open(sys.argv[1])):
    if k.get('id') == sys.argv[2]:
        body = dict(k)
        body['revoked'] = True
        for f in ('id', 'updated_at', 'last_used'):
            body.pop(f, None)
        print(json.dumps(body)); break
" "$LISTK" "$1" 2>/dev/null)
        [ -n "$OLD_JSON" ] && curl -s --max-time 30 -X PUT "http://127.0.0.1:$PORT_NETBIRD/api/setup-keys/$1" \
          -H "Content-Type: application/json" -H "Authorization: Bearer $PAT" \
          -d "$OLD_JSON" >/dev/null 2>&1 || true
      }
      HOST_KEY=""
      HOST_KEY_ID=""
      OLD_HOST_KEY_ID=""
      [ -f "$STACKDIR/host-mesh-key.id" ] && OLD_HOST_KEY_ID=$(tr -d '\n' < "$STACKDIR/host-mesh-key.id")
      ROTATE=0
      if [ -f /etc/redoubt/host-key-age ] && [ "$(( $(date +%s) - $(cat /etc/redoubt/host-key-age) ))" -gt 7776000 ]; then
        ROTATE=1
      fi
      if [ -n "$OLD_HOST_KEY_ID" ] && [ "$ROTATE" = "0" ] && [ "$(is_live_id "$OLD_HOST_KEY_ID")" = "ok" ]; then
        HOST_KEY_ID="$OLD_HOST_KEY_ID"
        HOST_KEY=$(tr -d '\n' < "$STACKDIR/host-mesh-key.txt")
      fi
      if [ -z "$HOST_KEY" ]; then
        MINTED=$(mint_host_key)
        HOST_KEY=$(printf '%s' "$MINTED" | sed -n '1p')
        HOST_KEY_ID=$(printf '%s' "$MINTED" | sed -n '2p')
        if [ -n "$HOST_KEY" ]; then
          printf '%s\n' "$HOST_KEY" > "$STACKDIR/host-mesh-key.txt"
          printf '%s\n' "$HOST_KEY_ID" > "$STACKDIR/host-mesh-key.id"
          chmod 600 "$STACKDIR/host-mesh-key.txt" "$STACKDIR/host-mesh-key.id"
          date +%s > /etc/redoubt/host-key-age
          chmod 600 /etc/redoubt/host-key-age
          dbg "OK: host key minted (bound to host-$MESH_ID)"
        fi
        # the previous key dies here: revoked, not just replaced (a
        # leaked but unused key loses its window with the rotation)
        if [ -n "$OLD_HOST_KEY_ID" ] && [ "$OLD_HOST_KEY_ID" != "$HOST_KEY_ID" ]; then
          revoke_key_id "$OLD_HOST_KEY_ID"
        fi
      fi
      MOBILE_KEY=""
      MOBILE_KEY_ID=""
      OLD_MOBILE_KEY_ID=""
      [ -f "$STACKDIR/mobile-mesh-key.id" ] && OLD_MOBILE_KEY_ID=$(tr -d '\n' < "$STACKDIR/mobile-mesh-key.id")
      if [ -n "$OLD_MOBILE_KEY_ID" ] && [ "$(is_live_id "$OLD_MOBILE_KEY_ID")" = "ok" ]; then
        MOBILE_KEY_ID="$OLD_MOBILE_KEY_ID"
        MOBILE_KEY=$(tr -d '\n' < "$STACKDIR/mobile-mesh-key.txt")
      fi
      if [ -z "$MOBILE_KEY" ]; then
        MINTED=$(mint_mobile_key)
        MOBILE_KEY=$(printf '%s' "$MINTED" | sed -n '1p')
        MOBILE_KEY_ID=$(printf '%s' "$MINTED" | sed -n '2p')
        if [ -n "$MOBILE_KEY" ]; then
          printf '%s\n' "$MOBILE_KEY" > "$STACKDIR/mobile-mesh-key.txt"
          printf '%s\n' "$MOBILE_KEY_ID" > "$STACKDIR/mobile-mesh-key.id"
          chmod 600 "$STACKDIR/mobile-mesh-key.txt" "$STACKDIR/mobile-mesh-key.id"
          dbg "OK: mobile key minted"
        fi
      fi
      # sweep leftovers: older passes minted fresh keys on every run.
      # Any valid key with the same name that is not the current one
      # dies here, so the coordinator keeps exactly one live pair.
      python3 -c "
import sys, json
name = sys.argv[1]; keep = sys.argv[2]
for k in json.load(open(sys.argv[3])):
    if k.get('name') == name and not k.get('revoked') and k.get('valid', True) and k.get('id') != keep:
        print(k.get('id', ''))
" host "$HOST_KEY_ID" "$LISTK" 2>/dev/null | while read -r OLD_ID; do
        [ -n "$OLD_ID" ] && revoke_key_id "$OLD_ID"
      done
      python3 -c "
import sys, json
name = sys.argv[1]; keep = sys.argv[2]
for k in json.load(open(sys.argv[3])):
    if k.get('name') == name and not k.get('revoked') and k.get('valid', True) and k.get('id') != keep:
        print(k.get('id', ''))
" mobile "$MOBILE_KEY_ID" "$LISTK" 2>/dev/null | while read -r OLD_ID; do
        [ -n "$OLD_ID" ] && revoke_key_id "$OLD_ID"
      done
      rm -f "$LISTK"
      if [ ! -f "$STACKDIR/mesh-ready.txt" ]; then
        printf 'ready\n' > "$STACKDIR/mesh-ready.txt"
        chmod 600 "$STACKDIR/mesh-ready.txt"
      fi
      dbg "OK: the client's own mesh is alive"
    else
      dbg "WARNING: bootstrap failed, mesh stays LAN-only"
    fi
  fi

  # 6b) Host agent. The machine joins its own mesh (official binary,
  #     pinned release, sha256-verified) and announces the home network
  #     so the phone reaches the apps from any network.
  HOST_KEY=$(cat "$STACKDIR/host-mesh-key.txt" 2>/dev/null)
  if [ -n "$HOST_KEY" ]; then
    NBEXE=$(command -v netbird 2>/dev/null || echo /usr/local/bin/netbird)
    NEED_NB=0
    if [ "$PKG_FAMILY" = "apt" ]; then
      # On apt machines the deb has to own the agent: netbird-ui depends
      # on the netbird package and its dpkg -i fails without it. A legacy
      # tarball copy in /usr/local/bin does not count. Migrate it.
      { dpkg -s netbird >/dev/null 2>&1 && "$NBEXE" version 2>/dev/null | grep -q "$NBVER"; } || NEED_NB=1
    else
      { [ -x "$NBEXE" ] && "$NBEXE" version 2>/dev/null | grep -q "$NBVER"; } || NEED_NB=1
    fi
    if [ "$NEED_NB" = "1" ]; then
      NBOK=0
      if [ "$PKG_FAMILY" = "apt" ]; then
        # The deb keeps dpkg aware of the agent and installs the binary
        # to /usr/sbin/netbird (not /usr/local/bin), which netbird-ui
        # depends on. The tarball leaves that dependency unsolvable, and
        # apt then refuses the GUI. Remove any legacy tarball copy in
        # /usr/local/bin, so the deb is the only truth on apt machines.
        # Everything lands in a private mktemp dir (0700), and the deb
        # is sha256-verified against the vendor checksums file. No fixed
        # /tmp names a local user can symlink or race, and the tmp dir
        # is removed again at the end.
        NBTMP=$(mktemp -d /tmp/netbird-install.XXXXXX)
        chmod 700 "$NBTMP"
        NBDEB="$NBTMP/netbird_${NBVER}_linux_amd64.deb"
        if nb_fetch "netbird_${NBVER}_linux_amd64.deb" "netbird_${NBVER}_checksums.txt" "$NBTMP" \
          && { dpkg -i "$NBDEB" >/dev/null 2>&1 || apt-get install -y -f -qq >/dev/null 2>&1; }; then
          NBOK=1
          # 0.79 ships the binary in /usr/bin (older releases used
          # /usr/sbin), so resolve the real path instead of hardcoding.
          NBEXE=$(command -v netbird 2>/dev/null || echo /usr/bin/netbird)
          rm -f /usr/local/bin/netbird
        fi
        rm -rf "$NBTMP"
      else
        NBTMP=$(mktemp -d /tmp/netbird-install.XXXXXX)
        chmod 700 "$NBTMP"
        NBTGZ="$NBTMP/netbird_${NBVER}_linux_amd64.tar.gz"
        if nb_fetch "netbird_${NBVER}_linux_amd64.tar.gz" "netbird_${NBVER}_checksums.txt" "$NBTMP" \
          && tar -xzf "$NBTGZ" -C "$NBTMP" netbird && install -m 755 "$NBTMP/netbird" "$NBEXE"; then
          NBOK=1
        fi
        rm -rf "$NBTMP"
      fi
      if [ "$NBOK" = "1" ]; then
        dbg "OK: netbird agent $NBVER installed"
      else
        dbg "WARNING: netbird agent download failed, phone works on LAN"
      fi
    fi
    # The daemon: the GUI and tray speak to the agent over its local
    # socket, so the service has to run and come back after a reboot.
    if [ -x "$NBEXE" ] && [ ! -S /var/run/netbird.sock ]; then
      "$NBEXE" service install >/dev/null 2>&1 || true
      "$NBEXE" service start >/dev/null 2>&1 || true
      systemctl enable netbird >/dev/null 2>&1 || true
      dbg "OK: netbird service running"
    elif [ -x "$NBEXE" ] && [ ! -f /var/lib/netbird/default.json ]; then
      # daemon alive but its config was wiped (disk image, reset):
      # a restart rewrites the config; an up would just 500 on it
      systemctl restart netbird >/dev/null 2>&1 || true
      dbg "OK: netbird service restarted to rebuild its config"
    fi
    # This milestone sits outside the conditionals. On a repatch the
    # agent may already be running, but the bar still has to walk its segment.
    step "your mesh, up"
    # The NetBird window for a fresh Linux user: the GUI speaks the same
    # protocol as the CLI, it just draws a tray icon and a window. The
    # kit runs as root through sudo, so the display variables are gone by
    # now. loginctl still sees the real sessions, and a display manager
    # on disk is proof enough on a desktop.
    HAS_GUI=0
    if command -v loginctl >/dev/null 2>&1; then
      for S in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        T=$(loginctl show-session "$S" -p Type --value 2>/dev/null || true)
        case "$T" in x11|wayland) HAS_GUI=1; break ;; esac
      done
    fi
    if [ "$HAS_GUI" = "0" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      HAS_GUI=1
    fi
    # The kit runs under the sudo chain where DISPLAY is empty even while
    # the desktop is live: derive it from the running session's sockets.
    GUI_DISPLAY=""
    for GS in /tmp/.X11-unix/X*; do
      [ -e "$GS" ] || continue
      GUI_DISPLAY=":${GS#/tmp/.X11-unix/X}"
      break
    done
    [ -n "$GUI_DISPLAY" ] || GUI_DISPLAY="${DISPLAY:-:0}"
    if [ "$HAS_GUI" = "0" ]; then
      ls /usr/share/xsessions/*.desktop >/dev/null 2>&1 && HAS_GUI=1
      ls /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1 && HAS_GUI=1
    fi
    if [ "$HAS_GUI" = "0" ]; then
      dbg "no graphical session seen, netbird-ui skipped"
    fi
    if [ "$HAS_GUI" = "1" ]; then
      if [ "$PKG_FAMILY" = "apt" ]; then
        NBUITMP=$(mktemp -d /tmp/netbird-ui.XXXXXX)
        chmod 700 "$NBUITMP"
        NBUIDEB="$NBUITMP/netbird-ui_${NBVER}_linux_amd64.deb"
        if nb_fetch "netbird-ui_${NBVER}_linux_amd64.deb" "netbird-ui_${NBVER}_checksums.txt" "$NBUITMP" \
          && { dpkg -i "$NBUIDEB" >/dev/null 2>&1 || apt-get install -y -f -qq >/dev/null 2>&1; }; then
          # The deb ships no autostart entry; this .desktop file is what
          # launches the tray icon at login (0.81+ removed the --hidden
          # flag, so a plain Exec start is enough). The webkit env keeps
          # the shipped DMABUF workaround for the renderer.
          mkdir -p /etc/xdg/autostart
          cat > /etc/xdg/autostart/netbird-ui.desktop <<NBDESK
[Desktop Entry]
Type=Application
Name=NetBird
Comment=Your mesh, in the tray
Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 /usr/bin/netbird-ui
Icon=netbird
Terminal=false
X-GNOME-Autostart-enabled=true
NBDESK
          # the session must be able to read it: the kit umask makes
          # it 600, which the desktop ignores
          chmod 644 /etc/xdg/autostart/netbird-ui.desktop
          # The autostart entry only fires on the next login, so the
          # first install would leave the tray empty until then. Launch
          # it in the current session right away, as the desktop user.
          if [ -n "${SUDO_USER:-}" ]; then
            sudo -u "$SUDO_USER" env DISPLAY="$GUI_DISPLAY" \
              WEBKIT_DISABLE_DMABUF_RENDERER=1 \
              nohup /usr/bin/netbird-ui >/dev/null 2>&1 &
          fi
          dbg "OK: netbird-ui installed (tray icon)"
          echo "$NBVER" > /etc/redoubt/netbird-ui.version
          chmod 644 /etc/redoubt/netbird-ui.version
        else
          dbg "netbird-ui skipped, the CLI and the web dashboard work"
        fi
        rm -rf "$NBUITMP"
      else
        # Arch/Fedora families: no official package. The release tarball
        # goes to /usr/local/bin with a menu entry.
        if [ "$PKG_FAMILY" = "pacman" ]; then
          # webkitgtk-6.0 carries both the webkit and javascriptcore
          # libraries the UI links against.
          pacman -S --noconfirm --needed webkitgtk-6.0 >/dev/null 2>&1 || true
        elif [ "$PKG_FAMILY" = "dnf" ]; then
          dnf install -y webkitgtk6.0 >/dev/null 2>&1 || true
        elif [ "$PKG_FAMILY" = "zypper" ]; then
          # Tumbleweed ships the webkit runtime as libwebkitgtk-6_0-4:
          # the UI binary links against its libwebkitgtk-6.0.so.4
          zypper --non-interactive install libwebkitgtk-6_0-4 >/dev/null 2>&1 || true
        fi
        NBUITMP=$(mktemp -d /tmp/netbird-ui.XXXXXX)
        chmod 700 "$NBUITMP"
        NBUITGZ="$NBUITMP/netbird-ui-linux_${NBVER}_linux_amd64.tar.gz"
        if nb_fetch "netbird-ui-linux_${NBVER}_linux_amd64.tar.gz" "netbird-ui_${NBVER}_checksums.txt" "$NBUITMP" \
          && tar -xzf "$NBUITGZ" -C "$NBUITMP" netbird-ui \
          && install -m 755 "$NBUITMP/netbird-ui" /usr/local/bin/netbird-ui; then
          cat > /usr/share/applications/netbird-ui.desktop <<NBDESKTOP
[Desktop Entry]
Name=NetBird
Comment=Your mesh status and settings
Exec=/usr/local/bin/netbird-ui
Icon=network-vpn
Terminal=false
Type=Application
Categories=Network;
NBDESKTOP
          chmod 644 /usr/share/applications/netbird-ui.desktop
          mkdir -p /etc/xdg/autostart
          cp /usr/share/applications/netbird-ui.desktop /etc/xdg/autostart/netbird-ui.desktop 2>/dev/null || true
          chmod 644 /etc/xdg/autostart/netbird-ui.desktop
          dbg "OK: netbird-ui installed (desktop entry)"
          echo "$NBVER" > /etc/redoubt/netbird-ui.version
          chmod 644 /etc/redoubt/netbird-ui.version
        else
          dbg "netbird-ui skipped, the CLI and the web dashboard work"
        fi
        rm -f "$NBUITGZ" /tmp/netbird-ui
      fi
    fi

  # the updater compares these records against the vendor release to
  # refresh the mesh pieces: write them honestly, they feed the update
  if [ -x "$NBEXE" ] && "$NBEXE" version 2>/dev/null | grep -q "$NBVER"; then
    echo "$NBVER" > /etc/redoubt/netbird.version
    chmod 644 /etc/redoubt/netbird.version
  fi
    if [ -x "$NBEXE" ]; then
      UP=$("$NBEXE" status 2>/dev/null | tr 'A-Z' 'a-z')
      JOINED_LOCAL=0
      # an agent linked to the cloud belongs to a different network:
      # a selfhost/both pass must bring it back to the local
      # coordinator, or the host silently keeps its cloud link while
      # the local mesh runs without it
      if nb_cloud_linked; then
        "$NBEXE" down >/dev/null 2>&1 || true
        sleep 2
        UP=$("$NBEXE" status 2>/dev/null | tr 'A-Z' 'a-z')
      fi
      case "$UP" in
        *connected*) ;;
        *)
          # The setup key travels via a 600 file, never argv. Any
          # local user can read /proc cmdline while the join runs.
          printf '%s' "$HOST_KEY" > "$STACKDIR/.join-key.tmp"
          chmod 600 "$STACKDIR/.join-key.tmp"
          UPERR=$(timeout -k 5 120 "$NBEXE" up --management-url "http://127.0.0.1:$PORT_NETBIRD" --disable-dns --setup-key-file "$STACKDIR/.join-key.tmp" 2>&1 || true)
          rm -f "$STACKDIR/.join-key.tmp"
          for i in $(seq 1 30); do
            UP=$("$NBEXE" status 2>/dev/null | tr 'A-Z' 'a-z')
            case "$UP" in *connected*) break ;; esac
            sleep 10
          done
          case "$UP" in *connected*) JOINED_LOCAL=1 ;; esac
        ;;
      esac
      case "$UP" in
        *connected*)
          if [ "$JOINED_LOCAL" = "1" ]; then
            dbg "OK: host joined its own mesh"
          else
            dbg "OK: host keeps its existing mesh link"
          fi
      # the peer's identity, pinned after the join: the coordinator id
      # for this host is stable across passes, so a different machine
      # enrolled under our key raises a warning instead of passing.
      PEER_ID_FILE=/etc/redoubt/mesh-peer-id.txt
      PEER_ID=$(curl -s --max-time 30 "http://127.0.0.1:$PORT_NETBIRD/api/peers" -H "Authorization: Bearer $PAT" \
        | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    if p.get('hostname') == '$HOSTNAME' or p.get('name') == '$HOSTNAME':
        print(p.get('id', '')); break" 2>/dev/null)
      if [ -n "$PEER_ID" ]; then
        if [ -f "$PEER_ID_FILE" ] && [ "$(cat "$PEER_ID_FILE")" != "$PEER_ID" ]; then
          echo "WARNING: the mesh peer identity changed (was $(cat "$PEER_ID_FILE"), now $PEER_ID). If you did not reinstall, the host key may have been used by another machine." >&3
        fi
        printf '%s\n' "$PEER_ID" > "$PEER_ID_FILE"
        chmod 600 "$PEER_ID_FILE"
      fi
      # one wireguard profile is enough: network manager auto-creates a
      # profile each time the agent brings its interface up, and joins
      # across passes can pile up duplicate "wt0" entries in the network
      # list. Keep the active one, drop the rest.
      if command -v nmcli >/dev/null 2>&1; then
        nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ":wireguard" | cut -d: -f1 | while read -r P; do
          ST=$(nmcli -t -f GENERAL.STATE connection show "$P" 2>/dev/null | cut -d: -f2 | head -1)
          [ "$ST" = "activated" ] || nmcli connection delete "$P" >/dev/null 2>&1 || true
        done
      fi
          NETBIRD_IP=""
          for _NBI in $(seq 1 10); do
            NETBIRD_IP=$("$NBEXE" status 2>/dev/null | awk -F': ' '/^NetBird IP:/ {print $2; exit}' | cut -d/ -f1)
            case "$NETBIRD_IP" in *.*.*.*) break ;; esac
            sleep 5
          done
          case "$NETBIRD_IP" in *.*.*.*) ;; *) NETBIRD_IP="" ;; esac
          if [ -n "$LAN_IP" ]; then
            # mgmt 0.79 dropped 'netbird routes add', so the home-network
            # route is created on the API (and the network itself when
            # the coordinator has none). Everything is 127.0.0.1-local.
            NBAPI="http://127.0.0.1:$PORT_NETBIRD/api"
            NBRC=""
            NET_ID=$(curl -s --max-time 20 "$NBAPI/networks" -H "Authorization: Bearer $PAT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
            if [ -z "$NET_ID" ]; then
              NET_ID=$(curl -s --max-time 20 -X POST "$NBAPI/networks" -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -d '{"name":"default","description":"redoubt mesh"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
            fi
            PEER_ID=$(curl -s --max-time 20 "$NBAPI/peers" -H "Authorization: Bearer $PAT" | python3 -c "import sys,json,os; d=json.load(sys.stdin); print(next((p['id'] for p in d if p.get('hostname')==os.uname().nodename), ''))" 2>/dev/null)
            GRP_ID=$(curl -s --max-time 20 "$NBAPI/groups" -H "Authorization: Bearer $PAT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
            if [ -n "$NET_ID" ] && [ -n "$PEER_ID" ] && [ -n "$GRP_ID" ]; then
              NBRC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$NBAPI/routes" \
                -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" \
                -d "{\"network\":\"${LAN_IP%.*}.0/24\",\"network_id\":\"$NET_ID\",\"description\":\"home network\",\"peer\":\"$PEER_ID\",\"enabled\":true,\"masquerade\":false,\"metric\":9999,\"groups\":[\"$GRP_ID\"]}")
            fi
            if [ "$NBRC" = "200" ]; then
              dbg "OK: home network announced"
            else
              dbg "home network route not announced (net=$NET_ID peer=$PEER_ID group=$GRP_ID http=$NBRC), phone on LAN"
            fi
          fi
          # The phone reaches the https edge through the mesh ip, so re-render the
          # edge config so the cert also covers it. default_sni stays on the LAN ip:
          # SNI-less clients (curl, browsers hitting a literal IP) are local and
          # must get the LAN cert, or the SAN mismatch paints every local browser
          # "not secure". Phones send SNI and get the mesh cert from the added
          # site address.
          # One-shot: only render when the mesh ip is not anchored yet, because
          # re-running the sed duplicates the site address on every tick and the
          # reload/restart churn keeps the edge bouncing.
          if [ -n "$NETBIRD_IP" ] && [ -f "$STACKDIR/local-caddy.Caddyfile" ]; then
            EDGE_BOUNCE=0
            sed -i -E "s|https://100\.[0-9.]+:([0-9]+)(, )?||g" "$STACKDIR/local-caddy.Caddyfile"
            if ! grep -q "https://$NETBIRD_IP:" "$STACKDIR/local-caddy.Caddyfile"; then
              sed -i "s|https://127.0.0.1:\([0-9][0-9]*\)|https://$NETBIRD_IP:\1, https://127.0.0.1:\1|g" "$STACKDIR/local-caddy.Caddyfile"
              EDGE_BOUNCE=1
            fi
            # Browsers send no SNI for IP literals, so caddy serves the
            # first address cert to every such request and the tiles
            # get a cert that names the wrong IP. One static cert with
            # every address in its SANs fixes all of them: no SNI
            # needed, every IP validates.
            if ! grep -q "tls /data/edge-chain.pem" "$STACKDIR/local-caddy.Caddyfile" \
               || [ ! -f /var/lib/redoubt/caddy-local/edge-chain.pem ] \
               || ! grep -q "$NETBIRD_IP" /var/lib/redoubt/caddy-local/edge-chain.pem \
                || ! grep -q "cdn.jsdelivr.net" /var/lib/redoubt/caddy-local/edge-chain.pem; then
              mint_edge_cert
            fi
            if [ "$EDGE_BOUNCE" = "1" ]; then
              if ! docker restart redoubt-edge-local-1 >/dev/null 2>&1; then
                docker restart redoubt-edge-local-1 >/dev/null 2>&1
              fi
              dbg "OK: edge serves one cert for every address (lan, mesh, localhost)"
            fi
          fi
        ;;
        *) echo "WARNING: host agent not connected yet, devices work on LAN (join: $UPERR)" ;;
      esac
    fi
  fi
fi


# 6c) Cloud mesh: the official agent joins NetBird's cloud with the
#     user's setup key. No coordinator, no ports, no tunnel of ours.
#     NetBird brokers the handshake; the phone works from any network.
if [ "$MESH_MODE" = "cloud" ]; then
  NBEXE=/usr/local/bin/netbird
  # The sign-in flow lives in the NetBird app, so the cloud needs the
  # tray and the window just as much as the selfhost does. The desktop
  # gets the deb plus the autostart and the immediate launch; the rest
  # of the families keep the CLI path.
  if [ "${HAS_GUI:-0}" = "1" ] && [ ! -x /usr/local/bin/netbird-ui ] && [ ! -x /usr/bin/netbird-ui ]; then
    # the deb depends on the netbird agent package, which cloud mode
    # never installs (the agent arrives as a tarball), so the deb can
    # never work here. The tarball carries the same UI with no dpkg
    # dependency chain; the toolkit libraries go in explicitly.
    if [ "$PKG_FAMILY" = "apt" ]; then
      apt-get install -y -qq libgtk-4-1 libwebkitgtk-6.0-4 xdg-utils >/dev/null 2>&1 || true
    elif [ "$PKG_FAMILY" = "pacman" ]; then
      pacman -S --noconfirm --needed gtk4 webkitgtk-6.0 >/dev/null 2>&1 || true
    elif [ "$PKG_FAMILY" = "dnf" ]; then
      dnf install -y gtk4 webkitgtk6.0 >/dev/null 2>&1 || true
    elif [ "$PKG_FAMILY" = "zypper" ]; then
      # the UI runtime on Tumbleweed: libwebkitgtk-6_0-4 carries the
      # libwebkitgtk-6.0.so.4 the binary links against
      zypper --non-interactive install libwebkitgtk-6_0-4 >/dev/null 2>&1 || true
    fi
    NBUITMP=$(mktemp -d /tmp/netbird-ui.XXXXXX)
    chmod 700 "$NBUITMP"
    NBUITGZ="$NBUITMP/netbird-ui-linux_${NBVER}_linux_amd64.tar.gz"
    if nb_fetch "netbird-ui-linux_${NBVER}_linux_amd64.tar.gz" "netbird-ui_${NBVER}_checksums.txt" "$NBUITMP" \
      && tar -xzf "$NBUITGZ" -C "$NBUITMP" netbird-ui \
      && install -m 755 "$NBUITMP/netbird-ui" /usr/local/bin/netbird-ui; then
      cat > /usr/share/applications/netbird-ui.desktop <<NBDESKTOP
[Desktop Entry]
Name=NetBird
Comment=Your mesh status and settings
Exec=/usr/local/bin/netbird-ui
Icon=network-vpn
Terminal=false
Type=Application
Categories=Network;
NBDESKTOP
      chmod 644 /usr/share/applications/netbird-ui.desktop
      mkdir -p /etc/xdg/autostart
      cat > /etc/xdg/autostart/netbird-ui.desktop <<NBDESK
[Desktop Entry]
Type=Application
Name=NetBird
Comment=Your mesh, in the tray
Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 /usr/local/bin/netbird-ui
Icon=netbird
Terminal=false
X-GNOME-Autostart-enabled=true
NBDESK
      chmod 644 /etc/xdg/autostart/netbird-ui.desktop
      dbg "OK: netbird-ui installed"
      echo "$NBVER" > /etc/redoubt/netbird-ui.version
      chmod 644 /etc/redoubt/netbird-ui.version
    fi
    rm -rf "$NBUITMP"
  fi
  # key-only: the cloud link never opens the NetBird app for a
  # sign-in; the tray copy stays quiet and the key flow does the work
  if [ ! -x "$NBEXE" ] || ! "$NBEXE" version 2>/dev/null | grep -q "$NBVER"; then
    # No fixed /tmp names a local user can symlink or race. Everything
    # lands in a private mktemp dir, same discipline as the selfhost
    # branch.
    NBTMP=$(mktemp -d /tmp/netbird-install.XXXXXX)
    chmod 700 "$NBTMP"
    NBTGZ="$NBTMP/netbird_${NBVER}_linux_amd64.tar.gz"
    if nb_fetch "netbird_${NBVER}_linux_amd64.tar.gz" "netbird_${NBVER}_checksums.txt" "$NBTMP" \
      && tar -xzf "$NBTGZ" -C "$NBTMP" netbird && install -m 755 "$NBTMP/netbird" "$NBEXE"; then
      dbg "OK: netbird agent $NBVER installed"
    else
      dbg "WARNING: netbird agent download failed, phone works on LAN"
    fi
    rm -rf "$NBTMP"
  fi
  # the GUI and the tray speak to the agent over its local socket, so
  # the service has to run and come back after a reboot (same
  # discipline as the selfhost branch)

  # the updater compares these records against the vendor release to
  # refresh the mesh pieces: write them honestly, they feed the update
  if [ -x "$NBEXE" ] && "$NBEXE" version 2>/dev/null | grep -q "$NBVER"; then
    echo "$NBVER" > /etc/redoubt/netbird.version
    chmod 644 /etc/redoubt/netbird.version
  fi
  if [ -x "$NBEXE" ] && [ ! -S /var/run/netbird.sock ]; then
    "$NBEXE" service install >/dev/null 2>&1 || true
    "$NBEXE" service start >/dev/null 2>&1 || true
    systemctl enable netbird >/dev/null 2>&1 || true
    dbg "OK: netbird service running"
  elif [ -x "$NBEXE" ] && [ ! -f /var/lib/netbird/default.json ]; then
    # daemon alive but its config was wiped (disk image, reset):
    # a restart rewrites the config; an up would just 500 on it
    systemctl restart netbird >/dev/null 2>&1 || true
    dbg "OK: netbird service restarted to rebuild its config"
  fi

  # a leftover unit from an old deb install keeps pointing at
  # /usr/bin/netbird while the cloud agent lives in /usr/local/bin:
  # the daemon then runs the stale binary and the GUI begs for an
  # update forever. Realign the unit to the active binary.
  if [ -x "$NBEXE" ]; then
    NB_UNIT_BIN=$(systemctl cat netbird 2>/dev/null | sed -n 's|^ExecStart=/\([^ ]*\) .*|/\1|p' | head -1)
    if [ -n "$NB_UNIT_BIN" ] && [ "$NB_UNIT_BIN" != "$NBEXE" ]; then
      "$NBEXE" service uninstall >/dev/null 2>&1 || true
      "$NBEXE" service install >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable netbird >/dev/null 2>&1 || true
      systemctl restart netbird >/dev/null 2>&1 || true
      dbg "OK: netbird service realigned to the active binary"
    fi
  fi

  if [ -x "$NBEXE" ]; then
    UP=$("$NBEXE" status 2>/dev/null | tr 'A-Z' 'a-z')
    # the daemon restarts during the pass and the status flickers: give
    # a linked machine a few seconds to settle before judging it
    for _UP_RETRY in 1 2 3; do
      printf '%s' "$UP" | grep -q 'netbird.cloud' && break
      sleep 3
      UP=$("$NBEXE" status 2>/dev/null | tr 'A-Z' 'a-z')
    done
    # cloud means NetBird's own network: an agent linked to a previous
    # local coordinator is not a cloud link and must re-join, or the
    # 'connected' state masks the machine forever on a dead local mesh
    if ! nb_cloud_linked; then
      # the stale state only gets wiped when a re-join can actually
      # follow: without a key (a re-run after the key was spent) the
      # wipe alone would unlink the machine with nothing to re-link it
      if [ -n "${NETBIRD_SETUP_KEY:-}" ]; then
        # a re-run on an already-linked cloud machine must never wipe
        # the owner's session: only an explicit link to the wrong
        # network (the local coordinator) is ground for the wipe. A
        # transient state without a known fqdn is left alone and the
        # wait below sorts it out.
        if printf '%s' "$UP" | grep -q 'netbird.selfhosted'; then
          "$NBEXE" down >/dev/null 2>&1 || true
          sleep 2
          # the saved state still points at the old local coordinator and
          # the daemon would re-join it on the next up: forget it so the
          # login below really hits the cloud
          systemctl stop netbird >/dev/null 2>&1 || true
          pkill -f '[n]etbird service' >/dev/null 2>&1 || true
          sleep 2
          rm -rf /var/lib/netbird
          rm -f /etc/netbird/config.json
          systemctl start netbird >/dev/null 2>&1 || true
          sleep 3
          UP=$("$NBEXE" status 2>/dev/null | tr 'A-Z' 'a-z')
        fi
      fi
      JOIN_WAIT=0
      if [ -n "${NETBIRD_SETUP_KEY:-}" ]; then
          join_cloud_with_key
        else
          # a desktop re-run lands here with none of the join flags set
          # and the agent already linked: stay quiet, the milestone line
          # below confirms the link. A real unlinked desktop gets the
          # app path instead of the dead-end text.
          if nb_cloud_linked; then
            :
          else
            dbg "cloud link stays off: no setup key landed on this pass (the reveal reports the LAN state)"
          fi
        fi
        if [ "$JOIN_WAIT" = "1" ]; then
          for i in $(seq 1 30); do
            UP=$("$NBEXE" status 2>/dev/null | tr 'A-Z' 'a-z')
            case "$UP" in *connected*) break ;; esac
            sleep 10
          done
        fi
        # a nameserver arm that failed on a past pass leaves a marker
        # behind: offer one retry right here on any later pass. The
        # The rerun menu skips the cloud question, so this is the only
        # place the retry can live: the ask inside cloud_key_flow is
        # dead code on reruns and the customer never gets a second
        # chance to arm the nameserver.
        if [ -f /etc/redoubt/mesh-ns-pending ]; then
          if [ -n "${ANIM_PID:-}" ]; then
            kill -9 "$ANIM_PID" 2>/dev/null || true
          fi
          printf '\r\033[K' >&3
          echo "Cloud link live, but the nameserver did not arm in the previous run" >&3 2>/dev/null || true
          echo "paste a fresh admin token to arm it now (it dies right after)" >&3 2>/dev/null || true
          read_cloud_key "Type your NetBird API token: "
          case "$_K" in
            *nbp_*)
              if nb_token_flow "$_K"; then
                arm_mesh_nameserver
              fi
              ;;
            *)
              echo "not a token - skipped (a later pass can retry the shield)" >&3 2>/dev/null || true
              ;;
          esac
          if [ -t 3 ]; then
            bar_anim &
            ANIM_PID=$!
          fi
        fi
    fi
    case "$UP" in
      *connected*)
        dbg "OK: host joined NetBird cloud"
        NETBIRD_IP=""
        for _NBT in $(seq 1 6); do
          NETBIRD_IP=$("$NBEXE" status 2>/dev/null | awk -F': ' '/^NetBird IP:/ {print $2; exit}' | cut -d/ -f1)
          case "$NETBIRD_IP" in *.*.*.*) break ;; esac
          sleep 2
        done
        if [ -n "$LAN_IP" ]; then
          "$NBEXE" routes add --network "${LAN_IP%.*}.0/24" --description "home network" >/dev/null 2>&1
          dbg "OK: home network announced"
        fi
        # the cloud side of the split-DNS: when the owner pasted a
        # PAT, publish redoubt.remote in their NetBird account so
        # every cloud phone resolves the name. Idempotent: existing
        # zones are refreshed, never duplicated.
        if [ -f /etc/redoubt/cloud-pat.txt ] && [ -n "$NETBIRD_IP" ]; then
          CPAT=$(cat /etc/redoubt/cloud-pat.txt)
          publish_remote_zone "https://api.netbird.io" "Authorization: Token $CPAT" "cloud"
        fi
        if [ -n "$NETBIRD_IP" ] && [ -f "$STACKDIR/local-caddy.Caddyfile" ]; then
          sed -i -E "s|https://100\.[0-9.]+:([0-9]+)(, )?||g" "$STACKDIR/local-caddy.Caddyfile"
          if ! grep -q "https://$NETBIRD_IP:" "$STACKDIR/local-caddy.Caddyfile"; then
            sed -i "s|https://127.0.0.1:\([0-9][0-9]*\)|https://$NETBIRD_IP:\1, https://127.0.0.1:\1|g" "$STACKDIR/local-caddy.Caddyfile"
          fi
          if ! grep -q "tls /data/edge-chain.pem" "$STACKDIR/local-caddy.Caddyfile" \
             || [ ! -f /var/lib/redoubt/caddy-local/edge-chain.pem ] \
             || ! grep -q "$NETBIRD_IP" /var/lib/redoubt/caddy-local/edge-chain.pem \
                || ! grep -q "cdn.jsdelivr.net" /var/lib/redoubt/caddy-local/edge-chain.pem; then
            mint_edge_cert
            if ! docker restart redoubt-edge-local-1 >/dev/null 2>&1; then
              docker restart redoubt-edge-local-1 >/dev/null 2>&1
            fi
            dbg "OK: edge serves one cert for every address (lan, mesh, localhost)"
          fi
        fi
      ;;
      *) echo "WARNING: the cloud link is not up yet${NBUPE:+ (join: $NBUPE)}; devices work on LAN" ;;
    esac
  fi
fi

# 7) Health checks, with retries. Services take a while to warm up.
# The pre-flight runs first: a root.crt directory (left by a crashed
# caddy) kills the edge with "is a directory" and the three https checks
# would fail without this pre-flight. Remove it and restart the edge;
# caddy regenerates the CA as real files.
CA_CRT_PRE=/var/lib/redoubt/caddy-local/caddy/pki/authorities/local/root.crt
if [ -d "$CA_CRT_PRE" ]; then
  echo "root.crt is a directory (crashed caddy leftover); removing and restarting the edge" >> "$LOG"
  rm -rf "$CA_CRT_PRE"
  docker restart redoubt-edge-local-1 >> "$LOG" 2>&1 || true
  sleep 8
fi
step "waking up containers"
# the management api answers 401 on /api/peers without a token: that
# auth wall IS the api alive. Older releases exposed /api/health,
# v0.8x does not (plain 404), so this probe targets the real route.
check_netbird() {
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT_NETBIRD/api/peers" 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then
      _ANS="  ${EM2}netbird answered (api alive, auth wall up)"$'\033[0m'
      log "$_ANS"
      return 0
    fi
    sleep 4
  done
  printf "  ${ERR}FAIL: netbird not responding\033[0m\n" >&3
  return 1
}

check_http() {
  local url=$1 name=$2
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$url" 2>/dev/null)
    # Any http code means the service answered; 200/302/401/405 all count.
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      _ANS="  ${EM2}$name answered (http $code)"$'\033[0m'
      log "$_ANS"
      return 0
    fi
    sleep 4
  done
  printf "  ${ERR}FAIL: %s not responding\033[0m\n" "$name" >&3
  return 1
}
RC=0
# Warm-up checks run in parallel. Serial, three services each retrying
# for up to two minutes would eat six minutes of the install. Each
# service reports the moment it answers, so the user watches them land
# one by one instead of staring at a silent bar.
check_http $PORT_IMMICH/api/server/ping immich & P1=$!
check_http $PORT_NEXTCLOUD nextcloud & P2=$!
check_http $PORT_SEARXNG searxng & P3=$!
if [ "$MESH_MODE" = "selfhost" ]; then
  check_netbird & P4=$!
else
  P4=""
fi
wait $P1 2>/dev/null; [ $? -eq 0 ] || RC=1
wait $P2 2>/dev/null; [ $? -eq 0 ] || RC=1
wait $P3 2>/dev/null; [ $? -eq 0 ] || RC=1
[ -n "$P4" ] && { wait $P4 2>/dev/null; [ $? -eq 0 ] || RC=1; }
# The edge-local caddy answers on the chosen ports. This is the phone's path.
check_edge() {
  local port=$1 path=$2 name=$3
  for i in $(seq 1 20); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:$port$path" 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      _ANS="  ${EM2}$name answered (https $code)"$'\033[0m'
      log "$_ANS"
      return 0
    fi
    sleep 4
  done
  printf "  ${ERR}FAIL: %s not responding over HTTPS\033[0m\n" "$name" >&3
  return 1
}
  check_edge $PORT_EDGE1 /api/server/ping immich-edge & E1=$!
  check_edge $PORT_EDGE2 / nextcloud-edge & E2=$!
  check_edge $PORT_EDGE3 /search?q=test searxng-edge & E3=$!
  wait $E1 2>/dev/null || true
  wait $E2 2>/dev/null || true
  wait $E3 2>/dev/null || true

[ $RC -eq 0 ] && step "stack healthy" && echo "OK: redoubt v1 complete on $ID ${VERSION_ID:-rolling}, stack alive" >> "$LOG" || { echo "FAIL: incomplete stack (see $LOG)" >&3; }
# the ad shield proves itself with a LOCAL query (redoubt.lan lives
# in its own records): no internet needed, so the verdict never lies
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx redoubt-pihole-1; then
  if docker exec redoubt-pihole-1 sh -c 'nslookup redoubt.lan 127.0.0.1 >/dev/null 2>&1'; then
    dbg "OK: ad shield answering (pi-hole over the private resolver)"
  else
    dbg "WARN: ad shield is up but did not answer a test query (see the log)"
  fi
else
  dbg "WARN: ad shield container is not running"
fi
# pi-hole v6 ships without a gravity db until the first update: run one
# so the blocklists and the UI domain list actually exist (the container
# does not run gravity on its own)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx redoubt-pihole-1; then
  if ! docker exec redoubt-pihole-1 sh -c '[ -f /etc/pihole/gravity.db ]' 2>/dev/null; then
    docker exec redoubt-pihole-1 pihole -g >/dev/null 2>&1 || true
    dbg "ad shield gravity ran (first blocklist build)"
  fi
fi
# v6 keeps the blocklists in gravity.db, not in the adlists file (that
# one only migrates once). The image ships with StevenBlack alone,
# which leaves whole ad networks open: the kit adds OISD Big on every
# install, plus the strict extra (1Hosts Xtra, ~1.5M domains) when
# REDOUBT_ADLIST=strict asks for it. Idempotent: each list is checked
# before it is written, so re-passes never duplicate rows. The db is
# reached from the host through the named volume because the container
# image does not ship sqlite3.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx redoubt-pihole-1; then
  _ADL_CHANGED=0
  for _ADL in "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts|StevenBlack" "https://big.oisd.nl/|OISD Big"; do
    _ADL_URL="${_ADL%%|*}"; _ADL_NAME="${_ADL##*|}"
    python3 -c "
import sqlite3
c = sqlite3.connect('/var/lib/docker/volumes/redoubt_pihole-data/_data/gravity.db')
if c.execute('SELECT COUNT(*) FROM adlist WHERE address = ?', ('$_ADL_URL',)).fetchone()[0] == 0:
    c.execute('INSERT INTO adlist (address, enabled, comment) VALUES (?, 1, ?)', ('$_ADL_URL', '$_ADL_NAME'))
    c.commit()
    print('added')
" 2>/dev/null | grep -q added && _ADL_CHANGED=1
  done
  if [ "${REDOUBT_ADLIST:-}" = "strict" ]; then
    python3 -c "
import sqlite3
c = sqlite3.connect('/var/lib/docker/volumes/redoubt_pihole-data/_data/gravity.db')
if c.execute('SELECT COUNT(*) FROM adlist WHERE address = ?', ('https://badmojr.github.io/1Hosts/Xtra/hosts.txt',)).fetchone()[0] == 0:
    c.execute('INSERT INTO adlist (address, enabled, comment) VALUES (?, 1, ?)', ('https://badmojr.github.io/1Hosts/Xtra/hosts.txt', '1Hosts Xtra'))
    c.commit()
    print('added')
" 2>/dev/null | grep -q added && _ADL_CHANGED=1
    dbg "strict adlists on (1Hosts Xtra): the shield holds ~1.5M domains, more RAM"
  fi
  if [ "$_ADL_CHANGED" = "1" ]; then
    docker exec redoubt-pihole-1 pihole -g >/dev/null 2>&1 || true
    _ADL_N=$(python3 -c "
import sqlite3
c = sqlite3.connect('/var/lib/docker/volumes/redoubt_pihole-data/_data/gravity.db')
print(c.execute('SELECT COUNT(*) FROM adlist').fetchone()[0])
" 2>/dev/null | tr -cd '0-9')
    dbg "ad shield blocklists loaded: ${_ADL_N:-?}${REDOUBT_ADLIST:+ (strict)}"
  fi
fi

#    Create the Immich admin account (the loop retries while immich warms up).
for i in $(seq 1 20); do
  R=$(curl -s --max-time 5 -X POST "http://127.0.0.1:$PORT_IMMICH/api/auth/admin-sign-up" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$IMMICH_EMAIL\",\"password\":\"$IMMICH_PASS\",\"name\":\"Owner\"}" 2>/dev/null)
  case "$R" in
    *accessToken*|*"created"*) echo "OK: immich admin created"; break ;;
    *already*)
      # an admin from an older pass keeps its own password: align it
      # with the single vault so every app opens with Access.txt
      # (the change endpoint is authenticated: login first, then
      # change with the bearer token)
      ALIGN_TOKEN=$(curl -s --max-time 10 -X POST "http://127.0.0.1:$PORT_IMMICH/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$IMMICH_EMAIL\",\"password\":\"$IMMICH_PASS\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get(\"accessToken\",\"\"))" 2>/dev/null)
      if [ -n "$ALIGN_TOKEN" ]; then
        ALIGN=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "http://127.0.0.1:$PORT_IMMICH/api/auth/change-password" \
          -H "Authorization: Bearer $ALIGN_TOKEN" -H "Content-Type: application/json" \
          -d "{\"password\":\"$IMMICH_PASS\",\"newPassword\":\"$OWNER_PASS\"}")
      else
        ALIGN=401
      fi
      [ "$ALIGN" = "200" ] && echo "OK: immich admin aligned with the single vault" || echo "OK: immich admin already set"
      break ;;
  esac
  sleep 3
done

#    Customer credentials: a 600 file and on screen.
if [ "$MESH_MODE" = "selfhost" ]; then
  PHONE_LINE="same wifi only (this mesh is home-only by choice)"
else
  PHONE_LINE="NetBird cloud (sign in on the device with your NetBird account)"
fi
if [ "$MESH_MODE" = "selfhost" ]; then
  PANEL_LINE=" | https://$LAN_IP:$PORT_EDGE4 (panel)"
else
  PANEL_LINE=""
fi
cat > /etc/redoubt/credentials.txt <<EOF
REDOUBT: your credentials (this file is the key to your cloud; keep it somewhere safe)
user: $OWNER_USER
pass: $OWNER_PASS
on this machine: https://127.0.0.1:$PORT_EDGE1 (photos) | https://127.0.0.1:$PORT_EDGE2 (files) | https://127.0.0.1:$PORT_EDGE3 (search)$PANEL_LINE | http://127.0.0.1:$PORT_DOCKGE (stack manager)
on any device (same wifi): https://$LAN_IP:$PORT_EDGE1 (photos) | https://$LAN_IP:$PORT_EDGE2 (files) | https://$LAN_IP:$PORT_EDGE3 (search)
immich:  email $IMMICH_EMAIL | pass $OWNER_PASS
nextcloud: user $OWNER_USER | pass $OWNER_PASS
dockge:  user $OWNER_USER | pass $OWNER_PASS
pi-hole: user $OWNER_USER | pass $OWNER_PASS (https://redoubt.lan:$PORT_EDGE5/admin)
anywhere: $PHONE_LINE
EOF
chmod 600 /etc/redoubt/credentials.txt
echo ""
if [ "$REINSTALL" != "1" ]; then
  print_rule
  printf "${EM1}  YOUR CREDENTIALS (generated by the kit)${RESET}\n"
  printf '%b\n' "${EM2}  user: $OWNER_USER${RESET}"
  printf '%b\n' "${EM2}  password: $OWNER_PASS${RESET}"
  printf '%b\n' "${EM2}  immich (email): $IMMICH_EMAIL${RESET}"
  echo "  saved to: Documents/My Redoubt/Access.txt (read it anytime with: redoubt creds)"
  print_rule
else
  echo "credentials kept from your first install (vault: Documents/My Redoubt/Access.txt, read anytime with: redoubt creds)"
fi

# 8) Welcome: the folder, the guide, the QR codes and the panel seed,
#    generated for this
#     machine: one QR per app listing and one per service address (LAN IP
#     plus the edge ports the pre-flight chose), so a scanned code always
#     matches this install.
#    The homarr admin, the app tiles and the branding ride the same
#    welcome pass. The
# seed rides stdin (never the disk: the owner password is in it) and the
# container deletes it right after the run. The JS stays literal; the
# values travel as environment variables.
  # the install steps restarted the agent right before this section:
  # a slow reconnect leaves the 6b capture empty and the tiles plus
  # the welcome would fall back to LAN addresses. Re-read here.
  if [ -z "${NETBIRD_IP:-}" ]; then
    for _NBI in $(seq 1 10); do
      NETBIRD_IP=$("$NBEXE" status 2>/dev/null | awk -F': ' '/^NetBird IP:/ {print $2; exit}' | cut -d/ -f1)
      case "$NETBIRD_IP" in *.*.*.*) break ;; esac
      sleep 5
    done
    case "$NETBIRD_IP" in *.*.*.*) ;; *) NETBIRD_IP="" ;; esac
  fi
  # the tile host follows the mode: the pure selfhost NAS answers only
  # to the mesh, so the tiles carry the mesh name; cloud rides the
  # mesh from any network with the same remote name
  SEED_HOST="redoubt.remote"
  # the mesh console tile is selfhost-only: cloud keeps the four tiles
  SEED_CONSOLE=""
  [ "$MESH_MODE" = "selfhost" ] && SEED_CONSOLE="https://$SEED_HOST:$PORT_DASH"
  [ "$MESH_MODE" != "selfhost" ] && [ ! -f /etc/redoubt/cloud-pat.txt ] && SEED_HOST="${NETBIRD_IP:-$LAN_IP}"

  # the away side of the split-DNS: a mesh zone makes redoubt.lan
  # resolve to this machine mesh address on every joined device, so
  # the same tile links work from any network. Created once, refreshed
  # on every pass (the mesh address can move after a re-join).
  if [ -n "${PAT:-}" ] && [ -n "${NETBIRD_IP:-}" ]; then
    publish_remote_zone "http://127.0.0.1:$PORT_NETBIRD" "Authorization: Bearer $PAT" "mesh"
  fi
SEED_SECTIONS="full"
[ "$MESH_MODE" = "selfhost" ] && SEED_SECTIONS="minimal"
for _i in $(seq 1 60); do
  docker compose -f "$STACKDIR/docker-compose.yml" exec -T homarr sh -c 'test -f /appdata/db/db.sqlite' >/dev/null 2>&1 && break
  sleep 10
done
if docker compose -f "$STACKDIR/docker-compose.yml" exec -T homarr sh -c 'test -f /appdata/db/db.sqlite' >/dev/null 2>&1; then
  # the vault (Access.txt) is the truth the owner types. A re-run can
  # hold a divergent pass in the env (the panel user then drifts from
  # the vault), so the seed always hashes the vault pass
  _SEED_PASS="$OWNER_PASS"
  _VAULT_PASS=$(awk -F': ' '/^[[:space:]]*pass:/ {print $2; exit}' "$MYREDOUBT/Access.txt" 2>/dev/null || true)
  [ -n "$_VAULT_PASS" ] && _SEED_PASS="$_VAULT_PASS"
  SEED_OUT=$(docker compose -f "$STACKDIR/docker-compose.yml" exec -T \
    -e SEED_USER="$OWNER_USER" -e SEED_EMAIL="$IMMICH_EMAIL" -e SEED_PASS="$_SEED_PASS" -e SEED_SECTIONS="$SEED_SECTIONS" \
    -e SEED_PHOTOS="https://${SEED_HOST}:$PORT_EDGE1" -e SEED_FILES="https://${SEED_HOST}:$PORT_EDGE2" -e SEED_SEARCH="https://${SEED_HOST}:$PORT_EDGE3" -e SEED_PIHOLE="https://${SEED_HOST}:$PORT_EDGE5/admin" -e SEED_WHEREAMI="/whereami" -e SEED_CONSOLE="$SEED_CONSOLE" \
    homarr sh -c 'cat > /appdata/seed.js; node /appdata/seed.js; rc=$?; rm -f /appdata/seed.js; exit $rc' <<'SEEDJS'
// Redoubt panel seed: writes the admin, the app tiles and the finished
// onboarding state, mirroring the wizard's own database writes. Runs
// inside the homarr container with its own native modules only.
(function () {
  "use strict";
  var fs = require("fs");
  var dbPath = "/appdata/db/db.sqlite";
  if (!fs.existsSync(dbPath)) { console.error("homarr db not ready"); process.exit(2); }
  var Database;
  try {
    Database = require("/app/node_modules/better-sqlite3");
  } catch (err) {
    try { Database = require("/app/build/better_sqlite3.node"); }
    catch (err2) { console.error("sqlite binding missing: " + err2.message); process.exit(2); }
  }
  var bcrypt;
  try { bcrypt = require("/app/node_modules/bcrypt"); }
  catch (err) { console.error("bcrypt missing: " + err.message); process.exit(2); }
  var db = new Database(dbPath);
  db.pragma("busy_timeout = 15000");

  var USERNAME = process.env.SEED_USER || "owner";
  var EMAIL = process.env.SEED_EMAIL || "owner@redoubt.local";
  var PASSWORD = process.env.SEED_PASS || "";
  var APPS = [
    { id: "redoubt-app-photos", name: "Photos", icon: "/icons/immich.svg",
      href: process.env.SEED_PHOTOS, ping: "http://immich-server:2283" },
    { id: "redoubt-app-files", name: "Files", icon: "/icons/nextcloud.svg",
      href: process.env.SEED_FILES, ping: "http://nextcloud:80" },
    { id: "redoubt-app-search", name: "Search", icon: "/icons/searxng.svg",
      href: process.env.SEED_SEARCH, ping: "http://searxng:8080" },
    { id: "redoubt-app-pihole", name: "Pi-hole", icon: "/icons/pihole.svg",
      href: process.env.SEED_PIHOLE, ping: "http://pihole:80" }
  ];
  // the mesh console tile only lands on selfhost boards: cloud has no
  // local dashboard, so its panel keeps the four app tiles
  if (process.env.SEED_CONSOLE) {
    // the icon rides the jsdelivr mirror the kit keeps on the box:
    // homarr's own icon catalog predates netbird and 404s /icons/netbird
    APPS.push({ id: "redoubt-app-console", name: "Mesh console",
      icon: "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@main/svg/netbird.svg",
      href: process.env.SEED_CONSOLE, ping: "http://dashboard:80" });
  }

  var uuid = function () {
    var out = "";
    for (var i = 0; i < 32; i++) {
      out += Math.floor(Math.random() * 16).toString(16);
    }
    return out;
  };

  var userCount = db.prepare('SELECT COUNT(*) AS c FROM "user"').get().c;
  var hash = bcrypt.hashSync(PASSWORD, 10);
  var uid;
  if (userCount === 0) {
    uid = uuid();
    db.prepare('INSERT INTO "user" (id, name, email, password) VALUES (?, ?, ?, ?)')
      .run(uid, USERNAME, EMAIL, hash);
    var gid = uuid();
    db.prepare('INSERT INTO "group" (id, name, owner_id, position) VALUES (?, ?, ?, ?)')
      .run(gid, "credentials-admin", uid, 0);
    db.prepare("INSERT INTO groupPermission (group_id, permission) VALUES (?, ?)")
      .run(gid, "admin");
    db.prepare("INSERT INTO groupMember (group_id, user_id) VALUES (?, ?)")
      .run(gid, uid);
  } else {
    uid = db.prepare('SELECT id FROM "user" LIMIT 1').get().id;
    // a re-run can arrive with a divergent env pass while the vault
    // holds the truth the owner types: re-hash every pass so the
    // panel login always matches the vault
    db.prepare('UPDATE "user" SET password = ? WHERE id = ?').run(hash, uid);
  }

  // one clean board: reuse the one the first boot seeded, or create it.
  // This runs on every pass: later passes refresh the branding and the
  // tile addresses, so a board seeded by an older build heals here too.
  var board = db.prepare("SELECT id FROM board LIMIT 1").get();
  var boardId;
  if (board) {
    boardId = board.id;
    db.prepare("UPDATE board SET name = ?, creator_id = ?, primary_color = ?, secondary_color = ?, custom_css = ?, logo_image_url = ?, favicon_image_url = ?, meta_title = ? WHERE id = ?")
      .run("Redoubt", uid, "#6ee7b7", "#0f766e",
        "html, body { background: #000000 !important; } :root[data-mantine-color-scheme=\"dark\"], :root[data-mantine-color-scheme=\"light\"], [data-mantine-color-scheme=\"light\"] { --mantine-color-body: #000000 !important; --mantine-color-text: #e8ece9 !important; --mantine-color-dimmed: #8b949e !important; --mantine-color-placeholder: #6b6f75 !important; --mantine-color-anchor: #6ee7b7 !important; --mantine-color-default: #17181a !important; --mantine-color-default-border: #3d3a39 !important; --mantine-color-default-hover: #1f2023 !important; --mantine-color-default-color: #e8ece9 !important; --mantine-color-input: #17181a !important; --mantine-color-input-border: #3d3a39 !important; --mantine-color-gray-light: rgba(110,231,183,0.12) !important; --mantine-color-gray-light-hover: rgba(110,231,183,0.20) !important; --mantine-color-gray-light-color: #6ee7b7 !important; --mantine-color-gray-outline: #6ee7b7 !important; --mantine-color-gray-outline-hover: rgba(110,231,183,0.08) !important; --mantine-color-gray-filled: rgba(110,231,183,0.14) !important; --mantine-color-gray-filled-hover: rgba(110,231,183,0.24) !important; --mantine-color-gray-color: #6ee7b7 !important; --mantine-color-dark-0: #c9c9c9 !important; --mantine-color-dark-1: #b8b8b8 !important; --mantine-color-dark-2: #8b949e !important; --mantine-color-dark-3: #6b6f75 !important; --mantine-color-dark-4: #3d3a39 !important; --mantine-color-dark-5: #2a2a2c !important; --mantine-color-dark-6: #17181a !important; --mantine-color-dark-7: #101012 !important; --mantine-color-dark-8: #0a0a0c !important; --mantine-color-dark-9: #000000 !important; } .mantine-Card-root, .mantine-Paper-root { background: #101012 !important; border: 1px solid #26262a; } .mantine-Card-root .mantine-Text-root:not(.app-title) { color: #6ee7b7; } .mantine-AppShell-main { background: transparent; } .mantine-UnstyledButton-root:hover { background: rgba(110,231,183,0.08); } ::-webkit-scrollbar { width: 10px; height: 10px; } ::-webkit-scrollbar-thumb { background: #26262a; border-radius: 6px; } ::-webkit-scrollbar-thumb:hover { background: #3d3a39; } ::-webkit-scrollbar-track { background: transparent; }",
        "/logo.png", "/favicon.ico", "Redoubt", boardId);
  } else {
    boardId = uuid();
    db.prepare("INSERT INTO board (id, name, is_public) VALUES (?, ?, 0)").run(boardId, "Redoubt");
  }

  // the visible branding lives in the serverSetting 'branding' row: the
  // app name, logo, favicon and the palette the UI actually paints. The
  // board's color columns are legacy and the UI ignores them.
  var branding = {
    json: {
      appName: "Redoubt",
      greeting: "",
      logoImageUrl: "/logo.png",
      faviconImageUrl: "/favicon.ico",
      primaryColor: "#6ee7b7",
      secondaryColor: "#0f766e",
      lockPrimaryColor: false,
      signInBackgroundImageUrl: null,
      signInBackgroundOverlay: 0.55,
      authBranding: { showAppName: true, showLogo: true, showGreeting: true },
      defaultRadius: "md"
    }
  };
  db.prepare("INSERT INTO serverSetting (setting_key, value) VALUES ('appearance', ?) ON CONFLICT(setting_key) DO UPDATE SET value = excluded.value")
    .run(JSON.stringify({ json: { defaultColorScheme: "dark" } }));
  db.prepare("INSERT INTO serverSetting (setting_key, value) VALUES ('branding', ?) ON CONFLICT(setting_key) DO UPDATE SET value = excluded.value")
    .run(JSON.stringify(branding));
  // homarr's telemetry: the first boot leaves general analytics enabled.
  // The seed pins it off on every pass.
  db.prepare("INSERT INTO serverSetting (setting_key, value) VALUES ('analytics', ?) ON CONFLICT(setting_key) DO UPDATE SET value = excluded.value")
    .run(JSON.stringify({ json: { enableGeneral: false } }));
  db.prepare('UPDATE "user" SET image = ? WHERE id = ?').run("/logo.png", uid);

  var section = db.prepare("SELECT id FROM section WHERE board_id = ? AND kind = 'empty' LIMIT 1").get(boardId);
  if (!section) {
    var sid = uuid();
    db.prepare("INSERT INTO section (id, board_id, kind, x_offset, y_offset) VALUES (?, ?, 'empty', 0, 0)")
      .run(sid, boardId);
    section = { id: sid };
    // selfhost boards keep one section: the wizard Home and Wifi
    // categories are clutter there, a single "Your Apps" section is
    // all the reveal needs. Cloud boards keep the wizard sections.
    if (process.env.SEED_SECTIONS === "minimal") {
      db.prepare("DELETE FROM section WHERE board_id = ? AND id != ?").run(boardId, section.id);
      var sectionCols = db.prepare("PRAGMA table_info(section)").all().map(function (c) { return c.name; });
      if (sectionCols.indexOf("name") !== -1) {
        db.prepare("UPDATE section SET name = ? WHERE id = ?").run("Your Apps", section.id);
      }
    }
  }
  var layouts = db.prepare("SELECT id, column_count AS cols FROM layout WHERE board_id = ?").all(boardId);
  if (layouts.length === 0) {
    var mid = uuid();
    var bid = uuid();
    db.prepare("INSERT INTO layout (id, name, board_id, column_count, breakpoint, role) VALUES (?, 'Mobile', ?, 3, 0, 'mobile')")
      .run(mid, boardId);
    db.prepare("INSERT INTO layout (id, name, board_id, column_count, breakpoint, role) VALUES (?, 'Base', ?, 10, 768, 'base')")
      .run(bid, boardId);
    layouts = [{ id: mid, cols: 3 }, { id: bid, cols: 10 }];
  }

  // drop the demo tiles, bookmark apps and default integrations the first
  // boot seeded, then lay down the three Redoubt tiles
  db.prepare("DELETE FROM item_layout WHERE item_id IN (SELECT id FROM item WHERE board_id = ?)").run(boardId);
  db.prepare("DELETE FROM integration_item WHERE item_id IN (SELECT id FROM item WHERE board_id = ?)").run(boardId);
  db.prepare("DELETE FROM item WHERE board_id = ?").run(boardId);
  db.prepare("DELETE FROM integrationSecret").run();
  db.prepare("DELETE FROM integration_item").run();
  db.prepare("DELETE FROM integration").run();
  db.prepare("DELETE FROM app").run();

  var extras = [
    { kind: "clock", opts: {} },
    { kind: "weather", opts: { showHumidity: false, showCity: false, hasForecast: false } },
    { kind: "bookmarks", opts: { title: "Useful Links", layout: "grid", openNewTab: true } },
    { kind: "iframe", opts: { embedUrl: process.env.SEED_WHEREAMI } }
  ];
  var extraItems = [];
  for (var e = 0; e < extras.length; e++) {
    var eid = uuid();
    db.prepare("INSERT INTO item (id, board_id, kind, options, advanced_options) VALUES (?, ?, ?, ?, ?)")
      .run(eid, boardId, extras[e].kind, JSON.stringify({ json: extras[e].opts }), '{"json": {}}');
    extraItems.push(eid);
  }
  // desktop (10 columns): clock spans four under the apps, weather two,
  // bookmarks four and two rows tall
  var deskExtra = [
    { x: 0, y: 1, w: 4, h: 1 },
    { x: 0, y: 2, w: 2, h: 1 },
    { x: 0, y: 3, w: 4, h: 2 },
    { x: 2, y: 2, w: 2, h: 1 }
  ];
  // phones (3 columns): the tiles wrap into rows 0-1, the vitals take
  // rows 2-3, and the clock, weather, bookmarks and the connection
  // badge stack below
  var mobExtra = [
    { x: 0, y: 4, w: 2, h: 1 },
    { x: 2, y: 4, w: 1, h: 1 },
    { x: 0, y: 5, w: 2, h: 2 },
    { x: 2, y: 5, w: 1, h: 1 }
  ];
  for (var e = 0; e < extraItems.length; e++) {
    for (var l = 0; l < layouts.length; l++) {
      var pos = layouts[l].cols === 3 ? mobExtra[e] : deskExtra[e];
      db.prepare("INSERT INTO item_layout (item_id, section_id, layout_id, x_offset, y_offset, width, height) VALUES (?, ?, ?, ?, ?, ?, ?)")
        .run(extraItems[e], section.id, layouts[l].id, pos.x, pos.y, pos.w, pos.h);
    }
  }
  for (var i = 0; i < APPS.length; i++) {
    var app = APPS[i];
    // the upsert refreshes the whole row: an older build may have
    // seeded a tile with a stale icon (or the catalog-only path that
    // homarr's bundled icon list lacks), so href alone is not enough
    db.prepare("INSERT INTO app (id, name, icon_url, href, ping_url) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET href = excluded.href, icon_url = excluded.icon_url, ping_url = excluded.ping_url")
      .run(app.id, app.name, app.icon, app.href, app.ping);
    var itemId = uuid();
    var options = JSON.stringify({ json: { appId: app.id, openInNewTab: true, showTitle: true } });
    db.prepare("INSERT INTO item (id, board_id, kind, options, advanced_options) VALUES (?, ?, 'app', ?, ?)")
      .run(itemId, boardId, options, '{"json": {}}');
    for (var l = 0; l < layouts.length; l++) {
      // phones wrap the tiles: three per row, a fourth drops below
      var mobile = layouts[l].cols === 3;
      db.prepare("INSERT INTO item_layout (item_id, section_id, layout_id, x_offset, y_offset, width, height) VALUES (?, ?, ?, ?, ?, 1, 1)")
        .run(itemId, section.id, layouts[l].id, mobile ? i % 3 : i, mobile ? Math.floor(i / 3) : 0);
    }
  }

  // the machine's own vitals: the glances integration feeds the
  // system-health widget (cpu, ram, disk from the host). The widget
  // spans two columns, after the app tiles.
  var gli = uuid();
  db.prepare("INSERT INTO integration (id, name, url, kind, app_id) VALUES (?, ?, ?, ?, NULL)")
    .run(gli, "glances", "http://glances:61208", "glances");
  var healthItemId = uuid();
  // the widget resolves its data source from the integration ids in
  // its options: without them it renders nothing
  db.prepare("INSERT INTO item (id, board_id, kind, options, advanced_options) VALUES (?, ?, 'systemResources', ?, ?)")
    .run(healthItemId, boardId, JSON.stringify({ json: { integrationIds: [gli], visibleCharts: ["cpu", "memory", "disk", "network"] } }), '{"json": {}}');
  db.prepare("INSERT INTO integration_item (item_id, integration_id) VALUES (?, ?)")
    .run(healthItemId, gli);
  for (var l = 0; l < layouts.length; l++) {
    // phones have 3 columns: the vitals take the whole row. Desktop has
    // 10: the app tiles keep their three columns and the vitals span
    // the rest, two rows deep so the charts can breathe.
    var wide = layouts[l].cols === 3;
    // mobile: the tiles wrap into two rows, the vitals start below
    db.prepare("INSERT INTO item_layout (item_id, section_id, layout_id, x_offset, y_offset, width, height) VALUES (?, ?, ?, ?, ?, ?, 2)")
      .run(healthItemId, section.id, layouts[l].id, wide ? 0 : APPS.length, wide ? 2 : 0, wide ? 3 : 10 - APPS.length);
  }

  var boardSetting = db.prepare("SELECT value FROM serverSetting WHERE setting_key = 'board'").get();
  var boardValue = {};
  if (boardSetting && boardSetting.value) {
    try {
      var parsed = JSON.parse(boardSetting.value);
      if (parsed && parsed.json) { boardValue = parsed.json; }
    } catch (err) { }
  }
  boardValue.homeBoardId = boardId;
  boardValue.mobileHomeBoardId = boardId;
  db.prepare("INSERT INTO serverSetting (setting_key, value) VALUES ('board', ?) ON CONFLICT(setting_key) DO UPDATE SET value = excluded.value")
    .run(JSON.stringify({ json: boardValue }));
  db.prepare('UPDATE "group" SET home_board_id = ?, mobile_home_board_id = ? WHERE name = ?')
    .run(boardId, boardId, "everyone");
  db.prepare('UPDATE "user" SET home_board_id = ?, mobile_home_board_id = ? WHERE id = ?')
    .run(boardId, boardId, uid);

  // the wizard rows are per device: mark every seen row finished
  // instead of deleting, so a pass never re-arms the wizard for a
  // device that already walked it
  db.prepare("UPDATE onboarding SET step = 'finish' WHERE step != 'finish'").run();
  console.log("homarr seed: done");
})();
SEEDJS
  )
  if printf '%s' "$SEED_OUT" | grep -qE "homarr seed: done"; then
    dbg "OK: panel seeded (admin, tiles, branding)"
  else
    dbg "WARN: panel seed returned unexpected output: $(printf '%s' "$SEED_OUT" | tail -2)"
  fi
  # one bounce so the panel serves the fresh database state
  docker compose -f "$STACKDIR/docker-compose.yml" restart homarr >/dev/null 2>&1 || true
else
  dbg "WARN: panel database did not appear, the seed is skipped (re-run the kit to retry)"
fi

# download + sha verify one icon tarball from the release edge into the
# local mirror; the .done marker makes later passes skip it. A failure
# leaves that set missing (the mirror just serves what it has) and the
# next kit run retries.
fetch_icon_set() {
  _ICON_NAME=$1; _ICON_URL=$2; _ICON_SHA=$3; _ICON_DEST=$4; _ICON_MAX=$5
  if [ -f "/etc/redoubt/icons-${_ICON_NAME}.done" ]; then
    return 0
  fi
  _ICON_OK=0
  for _TRY in 1 2 3; do
    if curl -fsSL --max-time "$_ICON_MAX" -o "/tmp/icons-${_ICON_NAME}.tar.gz" "$_ICON_URL" 2>/dev/null \
       && [ "$(sha256sum "/tmp/icons-${_ICON_NAME}.tar.gz" 2>/dev/null | cut -d' ' -f1)" = "$_ICON_SHA" ]; then
      _ICON_OK=1; break
    fi
    sleep 5
  done
  if [ "$_ICON_OK" = "1" ]; then
    mkdir -p "$_ICON_DEST"
    tar -xzf "/tmp/icons-${_ICON_NAME}.tar.gz" -C "$_ICON_DEST"
    touch "/etc/redoubt/icons-${_ICON_NAME}.done"
    chmod 600 "/etc/redoubt/icons-${_ICON_NAME}.done"
    dbg "OK: ${_ICON_NAME} icon set ready (offline, from the release edge)"
  else
    dbg "WARN: the ${_ICON_NAME} icon set did not download (re-run the kit to retry)"
  fi
  rm -f "/tmp/icons-${_ICON_NAME}.tar.gz"
}


if [ "${REDOUBT_WELCOME:-1}" = "1" ]; then
  # the panel branding and the default tile icons ship as one tarball
  # from the release edge (sha verified) and land in the edge share,
  # so the dashboard never fetches a third-party CDN at runtime. A
  # resume pass re-drops them on every run.
  fetch_icon_set "defaults" \
    "https://install.tryredoubt.com/install/icons-defaults.tar.gz" \
    "94262443ca5d3b537847bc8bf2acae6484ed55c4127ea72530f5db6c0e156707" \
    "/var/lib/redoubt/caddy-local" \
    "120"
  fetch_icon_set "catalog" \
    "https://install.tryredoubt.com/install/icons-svg.tar.gz" \
    "1c50ba60d73660dce3eb97f1f99815df44033b01f44349aee2f282611565caa2" \
    "/var/lib/redoubt/caddy-local/cdn/gh/homarr-labs/dashboard-icons" \
    "600"
  fetch_icon_set "png" \
    "https://install.tryredoubt.com/install/icons-png.tar.gz" \
    "62fe3de3c0063620439024de5eab6b3e3351a21e248cf780e49c21dd42252b18" \
    "/var/lib/redoubt/caddy-local/cdn/gh/homarr-labs/dashboard-icons" \
    "900"
  fetch_icon_set "papirus" \
    "https://install.tryredoubt.com/install/icons-papirus.tar.gz" \
    "ae31da5b72e37928e394eb7ba3f436617c96ff6f5fc5963512dad33d945e53a5" \
    "/var/lib/redoubt/caddy-local/cdn/gh/PapirusDevelopmentTeam/papirus_icons" \
    "600"
  dbg "OK: icon mirror counts: $(find /var/lib/redoubt/caddy-local/cdn -type f -name '*.png' 2>/dev/null | wc -l) png, $(find /var/lib/redoubt/caddy-local/cdn -type f -name '*.svg' 2>/dev/null | wc -l) svg"
  chmod 644 /var/lib/redoubt/caddy-local/logo.png /var/lib/redoubt/caddy-local/favicon.ico /var/lib/redoubt/caddy-local/icons/*.svg
  chmod 755 /var/lib/redoubt/caddy-local /var/lib/redoubt/caddy-local/icons
  chmod 755 /var/lib/redoubt

  # the panel icons point at cdn.jsdelivr.net, which only resolves to
  # this box through the LOCAL resolver. A phone on the mesh uses its
  # own DNS, so those hardcoded CDN urls would hit the real internet -
  # dead on a mesh that carries no internet. Re-map every icon to the
  # panel's own /icons path: same host as the page itself, so the set
  # works on home wifi AND over the mesh with zero DNS games.
  # The remap lives in a standalone script: the pass runs it now, and
  # a delayed timer re-runs it a few times after the install, catching
  # the icons Homarr registers lazily on the customer's first board
  # load. Idempotent and self-stopping.
  cat > /etc/redoubt/redoubt-icon-fix.sh <<'ICONFIX'
#!/bin/bash
ICON_DB="/var/lib/docker/volumes/redoubt_homarr-data/_data/db/db.sqlite"
[ -f "$ICON_DB" ] || exit 0
N_ICONS=$(python3 - "$ICON_DB" <<'PYICON'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
n = db.execute("UPDATE icon SET url = '/cdn/gh/homarr-labs/dashboard-icons' || substr(url, instr(url, '/png/')) WHERE url LIKE 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/%'").rowcount
n += db.execute("UPDATE icon SET url = '/cdn/gh/homarr-labs/dashboard-icons' || substr(url, instr(url, '/svg/')) WHERE url LIKE 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/%'").rowcount
n += db.execute("UPDATE icon SET url = '/cdn/gh/homarr-labs/dashboard-icons' || substr(url, instr(url, '/web/')) WHERE url LIKE 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/web/%'").rowcount
n += db.execute("UPDATE icon SET url = '/cdn/gh/homarr-labs/dashboard-icons' || substr(url, instr(url, '/plugins/')) WHERE url LIKE 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/plugins/%'").rowcount
n += db.execute("UPDATE icon SET url = '/cdn/gh/selfhst/icons' || substr(url, instr(url, '/png/')) WHERE url LIKE 'https://cdn.jsdelivr.net/gh/selfhst/icons/png/%'").rowcount
n += db.execute("UPDATE icon SET url = '/cdn/gh/selfhst/icons' || substr(url, instr(url, '/svg/')) WHERE url LIKE 'https://cdn.jsdelivr.net/gh/selfhst/icons/svg/%'").rowcount
n += db.execute("UPDATE icon SET url = '/cdn/simpleicons/' || substr(url, 27) || '.svg' WHERE url LIKE 'https://cdn.simpleicons.org/%'").rowcount
db.execute("UPDATE icon SET url = replace(url, '/cdn/simpleicons/g/', '/cdn/simpleicons/') WHERE url LIKE '/cdn/simpleicons/g/%'")
db.commit()
db.close()
print(n)
PYICON
)
echo "$N_ICONS"
CNT=/etc/redoubt/.icon-fix-runs
R=0; [ -f "$CNT" ] && R=$(cat "$CNT" 2>/dev/null || echo 0)
R=$((R+1)); echo "$R" > "$CNT"
# a handful of runs covers the first board load; then the timer retires
[ "$R" -ge 5 ] && systemctl disable --now redoubt-icon-fix.timer >/dev/null 2>&1
exit 0
ICONFIX
  chmod 755 /etc/redoubt/redoubt-icon-fix.sh
  cat > /etc/systemd/system/redoubt-icon-fix.service <<'ICNSVC'
[Unit]
Description=Redoubt panel icon url remap (local edge paths)
After=docker.service

[Service]
Type=oneshot
ExecStart=/etc/redoubt/redoubt-icon-fix.sh
ICNSVC
  cat > /etc/systemd/system/redoubt-icon-fix.timer <<'ICNTMR'
[Unit]
Description=Delayed panel icon remap (Homarr registers icons lazily)

[Timer]
OnBootSec=8min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
ICNTMR
  chmod 644 /etc/systemd/system/redoubt-icon-fix.service /etc/systemd/system/redoubt-icon-fix.timer
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now redoubt-icon-fix.timer >/dev/null 2>&1 || true
  if [ -f "/var/lib/docker/volumes/redoubt_homarr-data/_data/db/db.sqlite" ]; then
    N_ICONS=$(/etc/redoubt/redoubt-icon-fix.sh)
    dbg "OK: $N_ICONS panel icon urls remapped to the local edge (mesh-safe)"
  fi

  # trivy: the stack's security scanner. It audits every container
  # image against the public CVE feeds and the compose file for
  # misconfigs and leaked secrets, then drops a readable report in the
  # scan dir. The binary comes from the upstream GitHub release (sha
  # pinned); the scan itself runs weekly through a systemd timer and
  # once shortly after the first boot. Read-only: it never touches the
  # running containers.
  TRIVY_SHA="c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0"
  if [ ! -x /opt/redoubt/bin/trivy ]; then
    mkdir -p /opt/redoubt/bin
    if curl -fsSL --max-time 600 -o /tmp/trivy.tar.gz "https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-64bit.tar.gz" 2>/dev/null \
       && [ "$(sha256sum /tmp/trivy.tar.gz 2>/dev/null | cut -d' ' -f1)" = "$TRIVY_SHA" ]; then
      tar -xzf /tmp/trivy.tar.gz -C /opt/redoubt/bin trivy
      chmod 755 /opt/redoubt/bin/trivy
      dbg "OK: trivy scanner installed (sha verified, upstream release)"
    else
      dbg "WARN: trivy did not download (the weekly scan stays off; re-run the kit to retry)"
    fi
    rm -f /tmp/trivy.tar.gz
  fi
  cat > /etc/redoubt/redoubt-scan.sh <<'SCAN'
#!/usr/bin/env bash
# weekly stack scan: every running image against the CVE feeds plus the
# compose file for misconfigs. Read-only; writes only the report files.
set -u
TRIVY=/opt/redoubt/bin/trivy
OUT=/var/lib/redoubt/scan
CACHE=/var/lib/redoubt/trivy-cache
SUMMARY="$OUT/last-scan.txt"
RAW="$OUT/last-scan-full.txt"
mkdir -p "$OUT" "$CACHE"
[ -x "$TRIVY" ] || exit 0
IMAGES=$(docker ps --format '{{.Image}}' 2>/dev/null | sort -u)
[ -n "$IMAGES" ] || exit 0
DATE=$(date '+%Y-%m-%d %H:%M %Z')
TOTAL_C=0
TOTAL_H=0
{
  echo "Redoubt stack scan - $DATE"
  echo "------------------------------------"
  for IMG in $IMAGES; do
    REPORT=$("$TRIVY" image --severity CRITICAL,HIGH --no-progress --cache-dir "$CACHE" --format json "$IMG" 2>/dev/null)
    C=$(printf '%s' "$REPORT" | grep -oE '"Severity": ?"CRITICAL"' | wc -l)
    H=$(printf '%s' "$REPORT" | grep -oE '"Severity": ?"HIGH"' | wc -l)
    TOTAL_C=$((TOTAL_C + C))
    TOTAL_H=$((TOTAL_H + H))
    printf '%-36s %s CRITICAL / %s HIGH\n' "$IMG" "$C" "$H"
  done
  echo "------------------------------------"
  echo "TOTALS: $TOTAL_C CRITICAL / $TOTAL_H HIGH across $(echo "$IMAGES" | wc -l) images"
  echo "Detail: $RAW"
} > "$SUMMARY"
{
  for IMG in $IMAGES; do
    echo "==== $IMG"
    "$TRIVY" image --severity CRITICAL,HIGH --no-progress --cache-dir "$CACHE" --format table "$IMG" 2>/dev/null
  done
  echo "==== compose config"
  "$TRIVY" config --severity CRITICAL,HIGH --no-progress --quiet /opt/redoubt/docker-compose.yml 2>/dev/null
} > "$RAW"
chmod 644 "$SUMMARY" "$RAW"
exit 0
SCAN
  chmod 755 /etc/redoubt/redoubt-scan.sh
  cat > /etc/systemd/system/redoubt-scan.service <<'SCANSVC'
[Unit]
Description=Redoubt stack security scan (trivy)
After=docker.service

[Service]
Type=oneshot
Nice=10
ExecStart=/etc/redoubt/redoubt-scan.sh
SCANSVC
  cat > /etc/systemd/system/redoubt-scan.timer <<'SCANTMR'
[Unit]
Description=Weekly Redoubt stack security scan

[Timer]
OnCalendar=Sun 03:00
OnBootSec=12min
Persistent=true

[Install]
WantedBy=timers.target
SCANTMR
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable redoubt-scan.timer >/dev/null 2>&1 || true
  systemctl start redoubt-scan.timer >/dev/null 2>&1 || true
  dbg "OK: weekly stack scan armed (trivy, Sundays 03:00 + once after boot)"
  case "$PKG_FAMILY" in
    pacman) pacman -S --noconfirm --needed qrencode >/dev/null 2>&1 ;;
    dnf)    dnf -y install qrencode >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive install qrencode >/dev/null 2>&1 ;;
    *)      apt-get install -y -qq qrencode >/dev/null 2>&1 ;;
  esac
  WELCOME=/var/lib/redoubt/welcome
  mkdir -p "$WELCOME/Scan Me"
  if [ "$MESH_MODE" = "cloud" ]; then
    MESH_CARD_HTML="    <p>Your mesh rides NetBird's free cloud. Install the NetBird app on your phone and sign in with the NetBird account that owns the setup key. The addresses above then work from any network, and at home the same links run straight over your wifi. NetBird only brokers the handshake; your files stay encrypted between your devices. Prefer zero third parties? Run: redoubt mesh-local.</p>"
  else
    MESH_CARD_HTML='    <p>Install the NetBird app, add this self-hosted server, and enter the mobile mesh key from <em>Access.txt</em> (in this folder). The addresses above then work from any wifi in your home. If you want them from any network, grab a license at tryredoubt.com.</p>'
  fi
  # Service QRs carry the mesh address when the machine joined the mesh
  # (the phone reaches it from any network). LAN is the fallback.
  MESH_IP="${NETBIRD_IP:-$LAN_IP}"
  # the names hide the addresses in the texts: .lan is the home path
  # (the pi-hole or /etc/hosts resolve it), .remote is the mesh path
  # (the zone resolves it). Cloud and both phones ride the cloud:
  # with a PAT the kit published the zone and they resolve the name,
  # without one their texts keep the address.
  LAN_HOST="redoubt.lan"
  REMOTE_HOST="redoubt.remote"
  [ "$MESH_MODE" != "selfhost" ] && [ ! -f /etc/redoubt/cloud-pat.txt ] && REMOTE_HOST="${NETBIRD_IP:-$LAN_IP}"
  # the reveal, the guide and Access.txt lead with the mode's own path:
  # selfhost is a full-NB NAS: the apps sing the mesh name (the wifi
  # sees nothing unless the owner opened the doors), cloud sings the
  # mesh name too (any network, NetBird's cloud brokers the tunnel)
  if [ "$MESH_MODE" = "selfhost" ]; then APPS_HOST="$REMOTE_HOST"; else APPS_HOST="$REMOTE_HOST"; fi
  PANEL_URL="https://$LAN_HOST:$PORT_EDGE4"
  PANEL_URL_MESH="https://$REMOTE_HOST:$PORT_EDGE4"
LAN_CERT_URL="https://$LAN_HOST:$PORT_EDGE1/root-ca.crt"
CERT_URL="https://$REMOTE_HOST:$PORT_EDGE1/root-ca.crt"
  PHOTOS_URL="https://$MESH_IP:$PORT_EDGE1"
  FILES_URL="https://$MESH_IP:$PORT_EDGE2"
  SEARCH_URL="https://$MESH_IP:$PORT_EDGE3"
  qrencode -o "$WELCOME/Scan Me/immich-ios.png" -s 7 "https://apps.apple.com/app/immich/id1673945655" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/immich-android.png" -s 7 "https://play.google.com/store/apps/details?id=app.alextran.immich" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/nextcloud-ios.png" -s 7 "https://apps.apple.com/app/nextcloud/id1125420102" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/nextcloud-android.png" -s 7 "https://play.google.com/store/apps/details?id=com.nextcloud.client" 2>/dev/null
  case "$MESH_MODE" in
    cloud)
      qrencode -o "$WELCOME/Scan Me/netbird.png" -s 7 "https://app.netbird.io" 2>/dev/null
      NETBIRD_QR_LABEL="NetBird: your account"
      ;;
    *)
      qrencode -o "$WELCOME/Scan Me/netbird.png" -s 7 "$MESH_BASE" 2>/dev/null
      NETBIRD_QR_LABEL="NetBird: any phone"
      ;;
  esac
  qrencode -o "$WELCOME/Scan Me/panel.png" -s 7 "$PANEL_URL_MESH" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/panel-lan.png" -s 7 "https://$LAN_HOST:$PORT_EDGE4" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/netbird-ios.png" -s 7 "https://apps.apple.com/app/netbird/id6469329339" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/netbird-android.png" -s 7 "https://play.google.com/store/apps/details?id=io.netbird.client" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/cert.png" -s 7 "$CERT_URL" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/photos-lan.png" -s 7 "https://$LAN_HOST:$PORT_EDGE1" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/files-lan.png" -s 7 "https://$LAN_HOST:$PORT_EDGE2" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/search-lan.png" -s 7 "https://$LAN_HOST:$PORT_EDGE3" 2>/dev/null
  PHOTOS_URL_MESH="https://$REMOTE_HOST:$PORT_EDGE1"
  FILES_URL_MESH="https://$REMOTE_HOST:$PORT_EDGE2"
  SEARCH_URL_MESH="https://$REMOTE_HOST:$PORT_EDGE3"
  case "$MESH_MODE" in
    selfhost)
      MESH_SERVER_LABEL="Server (home wifi, via your mesh)"
      MESH_QR_LABEL="mesh: scan"
      ;;
    *)
      MESH_SERVER_LABEL="Server (anywhere, via your mesh)"
      MESH_QR_LABEL="anywhere: scan"
      ;;
  esac
  qrencode -o "$WELCOME/Scan Me/photos.png" -s 7 "$PHOTOS_URL_MESH" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/files.png" -s 7 "$FILES_URL_MESH" 2>/dev/null
  qrencode -o "$WELCOME/Scan Me/search.png" -s 7 "$SEARCH_URL_MESH" 2>/dev/null
  # The mesh QRs above open the apps from any network once the phone
  # joined the mesh. The LAN ones below work on home wifi, no mesh
  # needed. The owner's double-click shortcuts point at the local
  # network. The CA covers the LAN name, so the lock icon stays clean
  # and home wifi always works.
  PHOTOS_URL="https://$LAN_HOST:$PORT_EDGE1"
  FILES_URL="https://$LAN_HOST:$PORT_EDGE2"
  SEARCH_URL="https://$LAN_HOST:$PORT_EDGE3"
  if [ "$MESH_MODE" = "cloud" ]; then
    MESH_CARD_BODY="<h2>Your apps from anywhere</h2>
    <p>Install the NetBird app with the QR and sign in with the <strong>same account</strong> you used on this computer during the install, that account is where this computer's mesh lives. Your photos, files and search work on any network, and at home the same links run straight over your wifi, no mesh needed.</p>
    <ol>
      <li>Scan the QR and install the <strong>NetBird</strong> app. Open it and tap <strong>Sign in</strong> (no account yet? create one right there, an email is enough).</li>
      <li>Sign in with the <strong>same email and account</strong> you used on this computer. Do not change the server: your account already points at the right place.</li>
      <li>Allow the VPN permission when it asks, then tap the NetBird logo to connect.</li>
      <li>Once connected, open your panel (your dashboard with the big buttons for Photos, Files and Search): <code>$PANEL_URL_MESH</code></li>
    </ol>"
  else
    MESH_CARD_BODY="<h2>Your mesh, your rules</h2>
    <p>Install the NetBird app on your phone and add <strong>this machine</strong> as your self-hosted server. The addresses above then work from any wifi in your home, and your files stay between your devices only.</p>
    <ol>
      <li>Scan the <strong>NetBird</strong> QR and install the app (the QR opens the app's site; the app store QRs are right next to it).</li>
      <li>In the app tap <strong>Add self-hosted server</strong>: scan the mesh QR below (or type <code>$MESH_BASE</code>), then enter the mobile mesh key from <em>Access.txt</em> in this folder.</li>
      <li>Allow the VPN permission when it asks, then tap connect.</li>
      <li>Once connected, open your panel (your dashboard with the big buttons for Photos, Files and Search): <code>$PANEL_URL_MESH</code></li>
    </ol>"
  fi
  CA_CRT=/var/lib/redoubt/caddy-local/caddy/pki/authorities/local/root.crt
  # Edge killer: if root.crt is a directory (left by a crashed caddy),
  # the edge dies with "is a directory" and loops for ~60s. Delete it
  # and restart the edge; caddy regenerates the local CA as real files.
  if [ -d "$CA_CRT" ]; then
    echo "root.crt is a directory (crashed caddy leftover); removing and restarting the edge" >> "$LOG"
    rm -rf "$CA_CRT"
    docker restart redoubt-edge-local-1 >> "$LOG" 2>&1 || true
  fi
  # The cert also lands in a dedicated share dir for the edge's https
  # /root-ca.crt route. One file only: never the key, never the pki dir.
  LOGO_B64=""
  [ -f /var/lib/redoubt/caddy-local/logo.png ] && \
    LOGO_B64="$(base64 -w0 /var/lib/redoubt/caddy-local/logo.png 2>/dev/null)"
  if [ -f "$CA_CRT" ]; then
    mkdir -p /var/lib/redoubt/caddy-local/cert-share
    cp "$CA_CRT" /var/lib/redoubt/caddy-local/cert-share/root-ca.crt
    chmod 644 /var/lib/redoubt/caddy-local/cert-share/root-ca.crt
  fi
  [ -f "$CA_CRT" ] && cp "$CA_CRT" "$WELCOME/Redoubt Root CA.crt" && chmod 644 "$WELCOME/Redoubt Root CA.crt"
  # No system-store CA: Firefox auto-imports the enterprise roots and
  # lands them untrusted, beating the trusted profile copy on every
  # start. The welcome folder carries the cert for any tool that wants
  # it, and Firefox gets it through certutil below, the one import that
  # keeps the trust bits.
  if [ -f "$CA_CRT" ]; then
    # Firefox ignores the system store, and its policy engine imports
    # certs untrusted, so the only import that lands trusted is certutil
    # straight into the profile databases. Every profile that exists
    # gets one deduped, trusted copy; the kit re-imports on each pass so
    # profiles made later heal on the next run.
    if command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1; then
      chmod 644 "$CA_CRT" 2>/dev/null || true
      if ! command -v certutil >/dev/null 2>&1; then
        apt-get install -y -qq libnss3-tools >/dev/null 2>&1 || true
      fi
      if command -v certutil >/dev/null 2>&1; then
        # a running browser locks its NSS databases: the import below
        # fails silently per profile, so remember it and warn honestly
        FF_RUNNING=0
        FF_PROFILES=0
        FF_NAILED=0
        pgrep -x firefox >/dev/null 2>&1 && FF_RUNNING=1
        pgrep -x firefox-esr >/dev/null 2>&1 && FF_RUNNING=1
        for PF in /home/*/.mozilla/firefox/*.default* /home/*/.mozilla/firefox/*.default-release \
                  /home/*/.config/mozilla/firefox/*.default* /home/*/.config/mozilla/firefox/*.default-release; do
          [ -d "$PF" ] || continue
          while certutil -L -d "sql:$PF" 2>/dev/null | grep -q "Redoubt Local CA"; do
            certutil -D -d "sql:$PF" -n "Redoubt Local CA" >/dev/null 2>&1 || break
          done
          FF_PROFILES=$((FF_PROFILES + 1))
          certutil -A -d "sql:$PF" -n "Redoubt Local CA" -t "CT,," -i "$CA_CRT" >/dev/null 2>&1 \
            && FF_NAILED=$((FF_NAILED + 1))
        done
        if [ "$FF_NAILED" -gt 0 ]; then
          dbg "OK: Firefox trust imported into every profile (deduped, C, trust bits)"
          if [ "$FF_RUNNING" = "1" ]; then
            dbg "Firefox was open during this pass - close and reopen it for the green padlock (or run redoubt update)" >> "$LOG"
          fi
        elif [ "$FF_PROFILES" -gt 0 ]; then
          dbg "WARN: no Firefox profile took the local CA (browser open?). Close Firefox and run redoubt update for the green padlock" >> "$LOG"
        else
          # fresh machine: Firefox has never run, so no profile exists
          # to import. Make one now (db plus profiles.ini) in both the
          # classic and the XDG layout, and drop the trusted CA in it.
          # Firefox adopts the ready profile on its very first open and
          # the padlock is green before the owner ever touches it.
          for BASE in /home/*/.config/mozilla/firefox /home/*/.mozilla/firefox; do
            [ -d "$(dirname "$BASE")" ] || continue
            NEWPROF="$BASE/redoubt.default"
            mkdir -p "$NEWPROF"
            certutil -N -d "sql:$NEWPROF" --empty-password >/dev/null 2>&1
            certutil -A -d "sql:$NEWPROF" -n "Redoubt Local CA" -t "CT,," -i "$CA_CRT" >/dev/null 2>&1 \
              && FF_NAILED=$((FF_NAILED + 1))
            INI="$(dirname "$BASE")/profiles.ini"
            if [ ! -f "$INI" ]; then
              cat > "$INI" <<'PROFILES'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=redoubt
IsRelative=1
Path=redoubt.default
Default=1
PROFILES
            fi
          done
          [ "$FF_NAILED" -gt 0 ] && \
            dbg "OK: Firefox trust pre-imported into a fresh profile (green padlock from the very first open)"
        fi
      fi
    fi
  fi
  [ -f "$STACKDIR/mobile-mesh-key.txt" ] && cp "$STACKDIR/mobile-mesh-key.txt" "$WELCOME/Mobile Mesh Key.txt" && chmod 600 "$WELCOME/Mobile Mesh Key.txt"
  cat > "$WELCOME/thinkers-guide.txt" <<'THINKERS'
# Only for Thinkers

Welcome. If you opened this folder, you are already different. Most people never
ask the question. You did. This is your invitation to think twice.

## The one fact that changes everything

When a service is "free", you are not the customer. You are the product.

Your searches, your photos, your conversations, your location, the way you
type, the things you hesitate to click: all of it is collected, packaged,
and sold. Not to hackers in the movies. To data brokers, advertisers, and
algorithms that know you better than your friends do.

You did not give permission. You just clicked "I agree".

That ends the day you decide it ends. Redoubt is your first step: your data,
in your house, under your control. This folder is your second step: the tools
that free the rest of your digital life.

## The toolkit (free, proven, and worth your time)

1. A VPN that asks for nothing
   Mullvad (mullvad.net): the most audited VPN for privacy, and the one
   that asks the least about you. No email, no name: your account is a
   random number. Pay with Monero or cash by mail and they literally do
   not know who you are. WireGuard, a kill switch that cuts the internet
   if the tunnel drops, and no logs a court could ever read.
   Strong alternatives: Proton VPN (protonvpn.com, the best free tier,
   but it asks for an email at signup) and IVPN (ivpn.net, cash and
   Monero, for purists).
   Why it matters: your internet provider sees every address you visit
   and sells that history. A VPN moves the eyes away from your door.

2. A browser built to be invisible
   Mullvad Browser (mullvad.net/browser): made with the Tor Project team
   but for everyday use. It makes you look like everyone else, which is
   the real trick of privacy online. LibreWolf (librewolf.net) is a
   hardened Firefox. And if you want familiar, Brave (brave.com) blocks
   trackers and ads out of the box, no extensions needed.
   If you use Chrome or Edge, every site you visit is shared with the
   companies behind them. You can change that in ten minutes.

3. An ad-blocker that is not for sale
   uBlock Origin: blocks ads AND the trackers inside them. An ad is not
   just an ad. It is a tracking beacon that follows you across the
   internet.

4. A DNS that forgets, already switched on
   Quad9 (quad9.net) is built in: every lookup from this box travels
   encrypted (TLS) to Quad9, which blocks known-malicious domains and keeps
   no records. A firewall rule blocks plain DNS leaks, so your internet
   provider stops seeing the addresses you visit.

5. Email that is not being read
   Proton Mail (proton.me): end-to-end encrypted email from Switzerland.
   Free tier is real. Gmail reads your mail to sell ads; Proton literally
   cannot read it. Tuta (tuta.com) is the other serious option, same
   idea, different country.
   For signups and newsletters, use aliases: SimpleLogin (simplelogin.io,
   by Proton) or addy.io give every site a different address that
   forwards to you. When one leaks, you burn it and move on.

6. Messages that disappear into math
   Signal (signal.org): end-to-end encrypted messaging, open source, free.
   Every message is locked so that even Signal cannot read it. If your
   chats are on WhatsApp, they are shared with Meta's machine.
   For the hardcore: SimpleX (simplex.chat) keeps no identifiers at all,
   not even a username, and Session (getsession.org) routes everything
   through onion relays. No phone number, no profile, no trail.

7. Passwords that are not yours to remember
   Bitwarden (bitwarden.com): a free, open-source password manager. One
   strong master password, and every other password becomes long, random,
   and different for every site. Reusing passwords is how most accounts
   get taken. KeePassXC (keepassxc.org) keeps the vault on your own disk,
   no cloud at all, if that is your style.

8. A tunnel no one can watch
   Tor Browser (torproject.org): bounces your traffic through three random
   relays so no one, not your provider and not the site, knows who is looking.

9. A phone that stops snitching
   GrapheneOS (grapheneos.org): a hardened Android without Google
   services, for phones that support it. Your phone is the most talkative
   device you own; this one goes quiet. For computers, Qubes OS
   (qubes-os.org) runs every app in its own locked room, and Tails
   (tails.net) boots from a USB and forgets everything when you unplug.
   On any Android, install apps from F-Droid (f-droid.org): the
   open-source catalogue, no Google account required.

10. Pay without signing your name
    Monero (getmonero.org): the private digital cash. Where Bitcoin is a
    public ledger anyone can read, Monero hides amounts and addresses by
    design. Mullvad, IVPN and Proton all accept it. Cash by mail works
    too, and it still beats handing your card to a data broker.

11. A search engine that forgets
    DuckDuckGo (duckduckgo.com) and Startpage (startpage.com) answer your
    questions without building a file on you. For the full version:
    SearXNG is a search engine you host yourself, with no logs at all.
    Your Redoubt already runs one.

12. Photos without a home address
    Every photo your phone takes carries metadata: the exact place, the
    time, the camera model. Before sharing, strip it: ExifTool
    (exiftool.org) does it on any computer. Your location is nobody's
    business but yours.

13. Files that stay sealed
    Cryptomator (cryptomator.org): encrypts your files before they leave
    your machine, so any cloud that stores them stores sealed boxes.
    Whatever it is, only you hold the key.

14. Second factors that answer to you
    Aegis Authenticator (getaegis.app, Android) and Ente Auth
    (ente.io/auth, all platforms) are open-source two-factor apps that
    do not lock your codes in a Google account. For hardware, a YubiKey
    (yubico.com) cannot be phished: the key must be physically present.

15. Your whole network, cleaned
    AdGuard Home or Pi-hole: a tiny blocker you run at home that filters
    trackers for every device on your network: phones, TVs, everything.
    (Your Redoubt can host one. Ask us in the community.)

16. Know the law: knowledge is power
    You have rights. They are written down, and almost nobody reads them.
    Look up the privacy laws of your state and your country: the US Congress
    publishes every bill at congress.gov, and every state legislature has its
    own public site. Your state very likely gives you the right to access,
    delete, and say NO to the sale of your personal data (California's CCPA
    started it; many states followed).
    Watchdogs like the EFF (eff.org) and EPIC publish plain-language guides
    on what those rights are and how to use them.
    Why it matters: a company can only take what you do not know you own.
    Knowledge is power. Read the law, know your rights, and grow.

## The rule of thinking twice

Before you type anything, ask: who keeps this? Who sells it? Who reads it
when I am not looking?

Free is never free. Convenience has a price, and the currency is you.

You already took your data home. Now take your attention home too.
Think. Question. Verify. And keep what is yours.

- Redoubt
THINKERS
  cat > "$WELCOME/scan-readme.txt" <<'SCANNOTE'
Redoubt stack scan

A weekly security pass (trivy) audits every app image against the
public CVE feeds and the compose file for misconfigs and leaked
secrets. Read-only: it never touches the running apps.

  Report:    /var/lib/redoubt/scan/last-scan.txt
  Full log:  /var/lib/redoubt/scan/last-scan-full.txt

The first scan runs a few minutes after boot, then every Sunday at
03:00. Re-run any time with: sudo systemctl start redoubt-scan.service
SCANNOTE
  chmod 644 "$WELCOME/scan-readme.txt"
  dbg "OK: thinkers guide written"

  # 8d) The human folder, identical to the Windows app: Documents/My
  #     Redoubt with the welcome page, QR codes, the CA (plus the iPhone
  #     profile), shortcuts and the access note. The system paths above
  #     stay for the CLI.
  OWNER_HOME=""
  if [ -n "${SUDO_USER:-}" ]; then
    OWNER_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  fi
  [ -z "$OWNER_HOME" ] && OWNER_HOME=$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $6; exit}' 2>/dev/null)
  if [ -n "$OWNER_HOME" ] && [ -d "$OWNER_HOME" ]; then
    MYREDOUBT="$OWNER_HOME/Documents/My Redoubt"
    mkdir -p "$MYREDOUBT/Only for Thinkers"
    # A .directory file is the XFCE/Thunar-native way to pin the folder
    # icon (gvfs metadata is Nautilus-flavoured and gets written under
    # the wrong HOME from a root pass). The launcher on the desktop
    # also reads it.
    if [ -f /var/lib/redoubt/caddy-local/logo.png ]; then
      printf '[Desktop Entry]\nIcon=/var/lib/redoubt/caddy-local/logo.png\n' > "$MYREDOUBT/.directory"
    fi
    # umask 077 leaves every dir this chain creates owned by root:
    # My Redoubt gets chowned below, but Documents is born here and
    # would stay root-only, locking the owner out of their own vault.
    # fix the parent right where it may be born.
    chown "$(stat -c '%u:%g' "$OWNER_HOME")" "$OWNER_HOME/Documents" 2>/dev/null || true
    # The folder wears the logo and the desktop gets a one-click
    # shortcut. gio metadata drives both, so no root tricks and no
    # launcher-trust prompts; the icon file lives in the kit's own dir.
    if [ -f /var/lib/redoubt/caddy-local/logo.png ] && command -v gio >/dev/null 2>&1; then
      gio set "$MYREDOUBT" metadata::custom-icon \
        "file:///var/lib/redoubt/caddy-local/logo.png" >/dev/null 2>&1 || true
    fi
    DESKTOP_DIR="$OWNER_HOME/Desktop"
    if [ -f "$OWNER_HOME/.config/user-dirs.dirs" ]; then
      DLINE="$(grep '^XDG_DESKTOP_DIR=' "$OWNER_HOME/.config/user-dirs.dirs" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
      [ -n "$DLINE" ] && DESKTOP_DIR="$(printf '%s' "$DLINE" | sed "s|\$HOME|$OWNER_HOME|")"
    fi
    if [ -d "$DESKTOP_DIR" ] || mkdir -p "$DESKTOP_DIR" 2>/dev/null; then
      # The dir may be born under umask 077 as root-only, and a
      # root-owned Desktop hides the shortcut from the desktop shell
      # entirely (seen on Rocky: the shortcut never appeared).
      # Hand it to the owner before the shortcut lands inside.
      chown "$(stat -c '%u:%g' "$OWNER_HOME")" "$DESKTOP_DIR" 2>/dev/null || true
      cat > "$DESKTOP_DIR/My Redoubt.desktop" <<DESKSHRT
[Desktop Entry]
Type=Application
Name=My Redoubt
Comment=Your private cloud folder
Exec=xdg-open "$MYREDOUBT"
Icon=/var/lib/redoubt/caddy-local/logo.png
Terminal=false
DESKSHRT
      DSK_OWNER="$(stat -c '%U' "$DESKTOP_DIR" 2>/dev/null)"
      [ -n "${SUDO_USER:-}" ] && DSK_OWNER="$SUDO_USER"
      chown "$DSK_OWNER":"$DSK_OWNER" "$DESKTOP_DIR/My Redoubt.desktop" 2>/dev/null || true
      chmod 755 "$DESKTOP_DIR/My Redoubt.desktop" 2>/dev/null || true
      gio set "$DESKTOP_DIR/My Redoubt.desktop" metadata::trusted true >/dev/null 2>&1 || true
      # Fresh XFCE profiles sometimes lack the desktop-icons property
      # and xfdesktop stays silent with the launcher right there:
      # fill the default gap and reload the desktop as the owner so
      # the shortcut shows without a re-login. Harmless elsewhere
      # (both calls just fail quietly when XFCE is absent). The whole
      # nudge is hard-capped: a desktop helper must never hold the
      # pass (an unbounded su -c without the session bus
      # autolaunched dbus and hung the install for good).
      if [ -n "${SUDO_USER:-}" ] && command -v su >/dev/null 2>&1; then
        _UIDN=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f3)
        timeout 12 su "$SUDO_USER" -c "export DISPLAY=:0; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${_UIDN:-1000}/bus; xfconf-query -c xfce4-desktop -p /desktop-icons/style -n -t int -s 3 >/dev/null 2>&1; timeout 4 xfdesktop --reload >/dev/null 2>&1" 2>/dev/null || true
      fi
      dbg "OK: My Redoubt on the desktop (one click, with its icon)"
    fi
    # The QR burrow: cp -r into a live dir nests one level per pass, and
    # pre-parity bundles left a badly-cased "qr" folder behind. Rebuild
    # cleanly every pass so old installs self-heal.
    rm -rf "$MYREDOUBT/Scan Me" "$MYREDOUBT/qr" "$MYREDOUBT/QR"
    cp -r "$WELCOME/Scan Me" "$MYREDOUBT/Scan Me" 2>/dev/null || true
    cp "$WELCOME/Redoubt Root CA.crt" "$MYREDOUBT/" 2>/dev/null || true
    cp "$WELCOME/thinkers-guide.txt" "$MYREDOUBT/Only for Thinkers/" 2>/dev/null || true
    # The credentials also live here, in plain sight: a normal user opens
    # Documents/My Redoubt and finds every password without a terminal.
    :    # The CA also goes straight into every existing Firefox profile (the
    # policy covers new ones), so a browser that was already open trusts
    # the dashboards on its next start with zero clicks.
    if ! command -v certutil >/dev/null 2>&1; then
      case "$PKG_FAMILY" in
        apt) apt-get install -y -qq libnss3-tools >/dev/null 2>&1 ;;
        dnf) dnf -y install nss-tools >/dev/null 2>&1 ;;
        pacman) pacman -S --noconfirm --needed nss >/dev/null 2>&1 ;;
      esac
    fi
    if command -v certutil >/dev/null 2>&1; then
      # The profile may live in .mozilla or .config/mozilla (Mint and
      # some XDG setups use the latter). Scan both, so the padlock never
      # depends on where the browser keeps its profile.
      for PROF in "$OWNER_HOME"/.mozilla/firefox/* "$OWNER_HOME"/.config/mozilla/firefox/*; do
        [ -d "$PROF" ] && [ -f "$PROF/cert9.db" ] || continue
        certutil -A -n "Redoubt Local CA" -t "C,," -i "$CA_CRT" -d "sql:$PROF" >/dev/null 2>&1 \
          && echo "OK: local CA into firefox profile (clean padlock, zero clicks)" && break
      done
    fi
    # The iPhone profile: same CA, in the format iOS installs with one
    # tap from the Files app.
    CAPEM=$(openssl x509 -in "$WELCOME/Redoubt Root CA.crt" -outform DER 2>/dev/null | base64 -w0 2>/dev/null)
    CFGUUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "redoubt-ca")
    cat > "$MYREDOUBT/Redoubt Root CA.mobileconfig" <<MOBILECONFIG
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>Redoubt Root CA.crt</string>
      <key>PayloadContent</key>
      <data>$CAPEM</data>
      <key>PayloadDescription</key>
      <string>Trust the Redoubt certificate authority</string>
      <key>PayloadDisplayName</key>
      <string>Redoubt Root CA</string>
      <key>PayloadIdentifier</key>
      <string>devitechy.redoubt.ca.$CFGUUID</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>$CFGUUID</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>Redoubt root certificate authority</string>
  <key>PayloadDisplayName</key>
  <string>Redoubt Root CA</string>
  <key>PayloadIdentifier</key>
  <string>devitechy.redoubt.$CFGUUID</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$CFGUUID</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
MOBILECONFIG
    # Clickable shortcuts, the Linux twin of the exe .url files: small
    # html pages that hand the browser straight to the app. Double-click
    # and the app opens; no launcher trust issues, ever.
    rm -f "$MYREDOUBT"/*.desktop 2>/dev/null || true
    for APP in "Open Photos:$PHOTOS_URL" "Open Files:$FILES_URL" "Open Search:$SEARCH_URL" "Open Panel:$PANEL_URL" "Open Stack Manager:http://127.0.0.1:$PORT_DOCKGE"; do
      APPNAME=${APP%%:*}; APPURL=${APP#*:}
      cat > "$MYREDOUBT/$APPNAME.html" <<SHORTCUT
<!doctype html>
<html>
<head><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=$APPURL"></head>
<body><p>Opening... <a href="$APPURL">click here if nothing happens</a></p></body>
</html>
SHORTCUT
    done
    case "$MESH_MODE" in
      cloud)
        MESH_GUIDE="Install the NetBird app on your phone and sign in with the same NetBird account: the addresses above work from any network. At home, the same links run straight over your wifi, no mesh needed."
        if [ "$HAS_GUI" = "1" ]; then
          ACCESS_MESH="device mesh: NetBird cloud (sign in with your account and tap connect in the app); at home the wifi addresses work too"
        else
          ACCESS_MESH="device mesh: NetBird cloud (sign in with the same account on your device); at home the wifi addresses work too"
        fi
        ;;
      *)
        MESH_GUIDE="Install the NetBird app, add your self-hosted server, and enter the mobile mesh key from Access.txt. The same addresses then work from any network."
        ACCESS_MESH="device mesh: self-hosted (the mobile mesh key is in this file)"
        ;;
    esac
# the desktop trusts the local CA on its own: the system store per
# family, the shared NSS db Chromium reads, and Firefox through its
# system policy (read on every start, so a rotated CA lands on the next
# launch). Each piece is guarded: a missing tool is never fatal.
inject_ca_to_desktop() {
  local _CA="/var/lib/redoubt/caddy-local/caddy/pki/authorities/local/root.crt"
  local _OH="$OWNER_HOME" _OU=""
  [ -f "$_CA" ] || return 0
  _OU=$(stat -c '%U' "$_OH" 2>/dev/null || true)
  case "$PKG_FAMILY" in
    dnf)
      cp -f "$_CA" /etc/pki/ca-trust/source/anchors/redoubt-root-ca.crt 2>/dev/null || true
      update-ca-trust >/dev/null 2>&1 || true
      command -v certutil >/dev/null 2>&1 || dnf install -y -q nss-tools >/dev/null 2>&1 || true
      ;;
    apt)
      cp -f "$_CA" /usr/local/share/ca-certificates/redoubt-root-ca.crt 2>/dev/null || true
      update-ca-certificates >/dev/null 2>&1 || true
      command -v certutil >/dev/null 2>&1 || apt-get install -y -qq libnss3-tools >/dev/null 2>&1 || true
      ;;
    pacman)
      trust anchor "$_CA" >/dev/null 2>&1 || true
      command -v certutil >/dev/null 2>&1 || pacman -S --noconfirm --needed nss >/dev/null 2>&1 || true
      ;;
    zypper)
      cp -f "$_CA" /etc/pki/trust/anchors/redoubt-root-ca.crt 2>/dev/null || true
      update-ca-certificates >/dev/null 2>&1 || true
      command -v certutil >/dev/null 2>&1 || zypper --non-interactive install mozilla-nss-tools >/dev/null 2>&1 || true
      ;;
  esac
  if ! command -v certutil >/dev/null 2>&1; then
    return 0
  fi
  # Chromium reads the owner's shared NSS db; create it empty when it
  # does not exist yet (Chromium picks it up all the same)
  if [ ! -d "$_OH/.pki/nssdb" ]; then
    mkdir -p "$_OH/.pki/nssdb" 2>/dev/null || return 0
    certutil -d "sql:$_OH/.pki/nssdb" -N --empty-password >/dev/null 2>&1 || true
  fi
  certutil -d "sql:$_OH/.pki/nssdb" -A -t "C,," -n "Redoubt Root CA" -i "$_CA" >/dev/null 2>&1 || true
  mkdir -p /etc/firefox/policies 2>/dev/null
  cat > /etc/firefox/policies/policies.json <<FXPOL
{
  "policies": {
    "Certificates": {
      "Install": ["$_CA"]
    }
  }
}
FXPOL
  [ -n "$_OU" ] && chown -R "$_OU": "$_OH/.pki/nssdb" 2>/dev/null || true
  CA_AUTO=1
  dbg "OK: desktop browsers trust the Redoubt root CA (system, Chromium, Firefox)"
}

    CA_AUTO=0
    [ "$HAS_GUI" = "1" ] && inject_ca_to_desktop
    if [ "$HAS_GUI" = "1" ]; then
      if [ "$CA_AUTO" = "1" ]; then
        DESKTOP_CERT_LINE="   On this machine: Redoubt Root CA is already trusted (system, Chromium and Firefox); another browser can import it from this folder."
      else
        DESKTOP_CERT_LINE="   On this machine: open Redoubt Root CA.crt and install it in
   your browser or system trust store."
      fi
      APPS_EXTRA="   Start Here.html carries one QR per app."
      QR_GUIDE_LINE="   redoubt qr       a QR per app, scannable off the screen"
      QR_HINT=", qr"
    elif [ -e /dev/fb0 ] \
         && command -v qrencode >/dev/null 2>&1 && command -v fbi >/dev/null 2>&1 \
         && command -v openvt >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; then
      DESKTOP_CERT_LINE=""
      APPS_EXTRA="   No browser on this box? run: redoubt qr (a QR per app on screen)."
      QR_GUIDE_LINE="   redoubt qr       a QR per app, scannable off the screen"
      QR_HINT=", qr"
    elif [ "$TERM" = "linux" ] && command -v qrencode >/dev/null 2>&1; then
      # the ANSI path: the console itself paints the codes, no fbi
      # needed (the reveal kept the hint empty while the kit
      # was perfectly able to print the QR right here)
      DESKTOP_CERT_LINE=""
      APPS_EXTRA="   No browser on this box? run: redoubt qr (a QR per app, printed right here)."
      QR_GUIDE_LINE="   redoubt qr       a QR per app, printed right here"
      QR_HINT=", qr"
    else
      DESKTOP_CERT_LINE=""
      APPS_EXTRA=""
      QR_GUIDE_LINE="   redoubt qr       the app addresses as text (no screen painter here)"
      QR_HINT=""
    fi
    # the guide leads with the mode's own path: selfhost is a full-NB
    # NAS (the mesh carries the apps, the wifi sees nothing unless the
    # owner opened the doors), cloud rides NetBird's cloud from any
    # network and lists the wifi as the at-home line
    APPS_CONSOLE_LINE=""
    if [ "$MESH_MODE" = "selfhost" ]; then
      APPS_HEAD_LINE="(your mesh)"
      APPS_CONSOLE_LINE="
     console https://${REMOTE_HOST}:${PORT_DASH} (the NetBird dashboard: users, setup keys and peers)"
      if [ "${FW_DECISION:-}" = "on" ]; then
        printf -v APPS_SECOND_LINE 'Home wifi (you opened the doors):
     photos  https://%s:%s
     files   https://%s:%s
     search  https://%s:%s
     panel   https://%s:%s' "$LAN_HOST" "$PORT_EDGE1" "$LAN_HOST" "$PORT_EDGE2" "$LAN_HOST" "$PORT_EDGE3" "$LAN_HOST" "$PORT_EDGE4"
      else
        APPS_SECOND_LINE='The wifi sees nothing: your apps answer only to your mesh devices.'
      fi
    else
      APPS_HEAD_LINE="(the mesh addresses work from any network)"
      APPS_CONSOLE_LINE="
     console https://app.netbird.io (your NetBird account: peers, setup keys, access rules)"
      printf -v APPS_SECOND_LINE 'On this wifi (after setting this device'"'"'s DNS to %s):
     photos  https://%s:%s
     files   https://%s:%s
     search  https://%s:%s
     panel   https://%s:%s' "$LAN_IP" "$LAN_HOST" "$PORT_EDGE1" "$LAN_HOST" "$PORT_EDGE2" "$LAN_HOST" "$PORT_EDGE3" "$LAN_HOST" "$PORT_EDGE4"
    fi
    cat > "$MYREDOUBT/Welcome Guide.txt" <<GUIDE
Redoubt - welcome guide

Your cloud is up. This file is the quick tour.

1. The lock (do this once)
   The apps speak https signed by your own local CA, so the phone must
   trust it once: open http://${MESH_IP:-$LAN_IP}:8086/ca on the phone
   and install the certificate (iPhone: Redoubt Root CA.mobileconfig;
   Android: Redoubt Root CA.crt).
$DESKTOP_CERT_LINE
   The not-secure warning goes away for good.

2. Your apps $APPS_HEAD_LINE
     photos  https://${APPS_HOST}:$PORT_EDGE1
     files   https://${APPS_HOST}:$PORT_EDGE2
     search  https://${APPS_HOST}:$PORT_EDGE3
     panel   https://${APPS_HOST}:$PORT_EDGE4
     ad shield  https://redoubt.lan:$PORT_EDGE5/admin

$APPS_SECOND_LINE
$APPS_CONSOLE_LINE
$APPS_EXTRA
   Ad blocker: at home, set each device DNS to $LAN_IP (the router or
   the wifi settings) so ads and trackers get blocked network-wide.

3. Your phone on the mesh
   $MESH_GUIDE

4. Credentials
   Access.txt holds your user and password. Keep this folder somewhere
   safe: it is the key to your cloud.

Terminal (any time):
   redoubt status   every service, live
   redoubt creds    your credentials
   redoubt guide    this file
$QR_GUIDE_LINE
GUIDE
    MOBILE_KEY_VAL="$(cat "$WELCOME/Mobile Mesh Key.txt" 2>/dev/null)"
    case "$MESH_MODE" in
      cloud)
        MOBILE_BLOCK=""
        ;;
      *)
        MOBILE_BLOCK="Mobile mesh key (the NetBird app asks for it at home):
$MOBILE_KEY_VAL
"
        ;;
    esac
    PANEL_LINE="https://$APPS_HOST:$PORT_EDGE4"
    ACCESS_LAN_LINES=""
    if [ "$HAS_GUI" = "0" ]; then
      ACCESS_GUIDE_LINE="No browser on this box? run: redoubt guide (the phone steps as text)."
    else
      ACCESS_GUIDE_LINE="The phone steps and the certificate guide are in Start Here.html."
    fi
      if [ "$MESH_MODE" = "selfhost" ]; then
        printf -v ACCESS_LAN_LINES 'console https://%s:%s (NetBird dashboard: users, setup keys, peers)\n' "$REMOTE_HOST" "$PORT_DASH"
        if [ "${FW_DECISION:-}" = "on" ]; then
          printf -v ACCESS_WIFI 'home wifi (you opened the doors):\n  photos  https://%s:%s\n  files   https://%s:%s\n  search  https://%s:%s\n  panel   https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE1" "$LAN_HOST" "$PORT_EDGE2" "$LAN_HOST" "$PORT_EDGE3" "$LAN_HOST" "$PORT_EDGE4"
        else
          ACCESS_WIFI='the wifi sees nothing: your apps answer only to your mesh devices'
        fi
      else
        printf -v ACCESS_LAN_LINES 'home wifi:\n  photos  https://%s:%s\n  files   https://%s:%s\n  search  https://%s:%s\n  panel   https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE1" "$LAN_HOST" "$PORT_EDGE2" "$LAN_HOST" "$PORT_EDGE3" "$LAN_HOST" "$PORT_EDGE4"
        ACCESS_WIFI=''
      fi
    cat > "$MYREDOUBT/Access.txt" <<ACCESS
Redoubt - your private cloud, ready.

Photos:   https://${APPS_HOST}:$PORT_EDGE1
Files:    https://${APPS_HOST}:$PORT_EDGE2
Search:   https://${APPS_HOST}:$PORT_EDGE3
Panel:    $PANEL_LINE
Ad shield: https://redoubt.lan:$PORT_EDGE5/admin

$ACCESS_LAN_LINES$ACCESS_WIFI
$ACCESS_MESH

Ads off everywhere: set your devices' DNS to $LAN_IP (router or wifi settings) and the whole home network blocks ads and trackers.

Phone cert: http://${MESH_IP:-$LAN_IP}:8086/ca (open it on the phone and install it)

user: $OWNER_USER
email: $IMMICH_EMAIL
pass: $OWNER_PASS

$MOBILE_BLOCK$ACCESS_GUIDE_LINE
ACCESS
    chmod 600 "$MYREDOUBT/Access.txt"
    # terminal QRs for machines without a screen: the CLI prints them
    # named and scannable straight off the monitor
    cat > /etc/redoubt/qr-payloads.txt <<QRPAY
panel (mesh)|$PANEL_URL_MESH
panel (home wifi)|https://$LAN_HOST:$PORT_EDGE4
mobile cert|http://${NETBIRD_IP:-$LAN_IP}:8086/ca
QRPAY
    if [ "$MESH_MODE" = "selfhost" ]; then
      printf 'mesh management|%s\n' "$MESH_BASE" >> /etc/redoubt/qr-payloads.txt
      if [ -f "$STACKDIR/mobile-mesh-key.txt" ]; then
        MK=$(tr -d '\n' < "$STACKDIR/mobile-mesh-key.txt")
        [ -n "$MK" ] && printf 'mobile mesh key|%s\n' "$MK" >> /etc/redoubt/qr-payloads.txt
      fi
    fi
    chmod 600 /etc/redoubt/qr-payloads.txt
LAN_QR_PHOTOS='<div class="qr"><img src="Scan Me/photos-lan.png" alt=""><small>home wifi: scan</small></div>'
LAN_QR_FILES='<div class="qr"><img src="Scan Me/files-lan.png" alt=""><small>home wifi: scan</small></div>'
LAN_QR_SEARCH='<div class="qr"><img src="Scan Me/search-lan.png" alt=""><small>home wifi: scan</small></div>'
LAN_QR_PANEL='<div class="qr"><img src="Scan Me/panel-lan.png" alt=""><small>panel (same wifi): scan</small></div>'
LAN_LINE_PHOTOS="<p>Server (home wifi): <code>https://$LAN_HOST:$PORT_EDGE1</code></p>"
LAN_LINE_FILES="<p>Server (home wifi): <code>https://$LAN_HOST:$PORT_EDGE2</code></p>"
LAN_LINE_SEARCH="<p>Server (home wifi): <code>https://$LAN_HOST:$PORT_EDGE3</code></p>"
PANEL_LINK="https://$APPS_HOST:$PORT_EDGE4"

cp /var/lib/redoubt/caddy-local/favicon.ico "$MYREDOUBT/favicon.ico" 2>/dev/null || true

cat > "$MYREDOUBT/Start Here.html" <<WELCOMEHTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="favicon.ico" type="image/x-icon">
<title>Welcome to your Redoubt</title>
<link rel="icon" href="data:image/png;base64,$LOGO_B64">
<style>
:root { --bg:#000; --panel:#0a0e0b; --emerald:#34d399; --emerald-dim:#1e5c43; --ink:#e5f2ea; --muted:#8fa396; --line:#16251c; }
* { box-sizing:border-box; margin:0; }
body { background:var(--bg); color:var(--ink); font-family:ui-monospace,"Cascadia Mono",Consolas,"Segoe UI",monospace; line-height:1.6; padding:30px 18px 60px; }
.wrap { max-width:720px; margin:0 auto; position:relative; z-index:1; }
h1 { font-size:26px; margin:14px 0 4px; }
h1 em { font-style:normal; color:var(--emerald); }
h1::before { content:"$ "; color:var(--emerald); }
.lead { color:var(--muted); font-size:15px; margin-bottom:28px; }
.lead::before { content:"\279C "; color:var(--emerald); }
.card { background:var(--panel); border:1px solid var(--line); border-radius:10px; margin-bottom:16px; overflow:hidden; box-shadow:0 14px 40px rgba(0,0,0,.5); }
.card .bar { display:flex; align-items:center; gap:7px; padding:9px 14px; border-bottom:1px solid var(--line); background:rgba(255,255,255,.02); }
.card .bar i { width:11px; height:11px; border-radius:50%; display:block; }
.card .bar i:nth-child(1) { background:#3b1d1d; }
.card .bar i:nth-child(2) { background:#3a3318; }
.card .bar i:nth-child(3) { background:#1d3b2a; }
.card .bar span { margin-left:8px; font-size:12px; color:var(--muted); }
.card .body { padding:18px; display:flex; gap:18px; align-items:center; flex-wrap:wrap; }
.card .txt { flex:1; min-width:230px; }
.card h2 { font-size:16px; margin-bottom:5px; color:var(--emerald); }
.card h2::before { content:"# "; color:var(--emerald-dim); }
.card p { color:var(--muted); font-size:14px; }
.card p a { color:var(--emerald); }
.card img { width:150px; height:150px; background:#fff; padding:6px; border-radius:8px; }
.card .qr { text-align:center; }
.card .qr small { display:block; color:var(--muted); font-size:11px; margin-top:4px; }
.note { background:var(--panel); border:1px solid var(--line); padding:14px 16px; border-radius:8px; color:var(--muted); font-size:14px; margin:18px 0; }
.note strong { color:var(--emerald); }
.cert-step { font-size:14px; line-height:1.6; }
.cert-step ol { margin:4px 0 8px 20px; padding:0; }
.cert-step li { margin-bottom:7px; color:var(--muted); }
.cert-step li strong { color:var(--ink); }
.foot { color:var(--muted); font-size:13px; margin-top:30px; text-align:center; }
.foot::before { content:"$ exit "; color:var(--emerald); }
code { background:var(--line); padding:2px 7px; border-radius:5px; font-size:.9em; word-break:break-all; }
@media (max-width:560px) {
  body { padding:18px 12px 44px; }
  h1 { font-size:22px; }
  .lead { font-size:14px; margin-bottom:22px; }
  .card .body { padding:14px; flex-direction:column; align-items:flex-start; gap:12px; }
  .card h2 { font-size:15px; }
  .card p { font-size:13.5px; }
  .card img { width:108px; height:108px; }
  .card .qr { display:inline-block; margin:3px; text-align:center; }
  .cert-step ol { margin-left:16px; }
  .note { font-size:13.5px; padding:12px 14px; }
  .foot { font-size:12px; }
}
#sh-rain { position: fixed; inset: 0; z-index: 0; pointer-events: none; }
#sh-cosmos { position: fixed; inset: 0; z-index: 0; pointer-events: none; }
#sh-dialog { display: none; position: fixed; top: 50%; left: 50%; transform: translate(-50%, -50%); z-index: 1000; background: var(--panel); border: 1px solid var(--emerald); border-radius: 12px; padding: 22px 26px; max-width: 340px; color: var(--ink); cursor: pointer; }
#sh-dialog-msg { margin: 0; font-size: 15px; line-height: 1.5; }
</style>
</head>
<body>
<canvas id="sh-cosmos"></canvas>
<div class="wrap">
<h1>Welcome to your <em>Redoubt</em></h1>
<p class="lead">This machine is your private cloud. Everything on it belongs to you and your family. Nobody else can see any of it, not even us.</p>

<div class="card">
  <div class="bar"><i></i><i></i><i></i><span>redoubt@netbird:~</span></div>
  <div class="body">
  <div class="txt">$MESH_CARD_BODY
  </div>
  <div class="qr"><img src="Scan Me/netbird.png" alt=""><small>$NETBIRD_QR_LABEL</small></div>
  <div class="qr"><img src="Scan Me/netbird-ios.png" alt=""><small>NetBird iPhone: scan</small></div>
  <div class="qr"><img src="Scan Me/netbird-android.png" alt=""><small>NetBird Android: scan</small></div>
  </div>
</div>

<div class="card">
  <div class="bar"><i></i><i></i><i></i><span>redoubt@ca:~</span></div>
  <div class="body">
  <div class="txt cert-step">
    <h2>Your certificate: the full guide</h2>
    <p>You usually just scan the cert QR above. These steps are here only if your phone asks. One certificate per machine, tied to this PC. If you reinstall Redoubt, the certificate stays the same, so the phone installs it once and never again.</p>
    <p style="margin-top:10px">Link does not open? While your phone is on this wifi, use the local address instead; it needs no DNS at all: <code>$LAN_CERT_URL</code></p>
    <p style="margin-top:10px"><strong style="color:var(--ink)">iPhone: 4 steps</strong></p>
    <ol>
      <li>Open <strong>Safari</strong> (only Safari) and go to <a href="$CERT_URL" style="color:var(--emerald)">your Redoubt link</a>. Allow the profile download.</li>
      <li><strong>Settings &gt; General &gt; VPN &amp; Device Management</strong> &rarr; tap the <em>Redoubt Local CA</em> profile &rarr; <strong>Install</strong> (top right). It asks for your unlock code. That is normal.</li>
      <li>The step everyone forgets: <strong>Settings &gt; General &gt; About &gt; Certificate Trust Settings</strong> &rarr; turn <strong>ON</strong> Redoubt Local CA.</li>
      <li>Done. Open your photo and file links.</li>
    </ol>
    <p style="margin-top:10px"><strong style="color:var(--ink)">Android: 4 steps</strong></p>
    <ol>
      <li>Open <strong>Firefox</strong> and go to <a href="$CERT_URL" style="color:var(--emerald)">your Redoubt link</a>. The file lands in Downloads.</li>
      <li><strong>Settings &gt; Security &gt; More security settings &gt; Encryption &amp; credentials &gt; Install a certificate &gt; CA certificate</strong>. (The exact path varies by brand. Samsung hides it under <em>Biometrics &amp; security</em>.)</li>
      <li>The phone warns it is risky: that is <strong>YOUR</strong> certificate, not a third party's. Confirm with your PIN or fingerprint.</li>
      <li>Done. Use Firefox for your Redoubt links.</li>
    </ol>
  </div>
  <div class="qr"><img src="Scan Me/cert.png" alt=""><small>certificate: scan</small></div>
  </div>
</div>

<div class="card">
  <div class="bar"><i></i><i></i><i></i><span>redoubt@photos:~</span></div>
  <div class="body">
  <div class="txt">
    <h2>Your photos</h2>
    <p>Install the app with the QR below, then open the server address and sign in with your user and password (both are in Access.txt). Your photos back up by themselves from now on.</p>
    <p style="margin-top:6px">$MESH_SERVER_LABEL: <code>$PHOTOS_URL_MESH</code></p>
    $LAN_LINE_PHOTOS
  </div>
  <div class="qr"><img src="Scan Me/immich-ios.png" alt=""><small>iPhone app: scan</small></div>
  <div class="qr"><img src="Scan Me/immich-android.png" alt=""><small>Android app: scan</small></div>
  <div class="qr"><img src="Scan Me/photos.png" alt=""><small>$MESH_QR_LABEL</small></div>
  $LAN_QR_PHOTOS
  </div>
</div>

<div class="card">
  <div class="bar"><i></i><i></i><i></i><span>redoubt@files:~</span></div>
  <div class="body">
  <div class="txt">
    <h2>Your files</h2>
    <p>It works like Dropbox, but the files stay on this machine. Install the app with the QR, open the server address, and sign in. The app asks for <strong>Account name or email</strong>: use the email from Access.txt. Your folders sync across every device.</p>
    <p style="margin-top:6px">$MESH_SERVER_LABEL: <code>$FILES_URL_MESH</code></p>
    $LAN_LINE_FILES
  </div>
  <div class="qr"><img src="Scan Me/nextcloud-ios.png" alt=""><small>iPhone app: scan</small></div>
  <div class="qr"><img src="Scan Me/nextcloud-android.png" alt=""><small>Android app: scan</small></div>
  <div class="qr"><img src="Scan Me/files.png" alt=""><small>$MESH_QR_LABEL</small></div>
  $LAN_QR_FILES
  </div>
</div>

<div class="card">
  <div class="bar"><i></i><i></i><i></i><span>redoubt@search:~</span></div>
  <div class="body">
  <div class="txt">
    <h2>Your private search</h2>
    <p>Open this address in your browser (on this machine or on your phone) and your searches stay on this machine.</p>
    <p style="margin-top:6px">$MESH_SERVER_LABEL: <code>$SEARCH_URL_MESH</code></p>
    $LAN_LINE_SEARCH
  </div>
  <div class="qr"><img src="Scan Me/search.png" alt=""><small>$MESH_QR_LABEL</small></div>
  $LAN_QR_SEARCH
  </div>
</div>

<div class="card">
  <div class="bar"><i></i><i></i><i></i><span>redoubt@panel:~</span></div>
  <div class="body">
  <div class="txt">
    <h2>Your panel: everything behind one door</h2>
    <p>Open <a href="$PANEL_LINK" style="color:var(--emerald)"><code>$PANEL_LINK</code></a> and sign in. Your login is the same everywhere: the user, the password and the mesh keys all live in <strong>Access.txt</strong> in this folder. Your Photos, Files and Search are one tap away, on this computer and on your phone.</p>
  </div>
  <div class="qr"><img id="qr-egg" src="Scan Me/panel.png" alt=""><small>panel: scan</small></div>
  $LAN_QR_PANEL
  </div>
</div>

<div class="note">
  <strong>On this computer:</strong> double-click <strong>Open Panel</strong> in this folder; it is the one door to everything. <strong>Open Photos</strong>, <strong>Open Files</strong> and <strong>Open Search</strong> jump straight into each app.
</div>

<div class="note">
  <strong>If you give this machine away</strong>, wipe the stack (run the cleaner from the install, or remove <code>/var/lib/redoubt</code> and <code>/etc/redoubt</code>) and the next owner gets a brand-new cloud of their own.
</div>

<div class="note">
  <strong>Questions?</strong> Access.txt and Welcome Guide.txt in this folder have every address and step.
</div>

<div class="foot">Redoubt &middot; your data stays yours.</div>
</div>
<canvas id="sh-rain" aria-hidden="true"></canvas>
<div id="sh-dialog" aria-hidden="true"><p id="sh-dialog-msg"></p></div>
<script>
// The cosmos: a quiet starfield with a rare shooting star. Canvas is
// behind everything, so it costs one screen-sized element and a frame
// loop; nothing heavy for a file that already carries the QR art.
(function () {
  var cv = document.getElementById('sh-cosmos');
  if (!cv) return;
  var cx = cv.getContext('2d'), stars = [], shoot = null, W = 0, H = 0;
  function size() {
    var dpr = window.devicePixelRatio || 1;
    W = window.innerWidth;
    H = window.innerHeight;
    cv.width = Math.round(W * dpr);
    cv.height = Math.round(H * dpr);
    cx.setTransform(dpr, 0, 0, dpr, 0, 0);
    var n = Math.min(140, Math.floor(W * H / 9000));
    stars = [];
    for (var i = 0; i < n; i++) {
      stars.push({ x: Math.random() * W, y: Math.random() * H,
        r: Math.random() * 1.1 + 0.3, ph: Math.random() * 6.28,
        sp: Math.random() * 0.12 + 0.02 });
    }
  }
  function frame() {
    cx.clearRect(0, 0, W, H);
    for (var i = 0; i < stars.length; i++) {
      var s = stars[i];
      s.y += s.sp; s.ph += 0.02;
      if (s.y > H + 4) { s.y = -4; s.x = Math.random() * W; }
      var a = 0.22 + Math.abs(Math.sin(s.ph)) * 0.5;
      cx.fillStyle = 'rgba(110,231,183,' + a.toFixed(2) + ')';
      cx.beginPath(); cx.arc(s.x, s.y, s.r, 0, 6.283); cx.fill();
    }
    if (!shoot && Math.random() < 0.004) {
      shoot = { x: Math.random() * W * 0.8, y: Math.random() * H * 0.4,
        vx: 5 + Math.random() * 3, vy: 2.5 + Math.random() * 1.5, life: 0 };
    }
    if (shoot) {
      shoot.life++; shoot.x += shoot.vx; shoot.y += shoot.vy;
      cx.strokeStyle = 'rgba(110,231,183,0.85)'; cx.lineWidth = 1.6;
      cx.beginPath();
      cx.moveTo(shoot.x, shoot.y);
      cx.lineTo(shoot.x - shoot.vx * 9, shoot.y - shoot.vy * 9);
      cx.stroke();
      if (shoot.life > 60) shoot = null;
    }
    requestAnimationFrame(frame);
  }
  size();
  window.addEventListener('resize', size);
  frame();
})();
// the panel QR holds one more gate: four taps wake the rain. the dialog
// speaks only the first time, then the egg stays quiet. self-contained.
(function () {
  var cv = document.getElementById("sh-rain");
  var dlg = document.getElementById("sh-dialog");
  var dmsg = document.getElementById("sh-dialog-msg");
  if (!cv || !dlg || !dmsg) return;
  var ctx = cv.getContext("2d");
  var W = 0, H = 0;
  function size() { W = cv.width = window.innerWidth; H = cv.height = window.innerHeight; }
  size();
  window.addEventListener("resize", size);
  var chars = "アイウエオカキクケコサシスセソタチツテトナニヌネノ0123456789ABCDEF".split("");
  function layer(n, speed, sz, alpha, blur, trail) {
    var drops = [];
    for (var i = 0; i < n; i++) drops.push({ x: Math.random() * W, y: Math.random() * H, s: sz * (0.7 + Math.random() * 0.6) });
    return { drops: drops, speed: speed, size: sz, alpha: alpha, blur: blur, trail: trail };
  }
  var far = layer(60, 0.6, 10, 0.22, 2.5, 8);
  var mid = layer(50, 1.1, 14, 0.45, 1.2, 14);
  var near = layer(36, 1.9, 18, 0.85, 0, 22);
  var rainOn = false;
  function resetRain() {
    [far, mid, near].forEach(function (L) {
      L.drops.forEach(function (d, i) {
        d.y = -40 - (i / L.drops.length) * H * 0.5;
      });
    });
  }
  function draw(dt) {
    ctx.clearRect(0, 0, W, H);
    [far, mid, near].forEach(function (L) {
      ctx.font = L.size + "px monospace";
      ctx.filter = L.blur ? "blur(" + L.blur + "px)" : "none";
      L.drops.forEach(function (d) {
        d.y += L.speed * dt * 60;
        if (d.y > H + 40) { d.y = -40; d.x = Math.random() * W; }
        var c = chars[(Math.random() * chars.length) | 0];
        ctx.fillStyle = "rgba(52,211,153," + L.alpha + ")";
        ctx.fillText(c, d.x, d.y);
        if (L.trail) {
          for (var t = 1; t <= L.trail; t++) {
            ctx.fillStyle = "rgba(52,211,153," + (L.alpha * (1 - t / (L.trail + 1))) + ")";
            ctx.fillText(c, d.x, d.y - t * L.size * 1.05);
          }
        }
      });
      ctx.filter = "none";
    });
  }
  function loop(ts) {
    var dt = Math.min(0.05, (ts - (loop.last || ts)) / 1000);
    loop.last = ts;
    if (rainOn) draw(dt);
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
  var taps = 0;
  var tapUntil = 0;
  var found = false;
  var qr = document.getElementById("qr-egg");
  if (qr) {
    qr.addEventListener("click", function () {
      var now = Date.now();
      if (now > tapUntil) taps = 0;
      tapUntil = now + 2000;
      taps++;
      if (taps >= 4) {
        taps = 0;
        rainOn = true;
        resetRain();
        if (!found) {
          found = true;
          dmsg.textContent = "Four taps. Most people scan and move on, you pressed. That instinct is why you are here, why this machine is yours, and why nothing on it leaves home. Curiosity is the key to everything.";
          dlg.style.display = "block";
          dlg.setAttribute("aria-hidden", "false");
        }
      }
    });
  }
  dlg.addEventListener("click", function () {
    dlg.style.display = "none";
    dlg.setAttribute("aria-hidden", "true");
  });
})();
</script>
</body>
</html>

WELCOMEHTML
    chown -R "$(stat -c '%u:%g' "$OWNER_HOME")" "$MYREDOUBT" 2>/dev/null || true
    dbg "OK: the My Redoubt folder is in your Documents"
  fi
  # These milestones live outside the welcome conditional. On a repatch
  # the work is skipped but the bar still walks to 100, never stopping at 50.
  step "your own certificate authority"
  step "your folder, ready"
  draw_bar 100 "✓ your cloud, done"
  # Stop the painter and land the newline, so the finished line stays put.
  if [ -n "$ANIM_PID" ]; then
    kill -9 "$ANIM_PID" 2>/dev/null
    ANIM_PID=""
  fi
  # One last paint (the animator may have died mid-frame), then the newline.
  draw_line
  echo "" >&3
  rm -f "$BAR_STATE" 2>/dev/null || true

  # hand the console back to the system's usual loglevel
  [ -n "$QUIET_PK" ] && sysctl -w kernel.printk="$QUIET_PK" >/dev/null 2>&1

  # The vault (Access.txt) is the one truth the customer types. A
  # re-run can hold a divergent pass in the env (apps then sign up with
  # the wrong key), so realign every app pass before any sign-up.
  VAULT_PASS=$(awk -F': ' '/^[[:space:]]*pass:/ {print $2; exit}' "${MYREDOUBT:-}/Access.txt" 2>/dev/null || true)
  if [ -n "$VAULT_PASS" ]; then
    OWNER_PASS="$VAULT_PASS"
    IMMICH_PASS="$VAULT_PASS"
    DOCKGE_PASS="$VAULT_PASS"
  fi
  # 8c) First-run setup the client never sees. The immich admin signs up
  #     through its own API (idempotent; a 400 means it already exists)
  #     and the nextcloud admin envs leave the compose once installed, so
  #     later restarts boot clean. Leave the envs in place and the
  #     nextcloud entrypoint walks the "reinstall / CAN_INSTALL" path and
  #     dies in a restart loop.
  if command -v curl >/dev/null 2>&1 && [ -n "${OWNER_PASS:-}" ]; then
    IMMICH_ADMIN='{"email":"'"${IMMICH_EMAIL:-owner@redoubt.local}"'","password":"'"$OWNER_PASS"'","name":"'"${OWNER_USER:-owner}"'"}'
    for i in $(seq 1 30); do
      RC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST "http://127.0.0.1:$PORT_IMMICH/api/auth/admin-sign-up" -H "Content-Type: application/json" -d "$IMMICH_ADMIN" 2>/dev/null)
      case "$RC" in 200|201) echo "OK: immich admin created"; break ;; 400) echo "OK: immich admin already set"; break ;; esac
      sleep 10
    done
    NC_OK=""
    # nextcloud 35 no longer writes 'installed' => true to its config
    # (the $CONFIG format changed) and its entrypoint does not
    # auto-install from the admin envs anymore: it only prepares
    # autoconfig.php and waits for a wizard nobody can click in a
    # scripted install. Ask occ for the truth and, when the instance
    # is still empty, run the install by CLI with the same admin and
    # database the compose declares.
    NC_OK=$(docker exec redoubt-nextcloud-1 php occ status 2>/dev/null | grep -c "installed: true" || true)
    if [ "${NC_OK:-0}" -lt 1 ]; then
      NC_DBPASS=""
      for i in $(seq 1 6); do
        NC_DBPASS=$(docker exec redoubt-nextcloud-1 php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["dbpassword"] ?? "";' 2>/dev/null || true)
        [ -n "$NC_DBPASS" ] && break
        sleep 10
      done
      if [ -n "$NC_DBPASS" ]; then
        docker exec -u www-data redoubt-nextcloud-1 php occ maintenance:install --admin-user "$OWNER_USER" --admin-pass "$OWNER_PASS" --database pgsql --database-name nextcloud --database-user nextcloud --database-pass "$NC_DBPASS" --database-host redoubt-nextcloud-db-1 >/dev/null 2>&1 || true
        NC_OK=$(docker exec redoubt-nextcloud-1 php occ status 2>/dev/null | grep -c "installed: true" || true)
      fi
        if [ "${NC_OK:-0}" -lt 1 ]; then
          # the persisted config can carry a stale db password after a
          # container recreate: fall back to the password the live DB
          # container actually uses, and only warn if that fails too
          NC_DBPASS_LIVE=$(docker inspect redoubt-nextcloud-db-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep POSTGRES_PASSWORD | cut -d= -f2)
          if [ -n "$NC_DBPASS_LIVE" ]; then
            _NC_INSTALL_OUT=$(docker exec -u www-data redoubt-nextcloud-1 php occ maintenance:install --admin-user "$OWNER_USER" --admin-pass "$OWNER_PASS" --database pgsql --database-name nextcloud --database-user nextcloud --database-pass "$NC_DBPASS_LIVE" --database-host redoubt-nextcloud-db-1 2>&1 || true)
            NC_OK=$(docker exec redoubt-nextcloud-1 php occ status 2>/dev/null | grep -c "installed: true" || true)
          fi
          if [ "${NC_OK:-0}" -lt 1 ] && [ -n "$NC_DBPASS_LIVE" ]; then
            # the postgres role freezes the password of its first init:
            # an interrupted pass (power cut, a frozen VM, a re-cycled
            # env under a surviving DB) leaves the role on an older
            # generation while the compose and the env moved on. Align
            # the role to the live password and retry once: the install
            # then has exactly one truth.
            docker exec -e PGPASSWORD="$NC_DBPASS_LIVE" redoubt-nextcloud-db-1 \
              psql -U nextcloud -h 127.0.0.1 -d nextcloud \
              -c "ALTER USER nextcloud WITH PASSWORD '$NC_DBPASS_LIVE'" >/dev/null 2>&1 || true
            _NC_INSTALL_OUT=$(docker exec -u www-data redoubt-nextcloud-1 php occ maintenance:install --admin-user "$OWNER_USER" --admin-pass "$OWNER_PASS" --database pgsql --database-name nextcloud --database-user nextcloud --database-pass "$NC_DBPASS_LIVE" --database-host redoubt-nextcloud-db-1 2>&1 || true)
            NC_OK=$(docker exec redoubt-nextcloud-1 php occ status 2>/dev/null | grep -c "installed: true" || true)
          fi
          if [ "${NC_OK:-0}" -lt 1 ] && [ -n "$NC_DBPASS_LIVE" ]; then
            # a half-finished install can leave partial tables owned by
            # the admin role (oc_admin): the next install then dies with
            # "permission denied" even with the right password. No users
            # in the DB means the instance never carried data: drop and
            # recreate the database, then run the install on the clean
            # slate. "unknown" (the users table does not exist yet) is
            # safe too: a missing table cannot hold user data.
            _NC_USERS=$(docker exec -e PGPASSWORD="$NC_DBPASS_LIVE" redoubt-nextcloud-db-1 \
              psql -U nextcloud -h 127.0.0.1 -d nextcloud -tAc "SELECT count(*) FROM oc_users" 2>/dev/null || echo "unknown")
            if [ "$_NC_USERS" = "0" ] || [ "$_NC_USERS" = "unknown" ]; then
              docker exec -e PGPASSWORD="$NC_DBPASS_LIVE" redoubt-nextcloud-db-1 \
                psql -U nextcloud -h 127.0.0.1 -d postgres -tAc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'nextcloud' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true
              docker exec -e PGPASSWORD="$NC_DBPASS_LIVE" redoubt-nextcloud-db-1 \
                psql -U nextcloud -h 127.0.0.1 -d postgres -c "DROP DATABASE nextcloud" >/dev/null 2>&1 || true
              docker exec -e PGPASSWORD="$NC_DBPASS_LIVE" redoubt-nextcloud-db-1 \
                psql -U nextcloud -h 127.0.0.1 -d postgres -c "CREATE DATABASE nextcloud OWNER nextcloud" >/dev/null 2>&1 || true
              _NC_INSTALL_OUT=$(docker exec -u www-data redoubt-nextcloud-1 php occ maintenance:install --admin-user "$OWNER_USER" --admin-pass "$OWNER_PASS" --database pgsql --database-name nextcloud --database-user nextcloud --database-pass "$NC_DBPASS_LIVE" --database-host redoubt-nextcloud-db-1 2>&1 || true)
              NC_OK=$(docker exec redoubt-nextcloud-1 php occ status 2>/dev/null | grep -c "installed: true" || true)
            fi
          fi
        fi
    fi
    if [ "${NC_OK:-0}" -ge 1 ]; then
      sed -i '/NEXTCLOUD_ADMIN_USER:/d; /NEXTCLOUD_ADMIN_PASSWORD:/d' "$STACKDIR/docker-compose.yml"
      docker compose -f "$STACKDIR/docker-compose.yml" up -d nextcloud >/dev/null 2>&1
      # The edge is https, so nextcloud has to trust the LAN/mesh
      # addresses (the welcome links) and speak https in its own URLs and
      # redirects, or the user gets "untrusted domain" / "http while https
      # expected" pages. Each domain gets its own index; the no-index form
      # would keep overwriting the first slot. The machine name and the
      # split-DNS names are in too: https://redoubt.lan:port and
      # https://redoubt.remote:port are first-class addresses.
      MESH_IP_NC="${NETBIRD_IP:-$LAN_IP}"
      NC_IDX=2
      for D in "$LAN_IP" "$LAN_IP:$PORT_EDGE2" "$MESH_IP_NC" "$MESH_IP_NC:$PORT_EDGE2" "$(hostname)" "$(hostname):$PORT_EDGE2" "redoubt.lan" "redoubt.lan:$PORT_EDGE2" "redoubt.remote" "redoubt.remote:$PORT_EDGE2"; do
        [ -n "$D" ] || continue
        HAVE=$(docker exec -u www-data redoubt-nextcloud-1 php occ config:system:get trusted_domains 2>/dev/null | grep -cF "$D" || true)
        if [ "${HAVE:-0}" = "0" ]; then
          docker exec -u www-data redoubt-nextcloud-1 php occ config:system:set trusted_domains "$NC_IDX" --value="$D" >/dev/null 2>&1 || true
        fi
        NC_IDX=$((NC_IDX+1))
      done
      docker exec -u www-data redoubt-nextcloud-1 php occ config:system:set overwriteprotocol --value="https" >/dev/null 2>&1 || true
      dbg "OK: nextcloud trusted domains + https protocol set for the edge"
      dbg "OK: nextcloud installed - admin envs stripped for clean restarts"
    else
      dbg "WARN: nextcloud did not install (last error: $(printf '%s' "${_NC_INSTALL_OUT:-no error captured}" | grep -vE '^\s*$' | tail -1 | cut -c1-160))"
    fi
    # Dockge keeps its own credential. Inject it straight into its user
    # table with dockge's own libs (bcrypt, 10 rounds, same as its setup
    # flow), so the stack manager asks for a password like every other
    # app. The upsert also covers re-runs: the password gets refreshed,
    # not duplicated.
    # dockge keeps sessions in memory: a re-run must not bounce the
    # container when the owner row already exists, or the customer
    # logs in again after every update
    DOCKGE_HAS=$(docker exec redoubt-dockge-1 node -e 'require("@louislam/sqlite3"); const d=new (require("@louislam/sqlite3").verbose()).Database("/app/data/dockge.db"); d.get("SELECT COUNT(*) AS c FROM user WHERE username = ? AND active = 1", ["owner"], function (e, r) { console.log(r && r.c ? r.c : 0); d.close(); });' 2>/dev/null)
    if [ "$DOCKGE_HAS" = "1" ]; then
      dbg "OK: dockge owner already set (session kept)"
    else
      DOCKGE_OK=0
      for i in $(seq 1 30); do
        if docker exec redoubt-dockge-1 node -e 'require("@louislam/sqlite3")' >/dev/null 2>&1; then
          docker exec -e DP="$DOCKGE_PASS" redoubt-dockge-1 node -e '
const sqlite3 = require("@louislam/sqlite3").verbose();
const bcrypt = require("bcryptjs");
const db = new sqlite3.Database("/app/data/dockge.db");
db.configure("busyTimeout", 10000);
const hash = bcrypt.hashSync(process.env.DP, 10);
db.run("INSERT INTO user (username, password, active) VALUES (?, ?, 1) ON CONFLICT(username) DO UPDATE SET password = excluded.password", ["owner", hash], function (err) { if (err) { console.error("dockge user: " + err.message); process.exit(1); } db.close(); });
' >/dev/null 2>&1 && dbg "OK: dockge credential injected" && DOCKGE_OK=1 && break
        fi
        sleep 10
      done
      # Dockge decides "first run: create admin" at boot. Restart it
      # so the injected owner is seen and the screen asks to log in,
      # not create one.
      if [ "$DOCKGE_OK" = "1" ]; then
        docker restart redoubt-dockge-1 >/dev/null 2>&1 || true
        dbg "OK: dockge restarted - it asks for the owner, not a new admin"
      fi
    fi
  fi

  cat > "$WELCOME/index.html" <<WELCOME
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome to your Redoubt</title>
<link rel="icon" href="data:image/png;base64,$LOGO_B64">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%230a0e0b'/%3E%3Ctext x='32' y='45' font-family='system-ui' font-size='40' font-weight='700' fill='%2334d399' text-anchor='middle'%3ER%3C/text%3E%3C/svg%3E">
<style>
:root { --bg:#000; --panel:#0a0e0b; --emerald:#34d399; --ink:#e5f2ea; --muted:#8fa396; --line:#16251c; }
* { box-sizing:border-box; margin:0; }
body { background:var(--bg); color:var(--ink); font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif; line-height:1.6; padding:30px 18px 60px; }
.wrap { max-width:720px; margin:0 auto; }
h1 { font-size:30px; margin:14px 0 6px; }
h1 em { font-style:normal; color:var(--emerald); }
.lead { color:var(--muted); font-size:16px; margin-bottom:30px; }
.card { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:20px; margin-bottom:16px; display:flex; gap:18px; align-items:center; flex-wrap:wrap; }
.card .txt { flex:1; min-width:230px; }
.card h2 { font-size:18px; margin-bottom:5px; }
.card p { color:var(--muted); font-size:14.5px; }
.card img { width:150px; height:150px; background:#fff; padding:6px; border-radius:8px; }
.card .qr { text-align:center; }
.card .qr small { display:block; color:var(--muted); font-size:11px; margin-top:4px; }
.qr-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-top:16px; }
.qr-grid .qr { background:var(--surface,#10150f); border:1px solid var(--line); border-radius:8px; padding:14px 10px 12px; text-align:center; }
.qr-grid .qr img { width:124px; height:124px; background:#fff; padding:7px; border-radius:8px; box-sizing:border-box; }
.note { border-left:3px solid var(--emerald); background:var(--panel); padding:16px 18px; border-radius:0 10px 10px 0; color:var(--muted); font-size:14.5px; margin:22px 0; }
.note strong { color:var(--ink); }
.foot { color:var(--muted); font-size:13px; margin-top:30px; text-align:center; }
code { background:var(--line); padding:2px 7px; border-radius:5px; font-size:.9em; word-break:break-all; }
@media (max-width:520px) { .card { flex-direction:column; text-align:center; } }
</style>
</head>
<body>
<div class="wrap">
<h1>Welcome to your <em>Redoubt</em></h1>
<p class="lead">This machine is your private cloud. Everything on it belongs to you and your family. Nobody else can see it. Not even us.</p>

<div class="card">
  <div class="txt">
    <h2>Your photos</h2>
    <p>Install the app with the QR below, then open the server address and sign in with your user and password. Your photos back up by themselves from now on.</p>
    <p style="margin-top:6px">$MESH_SERVER_LABEL: <code>$PHOTOS_URL_MESH</code></p>
    $LAN_LINE_PHOTOS
  </div>
  <div class="qr"><img src="Scan Me/immich-ios.png" alt=""><small>iPhone app: scan</small></div>
  <div class="qr"><img src="Scan Me/immich-android.png" alt=""><small>Android app: scan</small></div>
  <div class="qr"><img src="Scan Me/photos.png" alt=""><small>$MESH_QR_LABEL</small></div>
</div>

<div class="card">
  <div class="txt">
    <h2>Your files</h2>
    <p>Like Dropbox, but yours. Install the app with the QR, sign in, and your folders sync across every device.</p>
    <p style="margin-top:6px">$MESH_SERVER_LABEL: <code>$FILES_URL_MESH</code></p>
    $LAN_LINE_FILES
  </div>
  <div class="qr"><img src="Scan Me/nextcloud-ios.png" alt=""><small>iPhone app: scan</small></div>
  <div class="qr"><img src="Scan Me/nextcloud-android.png" alt=""><small>Android app: scan</small></div>
  <div class="qr"><img src="Scan Me/files.png" alt=""><small>$MESH_QR_LABEL</small></div>
</div>

<div class="card">
  <div class="txt">
    <h2>Your private search</h2>
    <p>Open this address in your browser (on this machine or on your phone) and your searches never leave the house.</p>
    <p style="margin-top:6px">$MESH_SERVER_LABEL: <code>$SEARCH_URL_MESH</code></p>
    $LAN_LINE_SEARCH
  </div>
  <div class="qr"><img src="Scan Me/search.png" alt=""><small>$MESH_QR_LABEL</small></div>
</div>

<div class="card">
  <div class="txt">
    <h2>Your cloud from anywhere</h2>
$MESH_CARD_HTML
<h2>Phone setup</h2>
<div class="qr-grid">
<div class="qr"><img src="Scan Me/netbird-ios.png" alt=""><small>NetBird on iPhone: scan</small></div>
<div class="qr"><img src="Scan Me/netbird-android.png" alt=""><small>NetBird on Android: scan</small></div>
<div class="qr"><img src="Scan Me/cert.png" alt=""><small>root certificate: scan</small></div>
</div>
  </div>
</div>

<div class="note">
  <strong>First time on your phone?</strong> Your browser or app may ask about a certificate. Accept it. It is YOUR own Redoubt certificate, not a third party's. (To skip the warning entirely, install the <em>Redoubt Root CA.crt</em> from this folder.)
</div>

<div class="note">
  <strong>Your backup routine. One minute a month.</strong><br>
  Every night this machine makes a fresh encrypted copy of everything. Once a month, plug an external drive into the machine, let it finish, and keep that drive somewhere outside your home: a family member's house, your office, anywhere. We never see or touch your data, not even the backups.
</div>

<div class="note">
  <strong>Your credentials</strong> were shown when the kit finished and live in a root-only file on this machine. Keep them somewhere safe. You can change the password anytime from your account settings.
</div>

<div class="note">
  <strong>Your DNS is private, on purpose.</strong> This box resolves every name through the built-in ad shield, whose upstream speaks to Quad9 over an encrypted channel; no plain DNS ever leaves your house, and a firewall rule blocks leaks. To go back to your old DNS: <code>systemctl disable --now redoubt-dns-fw</code> and remove <code>/etc/systemd/resolved.conf.d/redoubt-quad9.conf</code>.
</div>

<p style="color:var(--muted); font-size:15px">Questions? Write to <code>hello@tryredoubt.com</code></p>
<div class="foot">Built and maintained by Naruto. No tracking. No analytics. No accounts with your data.</div>
</div>
</body>
</html>
WELCOME
  dbg "OK: welcome guide generated"
fi

# ============ private DNS lockdown (Quad9 over TLS, leak-proof) ============
# the tower is a server: it never needs the mesh DNS, and the agent
# rewrites resolv.conf to the mesh nameserver, which would bypass the
# ad shield on families without systemd-resolved. Legacy installs get
# one brief reconnect here, then the flag sticks in the agent state.

# ============ pass safety net: a live watcher for this section ============
# Everything from here on rewires how the machine reaches its network
# (mesh DNS, host resolver, leak firewall): a pass that dies right
# here would leave the box sealed. So the kit arms a local watchdog
# first: it snapshots the current connectivity state, then watches the
# pass. If it sees the pass die before completion, it rolls the box
# back to the snapshot. It is detection, not a timer: the watcher
# polls the pass pid and acts on death. A one-shot boot unit covers a
# power cut: on the next boot, if the pass never completed, it rolls
# back the same way and removes itself. Both are gone by the reveal.
if mkdir -p /etc/redoubt/.pass-snapshot 2>/dev/null; then
  chmod 700 /etc/redoubt/.pass-snapshot
  # the snapshot is the rollback target: copy every piece this section
  # may rewrite, and note which services were already on, so a rollback
  # restores exactly what was there, fresh box or previous install
  cp /etc/resolv.conf /etc/redoubt/.pass-snapshot/resolv.conf.bak 2>/dev/null || true
  [ -f /etc/systemd/resolved.conf.d/redoubt-quad9.conf ] \
    && cp /etc/systemd/resolved.conf.d/redoubt-quad9.conf /etc/redoubt/.pass-snapshot/resolved-quad9.conf.bak 2>/dev/null
  [ -f /etc/redoubt/nft-dns.conf ] \
    && cp /etc/redoubt/nft-dns.conf /etc/redoubt/.pass-snapshot/nft-dns.conf.bak 2>/dev/null
  # the active NetworkManager connection: name, device, dns and the
  # auto-dns flag, so a rollback can put them back without guessing
  if command -v nmcli >/dev/null 2>&1; then
    NM_SNAP=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$NM_SNAP" ]; then
      NM_SNAP_DEV=$(nmcli -g GENERAL.DEVICES connection show "$NM_SNAP" 2>/dev/null | head -1)
      NM_SNAP_DNS=$(nmcli -g ipv4.dns connection show "$NM_SNAP" 2>/dev/null | tr '\n' ' ')
      NM_SNAP_AUTO=$(nmcli -g ipv4.ignore-auto-dns connection show "$NM_SNAP" 2>/dev/null | tr '\n' ' ')
      printf '%s\t%s\t%s\t%s\n' "$NM_SNAP" "$NM_SNAP_DEV" "$NM_SNAP_DNS" "$NM_SNAP_AUTO" \
        > /etc/redoubt/.pass-snapshot/nmconn 2>/dev/null || true
    fi
  fi
  systemctl is-enabled redoubt-dns-fw >/dev/null 2>&1 && touch /etc/redoubt/.pass-snapshot/fw-enabled
  systemctl is-active redoubt-dns-fw >/dev/null 2>&1 && touch /etc/redoubt/.pass-snapshot/fw-active
  [ -f /etc/redoubt/nb-dns-off ] && touch /etc/redoubt/.pass-snapshot/nb-dns-off-existed
  # the watchdog itself: one standalone script, reused by the live
  # watcher and by the boot unit
  cat > /etc/redoubt/redoubt-emergency.sh <<'EMERGENCY'
#!/bin/bash
# Redoubt pass safety: roll the network state back to the snapshot
# taken at the start of the DNS lockdown section. Modes:
#   live  watch the pass pid; roll back if it dies before completion
#   boot  run once at boot; roll back if the pass never completed
SNAP=/etc/redoubt/.pass-snapshot
ELOG=/var/log/redoubt-emergency.log
say() { printf '%s\n' "$1" >> "$ELOG"; }

rollback() {
  # one rollback at a time: live and boot can race after a reboot
  exec 8>>/run/redoubt-emergency.lock
  flock -n 8 2>/dev/null || exit 0
  say "=== emergency rollback $(date '+%F %T') : $1 ==="
  # the dns a device is really using right now (one line, no secrets)
  nm_now() { nmcli -g IP4.DNS device show "$1" 2>/dev/null | tr '\n' ' '; }
  # mesh DNS back on: the snapshot predates the nb-dns-off flag this
  # section wrote, unless a previous install already had it
  if [ ! -f "$SNAP/nb-dns-off-existed" ] && [ -f /etc/redoubt/nb-dns-off ]; then
    rm -f /etc/redoubt/nb-dns-off
    if [ -f /var/lib/netbird/default.json ]; then
      NB=""
      for _C in /usr/local/bin/netbird /usr/bin/netbird /usr/sbin/netbird; do
        [ -x "$_C" ] && { NB="$_C"; break; }
      done
      [ -n "$NB" ] && timeout -k 5 60 "$NB" up >/dev/null 2>&1 || true
    fi
    say "netbird DNS restored"
  fi
  # the host resolver: put the previous drop-in back, or take this
  # section's pin away entirely
  if [ -f "$SNAP/resolved-quad9.conf.bak" ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    cp "$SNAP/resolved-quad9.conf.bak" /etc/systemd/resolved.conf.d/redoubt-quad9.conf 2>/dev/null || true
  else
    rm -f /etc/systemd/resolved.conf.d/redoubt-quad9.conf
  fi
  if systemctl is-active systemd-resolved --quiet 2>/dev/null; then
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
  fi
  say "host resolver restored"
  # NetworkManager: give the connection back its old dns, then reapply
  # (reapply never drops the link, so a rollback never cuts the owner)
  if [ -f "$SNAP/nmconn" ]; then
    IFS="$(printf '\t')" read -r NM_S NM_D NM_DNS NM_AUTO < "$SNAP/nmconn" 2>/dev/null || true
    if [ -n "${NM_S:-}" ]; then
      # older snapshots may lack the device: ask NetworkManager again
      [ -n "${NM_D:-}" ] || NM_D=$(nmcli -g GENERAL.DEVICES connection show "$NM_S" 2>/dev/null | head -1)
      say "nm snapshot: '$NM_S' dev='$NM_D' dns='$NM_DNS' auto='$NM_AUTO'"
      # at boot NetworkManager may still be waking: give it a beat to
      # be operational before touching the connection, or every restore
      # step bounces off a half-awake daemon (the failsafe runs early)
      _NM_T=0
      while [ "$_NM_T" -lt 30 ]; do
        nmcli -t -f RUNNING general status 2>/dev/null | grep -q '^running' && break
        sleep 2
        _NM_T=$((_NM_T+2))
      done
      nmcli con mod "$NM_S" ipv4.dns "$NM_DNS" ipv4.ignore-auto-dns "${NM_AUTO:-no}" >/dev/null 2>&1 || true
      # trust but verify: a few NetworkManager builds accept a reapply
      # without refetching the dns, leaving the shield pinned. Each step
      # checks the real device dns and escalates only when it is still
      # wrong, up to a forced clear and reconnect (the last resort).
      _OK=""
      if [ -n "${NM_D:-}" ] && nmcli device reapply "$NM_D" >/dev/null 2>&1; then
        sleep 2
        if ! printf '%s' "$(nm_now "$NM_D")" | grep -q '127\.0\.0\.1' || [ "${NM_DNS:-}" = "127.0.0.1" ]; then
          _OK="reapply"
        fi
      fi
      if [ -z "$_OK" ] && nmcli con up "$NM_S" >/dev/null 2>&1; then
        sleep 2
        if [ -z "${NM_D:-}" ] \
           || ! printf '%s' "$(nm_now "$NM_D")" | grep -q '127\.0\.0\.1' \
           || [ "${NM_DNS:-}" = "127.0.0.1" ]; then
          _OK="reconnect"
        fi
      fi
      if [ -z "$_OK" ]; then
        # the profile itself refused the restore: force it clear and
        # reconnect once more
        nmcli con mod "$NM_S" ipv4.dns "" ipv4.ignore-auto-dns no >/dev/null 2>&1 || true
        nmcli con up "$NM_S" >/dev/null 2>&1 || true
        sleep 2
        if [ -z "${NM_D:-}" ] \
           || ! printf '%s' "$(nm_now "$NM_D")" | grep -q '127\.0\.0\.1' \
           || [ "${NM_DNS:-}" = "127.0.0.1" ]; then
          _OK="forced"
        fi
      fi
      case "$_OK" in
        reapply)   say "NetworkManager dns restored (reapply)" ;;
        reconnect) say "NetworkManager dns restored (reconnect, the reapply had left the shield pinned)" ;;
        forced)    say "NetworkManager dns restored (forced clear and reconnect)" ;;
        *)         say "WARN: NetworkManager dns restore shaky; the device may stay on the ad shield" ;;
      esac
    fi
  fi
  # the leak firewall: previous installs get their conf and unit back;
  # fresh boxes get the table out and the unit off
  if [ -f "$SNAP/fw-enabled" ] || [ -f "$SNAP/fw-active" ]; then
    [ -f "$SNAP/nft-dns.conf.bak" ] && cp "$SNAP/nft-dns.conf.bak" /etc/redoubt/nft-dns.conf 2>/dev/null
    systemctl restart redoubt-dns-fw >/dev/null 2>&1 || true
    say "leak firewall restored"
  else
    nft delete table inet redoubt-dns 2>/dev/null || true
    systemctl disable --now redoubt-dns-fw >/dev/null 2>&1 || true
    say "leak firewall removed"
  fi
  # last resort for families where nothing above owns resolv.conf
  if [ -f "$SNAP/resolv.conf.bak" ] && [ ! -f "$SNAP/nmconn" ]; then
    if ! cmp -s "$SNAP/resolv.conf.bak" /etc/resolv.conf 2>/dev/null; then
      cp "$SNAP/resolv.conf.bak" /etc/resolv.conf 2>/dev/null || true
      say "resolv.conf restored"
    fi
  fi
  rm -f /etc/redoubt/.pass-in-progress
  # the boot unit has done its job: never run again, leave no trace
  if [ -f /etc/systemd/system/redoubt-failsafe.service ]; then
    rm -f /etc/systemd/system/redoubt-failsafe.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  # free the installer lock from an orphaned sentinel so the next pass
  # can take over without the stale-takeover dance. The lock file stays:
  # the kernel releases the flock when the sentinel dies, and removing
  # the file would let a third pass lock a fresh inode and dance
  # alongside (the takeover logic reads the pids, dead ones are stale)
  LPID=$(sed -n 2p /run/redoubt.lock 2>/dev/null)
  [ -n "$LPID" ] && kill "$LPID" 2>/dev/null || true
  rm -rf /etc/redoubt/.pass-snapshot
  say "=== rollback done ==="
}

case "$1" in
  live)
    MPID="$(head -1 /run/redoubt.lock 2>/dev/null)"
    LPID="$(sed -n 2p /run/redoubt.lock 2>/dev/null)"
    while :; do
      [ -f /etc/redoubt/.install-complete ] && exit 0
      if [ -n "$MPID" ] && ! kill -0 "$MPID" 2>/dev/null; then
        rollback "install died mid-run (pid $MPID gone)"
        [ -n "$LPID" ] && kill "$LPID" 2>/dev/null || true
        exit 1
      fi
      sleep 5
      MPID="$(head -1 /run/redoubt.lock 2>/dev/null)"
      LPID="$(sed -n 2p /run/redoubt.lock 2>/dev/null)"
    done
    ;;
  boot)
    if [ -f /etc/redoubt/.pass-in-progress ] && [ ! -f /etc/redoubt/.install-complete ]; then
      rollback "booted into a pass that never completed"
    else
      # nothing to fix: disarm quietly
      [ -f /etc/systemd/system/redoubt-failsafe.service ] \
        && rm -f /etc/systemd/system/redoubt-failsafe.service \
        && systemctl daemon-reload 2>/dev/null || true
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
EMERGENCY
  chmod 700 /etc/redoubt/redoubt-emergency.sh
  # boot cover for a power cut: one-shot, self-removing, no timer
  cat > /etc/systemd/system/redoubt-failsafe.service <<'FAILSAFE'
[Unit]
Description=Redoubt pass failsafe: restore the network if an install died mid-run
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/redoubt/redoubt-emergency.sh boot
[Install]
WantedBy=multi-user.target
FAILSAFE
  chmod 644 /etc/systemd/system/redoubt-failsafe.service
  systemctl daemon-reload
  systemctl enable redoubt-failsafe >/dev/null 2>&1 || true
  # arm the live watcher and mark the pass
  : > /etc/redoubt/.pass-in-progress
  chmod 600 /etc/redoubt/.pass-in-progress
  setsid nohup /bin/bash /etc/redoubt/redoubt-emergency.sh live >/dev/null 2>&1 &
  WATCH_PID=$!
  # btrfs and other slow-writeback filesystems can hold these writes in
  # the page cache for tens of seconds: a power cut right after this
  # point would lose the failsafe itself. Sync now, so the parachute is
  # on disk before this section changes the network below.
  sync
  dbg "OK: pass safety net armed (snapshot + live watchdog + boot failsafe)"
else
  dbg "WARN: could not snapshot the network state; this pass runs without the safety net"
fi

if [ ! -f /etc/redoubt/nb-dns-off ] && [ -x "$NBEXE" ]; then
  # a down+up only makes sense on an agent that already joined: a
  # NeedsLogin daemon has no config and a bare up hangs forever
  # waiting for a sign-in that never comes (the kit is key-only)
  if [ -f /var/lib/netbird/default.json ]; then
    "$NBEXE" down >/dev/null 2>&1 || true
    sleep 2
    timeout -k 5 120 "$NBEXE" up --disable-dns >/dev/null 2>&1 || true
  fi
  touch /etc/redoubt/nb-dns-off
  chmod 600 /etc/redoubt/nb-dns-off
fi
# Host resolver first. systemd-resolved (Debian/Ubuntu/Mint/Pop) points
# at the local pi-hole, so this machine filters ads too; the pi-hole
# forwards to the stack unbound, which keeps the encrypted Quad9 leg.
# Before writing the pin, check that 127.0.0.1:53 answers: pinning a
# dead nameserver takes the machine's DNS down with it, and the whole
# point of this
# section is that DNS never dies.
SHIELD_UP=0
_SHIELD_T=0
while [ "$_SHIELD_T" -lt 6 ]; do
  if (echo > /dev/tcp/127.0.0.1/53) 2>/dev/null; then
    SHIELD_UP=1
  elif python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",53),2); s.close()' >/dev/null 2>&1; then
    SHIELD_UP=1
  fi
  [ "$SHIELD_UP" = "1" ] && break
  _SHIELD_T=$((_SHIELD_T+1))
  sleep 5
done
if [ "$SHIELD_UP" = "1" ]; then
  if command -v resolvectl >/dev/null 2>&1 && systemctl is-active systemd-resolved --quiet; then
    mkdir -p /etc/systemd/resolved.conf.d
    # umask 077 would leave this dir root-only, and resolved drops to the
    # systemd-resolve user: the drop-ins would be silently ignored
    chmod 755 /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/redoubt-quad9.conf <<RESOLVED
[Resolve]
# the plain leg stays on loopback (the pi-hole); only the pi-hole's
# own upstream speaks to the outside, over unbound's encrypted Quad9
# channel. DoT is off for the local leg only: nothing plain ever
# leaves the machine
DNS=127.0.0.1
DNSOverTLS=no
# DNSSEC validation lives in unbound behind the pi-hole: nothing here
# needs to re-validate, and a mangled response is handled there
DNSSEC=no
LLMNR=no
MulticastDNS=no
RESOLVED
    chmod 644 /etc/systemd/resolved.conf.d/redoubt-quad9.conf
    systemctl restart systemd-resolved
    dbg "OK: host DNS now the ad shield, Quad9 over TLS underneath (systemd-resolved)"
  else
    # No systemd-resolved here. Leave the system resolver alone
    # (NetworkManager, dhcpcd and friends keep regenerating resolv.conf
    # anyway) and let the box's own resolver chain (pi-hole over
    # unbound) serve anyone who opts in. The leak firewall below
    # whitelists whichever nameservers are actually configured, so DNS
    # never dies on this family.
    dbg "no systemd-resolved here; NetworkManager owns the DNS and points it at the ad shield below"
    # point the active connection at the local pi-hole so this machine
    # filters too, and keep the DHCP servers out (the pi-hole forwards
    # to the stack unbound). Idempotent: a connection already pointed
    # here is left alone, and a failure warns honestly.
    if command -v nmcli >/dev/null 2>&1; then
      NM_CON=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1 | cut -d: -f1)
      if [ -n "$NM_CON" ]; then
        NM_DNS=$(nmcli -g ipv4.dns connection show "$NM_CON" 2>/dev/null)
        if [ "$NM_DNS" != "127.0.0.1" ]; then
          if nmcli con mod "$NM_CON" ipv4.dns "127.0.0.1" ipv4.ignore-auto-dns yes >/dev/null 2>&1; then
            # reapply carries the new dns into the live connection
            # without re-establishing it: the link never drops, an ssh
            # session never dies, and the pass cannot be cut right here
            NM_DEV=$(nmcli -g GENERAL.DEVICES connection show "$NM_CON" 2>/dev/null | head -1)
            if [ -n "$NM_DEV" ] && nmcli device reapply "$NM_DEV" >/dev/null 2>&1; then
              dbg "OK: host DNS now the ad shield (NetworkManager reapply)"
            elif nmcli con up "$NM_CON" >/dev/null 2>&1; then
              dbg "OK: host DNS now the ad shield (NetworkManager reconnect)"
            else
              dbg "WARN: could not point the host DNS at the ad shield (NetworkManager); this machine filters nothing for itself"
            fi
          else
            dbg "WARN: could not point the host DNS at the ad shield (NetworkManager); this machine filters nothing for itself"
          fi
        else
          dbg "OK: host DNS already on the ad shield (NetworkManager)"
        fi
      fi
    fi
  fi
else
  dbg "WARN: the ad shield is not answering on 127.0.0.1:53; host DNS left untouched so the machine keeps resolving"
fi
# The leak firewall: nothing on this machine may speak plain DNS (53) or
# DoT (853) to the outside. Allowed outbound are the configured nameservers
# (whatever the system resolver actually uses), the box's own resolver,
# and Quad9's two IPs. The stack's containers are covered too.
if ! command -v nft >/dev/null 2>&1; then
  apt-get install -y nftables >/dev/null 2>&1 || true
fi
if command -v nft >/dev/null 2>&1; then
  mkdir -p /etc/redoubt
  # Build the 53/udp+tcp allow-set: the box resolver plus whatever
  # nameservers the system actually points at. NetBird rewrites
  # resolv.conf when it connects (the live file then lists only the
  # mesh nameserver), so gather the pre-NetBird backup and the
  # default-route gateway too, and keep the unique IPv4 ones.
  NS53=$( { cat /etc/resolv.conf.original.netbird /etc/resolv.conf 2>/dev/null | awk '/^nameserver/ {print $2}'; ip route 2>/dev/null | awk '/^default/ {print $3; exit}'; } | grep -vE '^127\.' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//' )
  ALLOW53="{ 127.0.0.0/8, 172.28.0.53, 172.28.0.54"
  [ -n "$NS53" ] && ALLOW53="$ALLOW53, $NS53"
  ALLOW53="$ALLOW53 }"
  cat > /etc/redoubt/nft-dns.conf <<NFT
table inet redoubt-dns {
  chain mesh-dns-in {
    type nat hook prerouting priority dstnat; policy accept;
    # The mesh path: queries that arrive over the encrypted mesh hit
    # the pi-hole directly, so the dashboard nameserver (armed during
    # the cloud link) blocks ads on every peer, anywhere. Interface
    # based on purpose: it survives IP changes across re-enrollments
    # and never exposes anything beyond the mesh itself.
    iifname "wt0" udp dport 53 dnat ip to 172.28.0.54
    iifname "wt0" tcp dport 53 dnat ip to 172.28.0.54
  }
  chain mesh-dns-out {
    type nat hook postrouting priority srcnat; policy accept;
    # The pi-hole replies from its bridge address; the phone expects
    # the answer from the peer it asked (the mesh address), so every
    # DNS reply leaving the mesh wears the mesh source.
    oifname "wt0" udp sport 53 masquerade
    oifname "wt0" tcp sport 53 masquerade
  }
  chain output {
    type filter hook output priority filter; policy accept;
    udp dport 53 ip daddr != $ALLOW53 reject
    tcp dport 53 ip daddr != $ALLOW53 reject
    udp dport 853 ip daddr != { 9.9.9.9, 149.112.112.112 } reject
    tcp dport 853 ip daddr != { 9.9.9.9, 149.112.112.112 } reject
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    ip saddr 172.28.0.0/16 udp dport 53 ip daddr != { 172.28.0.53, 172.28.0.54 } reject
    ip saddr 172.28.0.0/16 tcp dport 53 ip daddr != { 172.28.0.53, 172.28.0.54 } reject
    ip saddr 172.28.0.0/16 udp dport 853 ip daddr != { 9.9.9.9, 149.112.112.112 } reject
    ip saddr 172.28.0.0/16 tcp dport 853 ip daddr != { 9.9.9.9, 149.112.112.112 } reject
  }
}
NFT
  chmod 644 /etc/redoubt/nft-dns.conf
  cat > /etc/systemd/system/redoubt-dns-fw.service <<'UNIT'
[Unit]
Description=Redoubt DNS lockdown (Quad9-only egress)
[Service]
Type=oneshot
# delete first: the table must load clean on every apply, never stack rules
ExecStart=/bin/sh -c 'nft delete table inet redoubt-dns 2>/dev/null; exec nft -f /etc/redoubt/nft-dns.conf'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/redoubt-dns-fw.service
  systemctl daemon-reload
  # enable --now does not re-run a unit a previous pass left 'active'
  # (oneshot + RemainAfterExit): the live ruleset can then be older
  # than the freshly written conf. restart re-applies it.
  systemctl enable redoubt-dns-fw >/dev/null 2>&1
  systemctl restart redoubt-dns-fw >/dev/null 2>&1
  if nft list table inet redoubt-dns >/dev/null 2>&1; then
    dbg "OK: DNS leak firewall active (plain DNS and stray DoT are blocked)"
  else
    dbg "WARN: the DNS leak firewall did not load; DNS stays open (see $LOG)"
  fi
else
  dbg "WARN: nftables unavailable, skipping the DNS leak firewall"
fi

# Host firewall: the cloud's ports face the owner's wifi, and wifi has
# neighbors. The kit never silently touches a firewall: if the machine
# ships one it asks before opening the ports, if it ships one switched
# off it offers to turn it on, and if there is none it offers to install
# the family-standard one. Every ask carries the same honest why.
# the conf alone lies about ufw: ENABLED=yes survives a half-dead
# enable and a wipe that flushed the chains, while the unit stays
# active on some distros with the firewall off. The loaded chains
# are the truth of runtime.
ufw_rules_live() {
  if iptables -L ufw-user-input -n >/dev/null 2>&1; then
    return 0
  fi
  nft list chain ip filter ufw-user-input >/dev/null 2>&1
}
FW_KIND="none"
if command -v ufw >/dev/null 2>&1; then
  FW_KIND="ufw"
elif command -v firewall-cmd >/dev/null 2>&1; then
  FW_KIND="firewalld"
fi
FW_ACTIVE=0
FW_QUIET=0
if [ "$FW_KIND" = "ufw" ]; then
  # the config file is the first gate, never the whole truth:
  # ENABLED=yes survives a half-dead enable and a flushed ruleset,
  # so the loaded chains must back it up (ufw status fails mid-pass
  # under iptables churn and the unit lies on some distros)
  if grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null && ufw_rules_live; then
    FW_ACTIVE=1
  fi
elif [ "$FW_KIND" = "firewalld" ]; then
  systemctl is-active firewalld >/dev/null 2>&1 && FW_ACTIVE=1
fi
# Fresh wording on every ask: rotate through a small pool (random
# start) so a multi-step ladder never repeats itself.
FW_WHY_POOL=(
  "A firewall keeps other devices on your wifi from knocking on your cloud's doors."
  "Your wifi has neighbors: a firewall is the lock between your cloud and their devices."
  "A firewall stands between your cloud and every other device on the network."
  "Without a firewall, any device on your wifi can walk right up to your cloud's apps."
)
# canonical door lists: every hint, allow and verify below reads these,
# so a port change happens in exactly one place. Arrays because each
# entry carries spaces: a quoted array survives word splitting, a
# backslash-quoted string does not (it splits into fragments and every
# check reads as failed even with the rules in place)
# the full-NAS model (selfhost): the apps answer only to the mesh
# interface by default, and the wifi only sees the mesh doors the
# phone needs to enroll. Cloud keeps the classic set: wifi doors for
# the apps, the tunnel itself arrives from NetBird's cloud.
FW_U_ESS_RULES=( "tcp --dport 22" "tcp --dport 8390" "udp --dport 8390" "udp --dport 40002" "tcp --dport 8086" )
FW_U_APP_PORTS="443 8443 8444 8445 8446 8447 33073"
FW_F_APP_PORTS="443/tcp 8443-8447/tcp 33073/tcp"
FW_U_CLOUD_TCP="22 443 8390 8443 8444 8445 8446 8447 8086 33073"
FW_U_CLOUD_RULES=( "tcp --dport 443" "tcp --dport 8390" "udp --dport 8390" "tcp --dport 33073" "tcp --dport 8443" "tcp --dport 8444" "tcp --dport 8445" "tcp --dport 8446" "tcp --dport 8447" "tcp --dport 8086" )
FW_U_CLOUD_FULL=( "tcp --dport 22" "${FW_U_CLOUD_RULES[@]}" )
FW_F_CLOUD_PORTS="8390/tcp 8390/udp 33073/tcp 443/tcp 8443-8447/tcp 8086/tcp"
# the NetBird console door is selfhost-only: cloud has no local
# dashboard, so its firewall story stays exactly as it was
if [ "$MESH_MODE" = "selfhost" ]; then
  FW_U_APP_PORTS="$FW_U_APP_PORTS 8448"
  FW_F_APP_PORTS="$FW_F_APP_PORTS 8448/tcp"
fi

# true when the rules for a firewall state are already in place.
# states: on (essentials + apps on every interface), on-nas
# (essentials + apps on the mesh interface only), on-nodoors
# (essentials only). cloud never uses on-nas: its n is on-nodoors.
fw_state_ok() {
  _FW_STATE=$1
  if [ "$FW_KIND" = "ufw" ]; then
    _FW_RULES=$(cat /etc/ufw/user.rules 2>/dev/null || true)
    for _FW_P in "${FW_U_ESS_RULES[@]}"; do
      case "$_FW_RULES" in *"$_FW_P"*) ;; *) return 1 ;; esac
    done
    case "$_FW_STATE" in
      on-nodoors) return 0 ;;
      on-nas)
        for _FW_P in $FW_U_APP_PORTS; do
          echo "$_FW_RULES" | grep -- "-i wt0" | grep -q -- "--dport $_FW_P" || return 1
        done ;;
      on)
        for _FW_P in $FW_U_APP_PORTS; do
          case "$_FW_RULES" in *"--dport $_FW_P"*) ;; *) return 1 ;; esac
        done ;;
    esac
    return 0
  fi
  _FW_PORTS=$(firewall-cmd --list-ports 2>/dev/null || true)
  for _FW_P in 8390/tcp 8390/udp 40002/udp 8086/tcp; do
    case " $_FW_PORTS " in *" $_FW_P "*) ;; *) return 1 ;; esac
  done
  firewall-cmd --query-service=ssh >/dev/null 2>&1 || return 1
  case "$_FW_STATE" in
    on-nodoors) return 0 ;;
    on-nas)
      _FW_ZP=$(firewall-cmd --zone=redoubt-mesh --list-ports 2>/dev/null || true)
      for _FW_P in $FW_F_APP_PORTS; do
        case " $_FW_ZP " in *" $_FW_P "*) ;; *) return 1 ;; esac
      done ;;
    on)
      for _FW_P in $FW_F_APP_PORTS; do
        case " $_FW_PORTS " in *" $_FW_P "*) ;; *) return 1 ;; esac
      done ;;
  esac
  return 0
}

# write the rules for a state. selfhost only: cloud keeps its classic
# apply in the door section below.
fw_apply_state() {
  _FW_STATE=$1
  if [ "$FW_KIND" = "ufw" ]; then
    for _FW_P in 22 8390 8086; do
      ufw allow "$_FW_P/tcp" >/dev/null 2>&1 || true
    done
    ufw allow 8390/udp >/dev/null 2>&1 || true
    ufw allow 40002/udp >/dev/null 2>&1 || true
    for _FW_P in $FW_U_APP_PORTS; do
      # both forms are cleaned first so a flipped decision on a
      # re-run never leaves the old form behind
      ufw delete allow "$_FW_P/tcp" >/dev/null 2>&1 || true
      ufw delete allow in on wt0 to any port "$_FW_P" proto tcp >/dev/null 2>&1 || true
      case "$_FW_STATE" in
        on) ufw allow "$_FW_P/tcp" >/dev/null 2>&1 || true ;;
        on-nas) ufw allow in on wt0 to any port "$_FW_P" proto tcp >/dev/null 2>&1 || true ;;
      esac
    done
  else
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
    for _FW_P in 8390/tcp 8390/udp 40002/udp 8086/tcp; do
      firewall-cmd --permanent --add-port="$_FW_P" >/dev/null 2>&1 || true
    done
    firewall-cmd --permanent --new-zone=redoubt-mesh >/dev/null 2>&1 || true
    for _FW_P in $FW_F_APP_PORTS; do
      firewall-cmd --permanent --zone=redoubt-mesh --remove-port="$_FW_P" >/dev/null 2>&1 || true
      firewall-cmd --permanent --remove-port="$_FW_P" >/dev/null 2>&1 || true
      case "$_FW_STATE" in
        on) firewall-cmd --permanent --add-port="$_FW_P" >/dev/null 2>&1 || true ;;
        on-nas) firewall-cmd --permanent --zone=redoubt-mesh --add-port="$_FW_P" >/dev/null 2>&1 || true ;;
      esac
    done
    if [ "$_FW_STATE" = "on-nas" ]; then
      # wt0 may not exist yet on a first pass: firewalld binds the
      # zone the moment the interface appears
      firewall-cmd --permanent --zone=redoubt-mesh --add-interface=wt0 >/dev/null 2>&1 || true
    else
      firewall-cmd --permanent --zone=redoubt-mesh --remove-interface=wt0 >/dev/null 2>&1 || true
    fi
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

fw_hints() {
  if [ "$MESH_MODE" = "selfhost" ]; then
    if [ "$FW_KIND" = "ufw" ]; then
      FW_HINT="sudo ufw allow 22/tcp && sudo ufw allow 8390/tcp && sudo ufw allow 8390/udp && sudo ufw allow 40002/udp && sudo ufw allow 8086/tcp && for p in 443 8443 8444 8445 8446 8447 8448 33073; do sudo ufw allow in on wt0 to any port \$p proto tcp; done"
      FW_ON_HINT="sudo ufw enable"
    else
      FW_HINT="sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --permanent --add-port=8390/tcp && sudo firewall-cmd --permanent --add-port=8390/udp && sudo firewall-cmd --permanent --add-port=40002/udp && sudo firewall-cmd --permanent --add-port=8086/tcp && sudo firewall-cmd --permanent --new-zone=redoubt-mesh && sudo firewall-cmd --permanent --zone=redoubt-mesh --add-interface=wt0 && sudo firewall-cmd --permanent --zone=redoubt-mesh --add-port=443/tcp && sudo firewall-cmd --permanent --zone=redoubt-mesh --add-port=8443-8448/tcp && sudo firewall-cmd --permanent --zone=redoubt-mesh --add-port=33073/tcp && sudo firewall-cmd --reload"
      FW_ON_HINT="sudo systemctl enable --now firewalld"
    fi
  else
    if [ "$FW_KIND" = "ufw" ]; then
      FW_HINT="sudo ufw allow 22/tcp && sudo ufw allow 443/tcp && sudo ufw allow 8390/tcp && sudo ufw allow 8390/udp && sudo ufw allow 8443/tcp && sudo ufw allow 8444/tcp && sudo ufw allow 8445/tcp && sudo ufw allow 8446/tcp && sudo ufw allow 8447/tcp && sudo ufw allow 8086/tcp && sudo ufw allow 33073/tcp"
      FW_ON_HINT="sudo ufw enable"
    else
      FW_HINT="sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --permanent --add-port=8390/tcp && sudo firewall-cmd --permanent --add-port=8390/udp && sudo firewall-cmd --permanent --add-port=443/tcp && sudo firewall-cmd --permanent --add-port=8443-8447/tcp && sudo firewall-cmd --permanent --add-port=8086/tcp && sudo firewall-cmd --permanent --add-port=33073/tcp && sudo firewall-cmd --reload"
      FW_ON_HINT="sudo systemctl enable --now firewalld"
    fi
  fi
}

ask_tty() {
  # one question on the TUI: stop the spinner, clear the line, ask,
  # read the answer back on fd 3 and drain whatever junk followed it
  _ASK_VAR=$1; _ASK_PROMPT=$2; _ASK_TIMEOUT=${3:-120}
  if [ -n "${ANIM_PID:-}" ]; then
    kill -9 "$ANIM_PID" 2>/dev/null || true
  fi
  printf '\r\033[K' >&3 2>/dev/null || true
  echo "" >&3 2>/dev/null || true
  printf "%s" "$_ASK_PROMPT" >&3 2>/dev/null || true
  stty echo icanon <&3 2>/dev/null || true
  # shellcheck disable=SC2229
  # read takes the variable NAME here, not the value
  read -r -t "$_ASK_TIMEOUT" "$_ASK_VAR" <&3 2>/dev/null || true
  drain_tty
}

FW_WHY_IDX=$((RANDOM % ${#FW_WHY_POOL[@]}))
FW_WHY="${FW_WHY_POOL[$FW_WHY_IDX]}"
FW_WHY_IDX=$(( (FW_WHY_IDX + 1) % ${#FW_WHY_POOL[@]} ))
if [ -t 3 ]; then
  # every path below prints a hint sooner or later: fill both once,
  # so a machine that ships its firewall never trips on an empty var
  fw_hints
  # The customer already chose the firewall story on an earlier pass:
  # apply it quietly now, no questions and no notes on screen. The
  # log keeps every detail; the screen keeps the aesthetic.
  if [ -n "${FW_DECISION:-}" ]; then
    FW_QUIET=1
    FW_INSTALL=n; FW_ON=n
    case "$FW_DECISION" in
      on) FW_ON=y; FW_STATE=on ;;
      on-nas) FW_ON=y; FW_STATE=on-nas ;;
      on-nodoors) FW_ON=y; FW_STATE=on-nodoors ;;
      *) FW_ON=y; FW_STATE=on-nodoors ;;
    esac
  fi
  if [ "$FW_KIND" = "none" ]; then
    if [ "${FW_QUIET:-0}" != "1" ]; then
      echo "This machine ships no firewall. $FW_WHY" >&3 2>/dev/null || true
      echo "I can install the standard one and open only what the cloud needs." >&3 2>/dev/null || true
      ask_tty FW_INSTALL "Install it? (y/N): "
    fi
    case "${FW_INSTALL:-}" in
      [yY]*|[sS]*)
        case "$PKG_FAMILY" in
          apt) apt-get install -y ufw >/dev/null 2>&1 ;;
          pacman) pacman -S --noconfirm ufw >/dev/null 2>&1 ;;
          dnf) dnf install -y firewalld >/dev/null 2>&1 ;;
          zypper) zypper --non-interactive install firewalld >/dev/null 2>&1 ;;
        esac
        command -v ufw >/dev/null 2>&1 && FW_KIND="ufw"
        command -v firewall-cmd >/dev/null 2>&1 && FW_KIND="firewalld"
        if [ "$FW_KIND" != "none" ]; then
          dbg "OK: firewall installed ($FW_KIND, with your ok)"
        fi
        if [ "$FW_KIND" = "none" ]; then
          if [ "${FW_QUIET:-0}" = "1" ]; then
            dbg "the firewall install did not land (no network?)"
          else
            echo "firewall install failed (no network?) - doors open on wifi until you add one." >&3 2>/dev/null || true
          fi
          FW_KIND="skip"
        fi
        fw_hints
        ;;
      *)
        if [ "${FW_QUIET:-0}" = "1" ]; then
          dbg "no firewall on this machine (the customer chose to leave it)"
        else
          echo "no firewall - app doors open on wifi. Install one and run me again." >&3 2>/dev/null || true
        fi
        FW_KIND="skip"
        ;;
    esac
  fi
  if [ "$FW_KIND" != "none" ] && [ "$FW_KIND" != "skip" ] && [ "$FW_ACTIVE" = "0" ]; then
    if [ "${FW_QUIET:-0}" != "1" ]; then
      FW_WHY="${FW_WHY_POOL[$FW_WHY_IDX]}"
      FW_WHY_IDX=$(( (FW_WHY_IDX + 1) % ${#FW_WHY_POOL[@]} ))
      echo "Your machine ships a firewall ($FW_KIND) but it is switched off. $FW_WHY" >&3 2>/dev/null || true
      ask_tty FW_ON "Switch it on? (y/N): "
    fi
    case "${FW_ON:-}" in
      [yY]*|[sS]*)
        FW_ON_OK=0
        if [ "$FW_KIND" = "ufw" ]; then
          ufw --force enable >/dev/null 2>&1 || true
          sleep 3
          if ! { grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null && ufw_rules_live; }; then
            ufw --force enable >/dev/null 2>&1 || true
            sleep 3
          fi
          { grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null && ufw_rules_live; } && FW_ON_OK=1
        else
          systemctl enable --now firewalld >/dev/null 2>&1 || true
          sleep 3
          systemctl is-active firewalld >/dev/null 2>&1 \
            || systemctl enable --now firewalld >/dev/null 2>&1 || true
          systemctl is-active firewalld >/dev/null 2>&1 && FW_ON_OK=1
        fi
        if [ "$FW_ON_OK" = "1" ]; then
          FW_ACTIVE=1
          dbg "OK: firewall switched on ($FW_KIND, with your ok)"
        else
          dbg "WARNING: firewall did not switch on ($FW_KIND enable failed)"
          if [ "${FW_QUIET:-0}" != "1" ]; then
            echo "WARNING: $FW_KIND did not switch on - doors closed, phone uses the mesh." >&3 2>/dev/null || true
          fi
          dbg "hint: $FW_ON_HINT"
          FW_KIND="skip"
        fi
        ;;
      *)
        if [ "${FW_QUIET:-0}" = "1" ]; then
          dbg "firewall stays off (the customer chose it)"
        else
          echo "firewall stays off - devices on your wifi can reach the app doors." >&3 2>/dev/null || true
          dbg "hint: $FW_ON_HINT"
        fi
        FW_KIND="skip"
        ;;
    esac
  fi
  if [ "$FW_ACTIVE" = "1" ]; then
    # a re-run must not ask again when the doors are already open:
    # check the rules first and skip the question entirely. the
    # state to check: the persisted story when there is one, the
    # classic all-open state when this is the first ask.
    FW_DONE=0
    if [ -z "${FW_STATE:-}" ]; then
      FW_STATE="on"
    fi
    if fw_state_ok "$FW_STATE"; then
      FW_DONE=1
      # a dead firewall must never read as open
      if [ "$FW_KIND" = "ufw" ] && ! ufw_rules_live; then
        FW_DONE=0
      fi
    fi
    if [ "$FW_DONE" = "1" ]; then
      dbg "OK: firewall doors already open ($FW_KIND, nothing to ask)"
    else
    if [ "${FW_QUIET:-0}" != "1" ]; then
      if [ -n "${ANIM_PID:-}" ]; then
        kill -9 "$ANIM_PID" 2>/dev/null || true
      fi
      printf '\r\033[K' >&3 2>/dev/null || true
      echo "" >&3 2>/dev/null || true
      echo "Your firewall ($FW_KIND) is active. I need to open a few doors:" >&3 2>/dev/null || true
      echo "  - mesh doors (8390, stun 40002, cert 8086): your phone enrolls on your home wifi" >&3 2>/dev/null || true
      if [ "$MESH_MODE" = "selfhost" ]; then
        echo "  - app doors (8443-8448, panel 443): they answer only to your mesh devices" >&3 2>/dev/null || true
        echo "I will not touch any other rule." >&3 2>/dev/null || true
        printf 'Open the apps to plain wifi too, without the mesh? (y/N): ' >&3 2>/dev/null || true
      else
        echo "  - app doors (8443-8447), panel (443) and certificate (8086): your phone opens photos, files and search on wifi" >&3 2>/dev/null || true
        echo "I will not touch any other rule." >&3 2>/dev/null || true
        printf 'May I add these rules? (y/N): ' >&3 2>/dev/null || true
      fi
      # strict gate like the mesh questions: junk must never fall
      # through to a silent 'no' and leave the run half-open (typing
      # 'clear' means the customer wants out, not 'no')
      while :; do
        stty echo icanon <&3 2>/dev/null || true
        read -r -t 120 FW_OK <&3 2>/dev/null || true
        drain_tty
        case "$FW_OK" in
          ""|[yY]|[yY][eE][sS]|[sS]|[sS][iI]|[nN]|[nN][oO]) break ;;
          [cC]lear|[cC]ancel|[eE]xit|[qQ]uit|[aA]bort|[sS]top|[sS]alir)
            printf 'Run cancelled - nothing was changed.\n' >&3 2>/dev/null || true
            exit 0
            ;;
          *) printf 'Please answer y or n.\n' >&3 2>/dev/null || true ;;
        esac
      done
    fi
    # the quiet branch already carries the persisted state; a fresh
    # answer maps to its state here
    if [ -z "${FW_STATE:-}" ]; then
      case "${FW_OK:-}" in
        [yY]*|[sS]*) FW_STATE=on ;;
        *) FW_STATE=on-nas ;;
      esac
      [ "$MESH_MODE" != "selfhost" ] && [ "$FW_STATE" = "on-nas" ] && FW_STATE=on-nodoors
    fi
    FW_RULES_OK=0
    if [ "$MESH_MODE" = "selfhost" ]; then
      # the full-NAS apply: essentials always, apps on the mesh
      # interface (or everywhere when the wifi answer was yes)
      fw_apply_state "$FW_STATE"
      # an allow on a firewall that just died writes nothing:
      # verify the rules landed before claiming the doors open
      if [ "$FW_KIND" = "ufw" ] && ! ufw_rules_live; then
        FW_RULES_OK=0
      else
        fw_state_ok "$FW_STATE" && FW_RULES_OK=1
      fi
      if [ "$FW_RULES_OK" = "1" ]; then
        dbg "OK: firewall doors opened ($FW_KIND, apps on the mesh${FW_STATE:+ (state $FW_STATE)} )"
      else
        dbg "WARNING: firewall rules did not land ($FW_KIND)"
        dbg "hint: $FW_HINT"
        if [ "${FW_QUIET:-0}" != "1" ]; then
          echo "WARNING: firewall rules did not land - the mesh works, the apps stay box-only." >&3 2>/dev/null || true
        fi
      fi
    else
      # cloud: the classic apply, one form only
      if [ "$FW_STATE" = "on" ]; then
        if [ "$FW_KIND" = "ufw" ]; then
          for FW_P in $FW_U_CLOUD_TCP; do
            ufw allow "$FW_P/tcp" >/dev/null 2>&1 || true
          done
          ufw allow 8390/udp >/dev/null 2>&1 || true
          # an allow on a firewall that just died writes nothing:
          # verify the rules landed before claiming the doors open
          FW_RULES=$(cat /etc/ufw/user.rules 2>/dev/null || true)
          FW_RULES_OK=1
          for FW_P in "${FW_U_CLOUD_FULL[@]}"; do
            case "$FW_RULES" in *"$FW_P"*) ;; *) FW_RULES_OK=0 ;; esac
          done
          # written rules mean nothing while nothing is loaded
          ufw_rules_live || FW_RULES_OK=0
        else
          firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
          for FW_P in $FW_F_CLOUD_PORTS; do
            firewall-cmd --permanent --add-port="$FW_P" >/dev/null 2>&1 || true
          done
          firewall-cmd --reload >/dev/null 2>&1 || true
          FW_PORTS=$(firewall-cmd --list-ports 2>/dev/null || true)
          FW_RULES_OK=1
          # services live in a list of their own: --list-ports never
          # shows the ssh service, so it gets its own query
          firewall-cmd --query-service=ssh >/dev/null 2>&1 || FW_RULES_OK=0
          for FW_P in $FW_F_CLOUD_PORTS; do
            case " $FW_PORTS " in *" $FW_P "*) ;; *) FW_RULES_OK=0 ;; esac
          done
        fi
        if [ "$FW_RULES_OK" = "1" ]; then
          dbg "OK: firewall doors opened for the mesh and the local apps ($FW_KIND, with your ok)"
        else
          dbg "WARNING: firewall rules did not land ($FW_KIND)"
          dbg "hint: $FW_HINT"
          if [ "${FW_QUIET:-0}" != "1" ]; then
            echo "WARNING: firewall rules did not land - mesh works, wifi doors stay closed." >&3 2>/dev/null || true
          fi
        fi
      else
        dbg "hint: $FW_HINT"
        if [ "${FW_QUIET:-0}" != "1" ]; then
          echo "firewall untouched - the phone reaches the apps over the mesh." >&3 2>/dev/null || true
        fi
      fi
    fi
    fi
  fi
  # Persist the customer's firewall story: every later pass applies it
  # quietly (no questions, no notes on screen). The states map to the
  # quiet branch above: on = switch on + apps on every interface,
  # on-nas = switch on + apps on the mesh only (selfhost), on-nodoors
  # = switch on + mesh doors only, off = untouched.
  if [ "$FW_ACTIVE" = "1" ]; then
    if [ "${FW_RULES_OK:-0}" = "1" ] || [ "${FW_DONE:-0}" = "1" ]; then
      FW_DECISION="${FW_STATE:-on}"
    else
      FW_DECISION=on-nodoors
    fi
  else
    FW_DECISION=off
  fi
  if grep -qs '^FW_DECISION=' /etc/redoubt/redoubt.env 2>/dev/null; then
    sed -i "s|^FW_DECISION=.*|FW_DECISION=$FW_DECISION|" /etc/redoubt/redoubt.env
  else
    echo "FW_DECISION=$FW_DECISION" >> /etc/redoubt/redoubt.env
  fi
  bar_anim &
  ANIM_PID=$!
else
  if [ "$FW_ACTIVE" = "1" ]; then
    dbg "$FW_KIND is active and this run has no terminal to ask. Firewall untouched: run again from a terminal to open the mesh doors." >> "$LOG"
  fi
fi

# 9) Updates check, reports only, never blocks. Signed manifest from the key server.
if [ -n "${REDOUBT_KIT_VERSION:-}" ] && [ -n "${REDOUBT_BOOTSTRAP_URL:-}" ]; then
  MANIFEST_URL="${REDOUBT_BOOTSTRAP_URL%/api/v1/bootstrap*}/api/v1/updates/manifest"
  MAN=$(curl -s --max-time 10 "$MANIFEST_URL" 2>/dev/null | tr -d '{}' | tr ',' '\n' | grep -oE '"manifest":"[^"]*"' | cut -d'"' -f4)
  LATEST=$(printf '%s' "$MAN" | grep -oE '"latest":"[^"]*"' | cut -d'"' -f4)
  if [ -n "$LATEST" ] && [ "$LATEST" != "$REDOUBT_KIT_VERSION" ]; then
    dbg "WARNING: a newer redoubt is available ($LATEST; installed $REDOUBT_KIT_VERSION). Signed updates available."
  elif [ -n "$LATEST" ]; then
    dbg "OK: up to date ($LATEST)"
  fi
fi

# 9b) Opt-in technical heartbeat (only with bootstrap + saved key). Infra only, no private data.
if [ -n "${REDOUBT_BOOTSTRAP_URL:-}" ] && [ -f /etc/redoubt/.node-key ]; then
  HB_URL="${REDOUBT_BOOTSTRAP_URL%/api/v1/bootstrap*}/api/v1/node/heartbeat"
  mkdir -p /etc/redoubt
  printf '#!/bin/sh\ncurl -s --max-time 10 -X POST "%s" -H "Authorization: Bearer $(cat /etc/redoubt/.node-key)" -d "{\\"version\\":\\"%s\\",\\"uptime\\":\\"$(uptime -p | cut -c4-)\\"}" >/dev/null 2>&1\n' "$HB_URL" "${REDOUBT_KIT_VERSION:-v1}" > /etc/redoubt/heartbeat.sh
  chmod 700 /etc/redoubt/heartbeat.sh
  printf '[Unit]\nDescription=Redoubt heartbeat (opt-in)\n[Service]\nType=oneshot\nExecStart=/etc/redoubt/heartbeat.sh\n' > /etc/systemd/system/redoubt-heartbeat.service
  printf '[Unit]\nDescription=Redoubt heartbeat every 6h\n[Timer]\nOnBootSec=10min\nOnUnitActiveSec=6h\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/redoubt-heartbeat.timer
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable redoubt-heartbeat.timer >/dev/null 2>&1 && echo "OK: opt-in heartbeat installed (every 6h)"
fi

# 9c) Self-update hook. apt's Post-Invoke compares the installed kit with
#     the release edge and re-runs the installer by itself, so a plain
#     'sudo apt update' keeps the cloud patched. The marker is the kit's
#     own sha, captured at boot before the mid-run cd; the edge serves
#     the current one, signed.
if [ -n "$KIT_SELF_SHA" ]; then
  mkdir -p /etc/redoubt
  echo "$KIT_SELF_SHA" > /etc/redoubt/kit-sha.txt
  echo "$KIT_BUILD" > /etc/redoubt/kit-build.txt
  cat > /etc/redoubt/redoubt-update.sh.tmp <<'UPDATER'
#!/bin/sh
# Redoubt self-update: compares the installed kit against the release
# edge and re-runs the installer when a newer one exists. The remote
# sha is verified against the Redoubt release signature before anything
# is re-run: a missing or invalid signature fails closed (no update),
# so a tampered edge can never push root code to this machine.
UPD_EDGE=https://install.tryredoubt.com
UPD_KEY="-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAIkuck+5xb7kMv5c7JwcM3PpuOc4/W2ySl6wknsg5GnM=
-----END PUBLIC KEY-----"
UPD_KEY_V2="-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAdxRgkHkxb2i0SZ9UvjOcdn51eM2pDvE4VZWBViOCurs=
-----END PUBLIC KEY-----"
UPD_TMP=$(mktemp -d /tmp/redoubt-update.XXXXXX) || exit 0
trap 'rm -rf "$UPD_TMP"' EXIT
chmod 700 "$UPD_TMP"
LOCAL=$(cat /etc/redoubt/kit-sha.txt 2>/dev/null)
[ -n "$LOCAL" ] || { echo "redoubt: no local kit record, re-run the installer"; exit 1; }
echo "redoubt: checking for updates..."
curl -fsSL --max-time 20 -o "$UPD_TMP/kit-sha.txt" "$UPD_EDGE/install/kit-sha.txt" 2>/dev/null || exit 0
curl -fsSL --max-time 20 -o "$UPD_TMP/kit-sha.txt.sig" "$UPD_EDGE/install/kit-sha.txt.sig" 2>/dev/null || exit 0
printf '%s\n' "$UPD_KEY" > "$UPD_TMP/key.pem"
printf '%s\n' "$UPD_KEY_V2" > "$UPD_TMP/key2.pem"
# rotation window: the sha must verify with either release key. Once the
# fleet carries this updater, releases move to the new key alone.
if ! openssl pkeyutl -verify -pubin -inkey "$UPD_TMP/key.pem" -rawin \
     -in "$UPD_TMP/kit-sha.txt" -sigfile "$UPD_TMP/kit-sha.txt.sig" 2>/dev/null \
     | grep -q "Signature Verified Successfully" \
   && ! openssl pkeyutl -verify -pubin -inkey "$UPD_TMP/key2.pem" -rawin \
     -in "$UPD_TMP/kit-sha.txt" -sigfile "$UPD_TMP/kit-sha.txt.sig" 2>/dev/null \
     | grep -q "Signature Verified Successfully"; then
  exit 0
fi
# never fight a running install: the apt hook skips its turn when the
# lock is held by a live kit and waits for the next quiet moment
if [ -f /run/redoubt.lock ]; then
  LOCK_PID="$(head -1 /run/redoubt.lock 2>/dev/null)"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0
  fi
fi
# the tool updates itself first: a kit change re-runs the installer
# (which rewrites this updater), and only a current updater touches the
# stack images. The old order left a stale updater running forever.
REMOTE=$(cat "$UPD_TMP/kit-sha.txt")
[ -n "$REMOTE" ] || { echo "redoubt: could not read the release record"; exit 1; }
if [ "$LOCAL" != "$REMOTE" ]; then
  echo "redoubt: update available, pulling the new kit..."
  # the signed sha must bind to the code that runs: download the bundle,
  # extract the kit, hash it against the signed value, and only then run it.
  # A tampered edge can never push root code here.
  curl -fsSL --max-time 120 -o "$UPD_TMP/kit.tar.gz" "$UPD_EDGE/install/redoubt-kit-latest.tar.gz" 2>/dev/null || { echo "redoubt: download failed, try again later"; exit 1; }
  tar -xzf "$UPD_TMP/kit.tar.gz" -C "$UPD_TMP" redoubt.sh 2>/dev/null \
        || { echo "redoubt: the bundle arrived broken"; exit 1; }
  KIT_FILE="$UPD_TMP/redoubt.sh"
  [ "$(sha256sum "$KIT_FILE" | cut -d' ' -f1)" = "$REMOTE" ] || { echo "redoubt: hash mismatch, the update was dropped"; exit 1; }
  # never downgrade: the build counter inside the verified kit is
  # monotonic. An older but validly signed kit cannot roll this
  # machine back, whether it comes from a lab mixup or a stale edge
  REMOTE_BUILD=$(grep -m1 '^KIT_BUILD=' "$KIT_FILE" | cut -d'"' -f2)
  LOCAL_BUILD=$(cat /etc/redoubt/kit-build.txt 2>/dev/null)
  if [ -n "$REMOTE_BUILD" ] && [ -n "$LOCAL_BUILD" ] \
     && [ "$REMOTE_BUILD" -lt "$LOCAL_BUILD" ] 2>/dev/null; then
    echo "redoubt: the installed kit is newer than the release edge, nothing to do"
    exit 0
  fi
  echo "redoubt: running the new kit (this takes a few minutes)..."
  bash "$KIT_FILE"
  # the kit rewrote this updater: this pass already did its job, the
  # next one runs the fresh logic
  exit 0
fi
# the kit is current. The stack rides moving tags (nextcloud:35-apache,
# immich:release and friends): pull them on every update pass and let
# compose recreate whatever actually moved upstream. When something DID
# move, the volumes get a cold snapshot first: a recreate then never
# risks the owner's data on a bad migration.
if [ -f /opt/redoubt/docker-compose.yml ] && command -v docker >/dev/null 2>&1; then
  IMG_IDS=$(mktemp)
  NEW_IDS=$(mktemp)
  docker compose -f /opt/redoubt/docker-compose.yml config --images 2>/dev/null \
    | xargs -r -n1 docker image inspect --format '{{.Id}}' 2>/dev/null | sort > "$IMG_IDS" || true
  # the owner watches this run: one verdict line per image, so the
  # update never looks like a silent process
  for IMG in $(docker compose -f /opt/redoubt/docker-compose.yml config --images 2>/dev/null); do
    echo "redoubt: checking $IMG ..."
    docker pull "$IMG" 2>&1 | grep -E "Pulling from|Downloaded newer image|Image is up to date" | tail -1
  done
  docker compose -f /opt/redoubt/docker-compose.yml config --images 2>/dev/null \
    | xargs -r -n1 docker image inspect --format '{{.Id}}' 2>/dev/null | sort > "$NEW_IDS" || true
  if ! cmp -s "$IMG_IDS" "$NEW_IDS"; then
    SNAP_DIR=/var/lib/redoubt/snapshots
    SNAP="$SNAP_DIR/pre-update-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$SNAP"
    echo "redoubt: new images arrived, snapshotting the stack data first..."
    # the mount map must be captured while the stack is up (a stopped
    # compose lists no containers), then the tars run cold on it
    MOUNTMAP=$(mktemp)
    for CID in $(docker compose -f /opt/redoubt/docker-compose.yml ps -q 2>/dev/null); do
      CNAME=$(docker inspect "$CID" --format '{{.Name}}' 2>/dev/null | tr -d '/')
      # cover every data mount the stack owns: named volumes and host
      # binds (the photos and the databases live on host paths). System
      # binds (sockets, localtime) are skipped, they hold no owner data.
      docker inspect "$CID" --format '{{range .Mounts}}{{.Type}}|{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}|{{.Destination}}{{println}}{{end}}' 2>/dev/null \
        | while IFS='|' read -r MTYPE MSRC MDEST; do
            [ -n "$MSRC" ] || continue
            case "$MSRC" in
              /etc/localtime|/etc/timezone|/var/run/*|/run/*|/proc/*|/sys/*) continue ;;
            esac
            printf '%s|%s|%s|%s\n' "$CNAME" "$MTYPE" "$MSRC" "$MDEST" >> "$MOUNTMAP"
          done
    done
    docker compose -f /opt/redoubt/docker-compose.yml --profile '*' stop >/dev/null 2>&1 || true
    while IFS='|' read -r CNAME MTYPE MSRC MDEST; do
      [ -n "$MSRC" ] || continue
      if [ "$MTYPE" = "volume" ]; then
        MP=$(docker volume inspect "$MSRC" --format '{{.Mountpoint}}' 2>/dev/null)
      else
        MP="$MSRC"
      fi
      SAFE=$(printf '%s' "$MDEST" | tr '/' '_')
      echo "redoubt: snapshotting $CNAME ($MDEST) ..."
      tar -czf "$SNAP/${CNAME}${SAFE}.tar.gz" -C "$MP" . 2>/dev/null || true
    done < "$MOUNTMAP"
    rm -f "$MOUNTMAP"
    # keep the last two snapshots, the rest would just eat the disk
    ls -1dt "$SNAP_DIR"/pre-update-* 2>/dev/null | tail -n +3 | xargs -r rm -rf
    SNAP_SIZE=$(du -sh "$SNAP" 2>/dev/null | cut -f1)
    echo "redoubt: snapshot saved ($SNAP_SIZE), recreating the stack..."
    docker compose -f /opt/redoubt/docker-compose.yml --profile '*' up -d 2>&1 \
      | grep -E "Recreated|Started|Running|Created" | tail -6
  fi
  rm -f "$IMG_IDS" "$NEW_IDS"
fi
# the mesh pieces ride the vendor release the kit pinned when it
# installed them: an agent or GUI left behind is a support call, so the
# updater brings both to the latest official version, verified against
# the vendor checksums, same discipline as the installer.
NBLATEST=$(curl -fsSL --max-time 30 https://api.github.com/repos/netbirdio/netbird/releases/latest 2>/dev/null \
  | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
if [ -n "$NBLATEST" ]; then
  # the asset names come from the release itself at update time: a
  # vendor rebrand (same API, same links, new names) must never kill
  # the updater. The sha, not the name, proves the vendor.
  NB_ASSETS=$(curl -fsSL --max-time 30 "https://api.github.com/repos/netbirdio/netbird/releases/tags/v${NBLATEST}" 2>/dev/null | grep -oE '"name": *"[^"]*"' | sed 's/.*"name": *"\([^"]*\)".*/\1/')

  NBIN=$(command -v netbird 2>/dev/null || true)
  NBUIV=$(command -v netbird-ui 2>/dev/null || true)
  NB_DAEMON_VER=$("$NBIN" status 2>/dev/null | grep -oE 'Daemon version: [0-9.]+' | cut -d' ' -f3)
  if [ -x "$NBIN" ] && { [ "$(cat /etc/redoubt/netbird.version 2>/dev/null)" != "$NBLATEST" ] || { [ -n "$NB_DAEMON_VER" ] && [ "$NB_DAEMON_VER" != "$NBLATEST" ]; }; }; then
    echo "redoubt: netbird update available ($NBLATEST), pulling..."
    NBOK=0
    if { dpkg -s netbird >/dev/null 2>&1; } 2>/dev/null; then
      NBT=$(mktemp -d)
      chmod 700 "$NBT"
      NB_DEB=$(printf '%s\n' "$NB_ASSETS" | grep -E 'linux_amd64[.]deb$' | grep -v ui | head -1)
      NB_CK=$(printf '%s\n' "$NB_ASSETS" | grep -E 'checksums[.]txt$' | grep -vE 'ui|darwin|gtk3' | head -1)
      if nb_fetch_latest "$NB_DEB" "$NB_CK" "$NBT" \
        && { dpkg -i "$NBT/$NB_DEB" >/dev/null 2>&1 || apt-get install -y -f -qq >/dev/null 2>&1; }; then
        NBOK=1
      fi
      rm -rf "$NBT"
    else
      NBT=$(mktemp -d)
      chmod 700 "$NBT"
      NB_TGZ=$(printf '%s\n' "$NB_ASSETS" | grep -E 'linux_amd64[.]tar[.]gz$' | grep -vE 'ui|idp|mysql|nblink' | head -1)
      NB_CK=$(printf '%s\n' "$NB_ASSETS" | grep -E 'checksums[.]txt$' | grep -vE 'ui|darwin|gtk3' | head -1)
      if nb_fetch_latest "$NB_TGZ" "$NB_CK" "$NBT" \
        && tar -xzf "$NBT/$NB_TGZ" -C "$NBT" netbird && install -m 755 "$NBT/netbird" "$NBIN"; then
        NBOK=1
      fi
      rm -rf "$NBT"
    fi
    if [ "$NBOK" = "1" ]; then
      echo "$NBLATEST" > /etc/redoubt/netbird.version
      echo "redoubt: netbird $NBLATEST installed"
      NB_UNIT_BIN=$(systemctl cat netbird 2>/dev/null | sed -n 's|^ExecStart=/\([^ ]*\) .*|/\1|p' | head -1)
      if [ -n "$NB_UNIT_BIN" ] && [ "$NB_UNIT_BIN" != "$NBIN" ]; then
        "$NBIN" service uninstall >/dev/null 2>&1 || true
        "$NBIN" service install >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable netbird >/dev/null 2>&1 || true
        echo "redoubt: netbird service realigned to the active binary"
      fi
      systemctl restart netbird >/dev/null 2>&1 || true
    else
      echo "redoubt: netbird update failed, retrying on the next pass"
    fi
  fi
  if [ -x "$NBUIV" ]; then
    # the UI carries no version flag: the binary itself is the truth.
    # Compare the installed copy against the vendor release binary
    # (checksum-verified download, private tmp) and only touch the
    # machine when they differ. A stale stamp must never mask an old
    # binary again.
    NBT=$(mktemp -d)
    chmod 700 "$NBT"
    NBU_NEED=0
    NBUI_TGZ=$(printf '%s\n' "$NB_ASSETS" | grep -E 'linux_amd64[.]tar[.]gz$' | grep ui | grep -v gtk3 | head -1)
    NBU_CK=$(printf '%s\n' "$NB_ASSETS" | grep -E 'checksums[.]txt$' | grep ui | grep -vE 'darwin|gtk3' | head -1)
    if nb_fetch_latest "$NBUI_TGZ" "$NBU_CK" "$NBT" \
      && tar -xzf "$NBT/$NBUI_TGZ" -C "$NBT" netbird-ui \
      && ! cmp -s "$NBT/netbird-ui" "$NBUIV"; then
      NBU_NEED=1
    fi
    rm -rf "$NBT"
    if [ "$NBU_NEED" = "1" ]; then
      echo "redoubt: netbird-ui update available ($NBLATEST), pulling..."
      NBUOK=0
      if { dpkg -s netbird >/dev/null 2>&1; } 2>/dev/null; then
        NBT=$(mktemp -d)
        chmod 700 "$NBT"
        NBUI_DEB=$(printf '%s\n' "$NB_ASSETS" | grep -E 'linux_amd64[.]deb$' | grep ui | grep -v gtk3 | head -1)
        NBU_CK=$(printf '%s\n' "$NB_ASSETS" | grep -E 'checksums[.]txt$' | grep ui | grep -vE 'darwin|gtk3' | head -1)
        if nb_fetch_latest "$NBUI_DEB" "$NBU_CK" "$NBT" \
          && { dpkg -i "$NBT/$NBUI_DEB" >/dev/null 2>&1 || apt-get install -y -f -qq >/dev/null 2>&1; }; then
          NBUOK=1
        fi
        rm -rf "$NBT"
      else
        NBT=$(mktemp -d)
        chmod 700 "$NBT"
        NBUI_TGZ=$(printf '%s\n' "$NB_ASSETS" | grep -E 'linux_amd64[.]tar[.]gz$' | grep ui | grep -v gtk3 | head -1)
        NBU_CK=$(printf '%s\n' "$NB_ASSETS" | grep -E 'checksums[.]txt$' | grep ui | grep -vE 'darwin|gtk3' | head -1)
        if nb_fetch_latest "$NBUI_TGZ" "$NBU_CK" "$NBT" \
          && tar -xzf "$NBT/$NBUI_TGZ" -C "$NBT" netbird-ui && install -m 755 "$NBT/netbird-ui" "$NBUIV"; then
          NBUOK=1
        fi
        rm -rf "$NBT"
      fi
      if [ "$NBUOK" = "1" ]; then
        echo "$NBLATEST" > /etc/redoubt/netbird-ui.version
        echo "redoubt: netbird-ui $NBLATEST installed"
        pkill -x netbird-ui >/dev/null 2>&1 || true
        echo "redoubt: NetBird was updated - reopen it from the menu or the tray"
      else
        echo "redoubt: netbird-ui update failed, retrying on the next pass"
      fi
    fi
  fi
fi
echo "redoubt: already up to date"
exit 0
UPDATER
  mv -f /etc/redoubt/redoubt-update.sh.tmp /etc/redoubt/redoubt-update.sh
  chmod 700 /etc/redoubt/redoubt-update.sh
  if [ "$PKG_FAMILY" = "apt" ]; then
    cat > /etc/apt/apt.conf.d/99redoubt <<'APTHOOK'
// Redoubt: check for a newer kit after every apt update
DPkg::Post-Invoke "if [ -x /etc/redoubt/redoubt-update.sh ]; then /etc/redoubt/redoubt-update.sh; fi";
APTHOOK
    # The file has to stay world-readable. GUI tools (mintupdate,
    # synaptic, aptdaemon) init apt as the logged user, and a 600
    # root-only file makes them report "apt configuration is corrupt".
    chmod 644 /etc/apt/apt.conf.d/99redoubt
  fi
  if [ "$PKG_FAMILY" = "pacman" ]; then
    # The arch twin: pacman runs the same check after every upgrade or
    # install, so 'sudo pacman -Syu' patches the cloud too.
    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/99-redoubt.hook <<'PACHOOK'
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = *

[Action]
Description = Redoubt checks for a newer kit
When = PostTransaction
Exec = /etc/redoubt/redoubt-update.sh
PACHOOK
    chmod 644 /etc/pacman.d/hooks/99-redoubt.hook
  fi
  if [ "$PKG_FAMILY" = "dnf" ] || [ "$PKG_FAMILY" = "zypper" ]; then
    # these families carry no declarative post-transaction hook: a
    # daily timer runs the updater instead, so the client never has
    # to remember the command. Persistent catches missed runs after
    # the machine was off.
    cat > /etc/systemd/system/redoubt-update.service <<'RUSVC'
[Unit]
Description=Redoubt checks for a newer kit
[Service]
Type=oneshot
ExecStart=/etc/redoubt/redoubt-update.sh
RUSVC
    cat > /etc/systemd/system/redoubt-update.timer <<'RUTIMER'
[Unit]
Description=Daily Redoubt update check
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
RUTIMER
    chmod 644 /etc/systemd/system/redoubt-update.service /etc/systemd/system/redoubt-update.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now redoubt-update.timer >/dev/null 2>&1 || true
  fi
  if [ "$PKG_FAMILY" = "apt" ] || [ "$PKG_FAMILY" = "pacman" ]; then
    dbg "OK: self-update hooked into the package manager (updates patch the cloud)"
  else
    dbg "OK: daily self-update timer armed (updates patch the cloud)"
  fi
fi

# ============ the dashboard: one command ==========================
# 'redoubt' stays on the machine: status / creds / update / guide, with
# a plain-text fallback when gum is missing. The kit's own gum copy lives
# in /opt/redoubt/bin, so the dashboard never depends on the system PATH.
cat > /usr/local/bin/redoubt.tmp <<'REDOUBT'
#!/usr/bin/env bash
# redoubt - your private cloud's dashboard
export DEBIAN_FRONTEND=noninteractive
GUM=/opt/redoubt/bin/gum
[ -x "$GUM" ] || GUM=/usr/local/bin/gum
[ -x "$GUM" ] || GUM=""
# docker answers the owner without sudo once the kit's group lands on
# the user; the fallback elevates on its own. updates always run as root.
if [ "$(id -u)" -ne 0 ]; then
  if ! docker info >/dev/null 2>&1 || [ "${1:-}" = "update" ] || [ "${1:-}" = "qr" ]; then
    exec sudo "$0" "$@"
  fi
fi
case "${1:-}" in
  creds)
    if [ -r /etc/redoubt/credentials.txt ]; then
      cat /etc/redoubt/credentials.txt
    else
      cat "$HOME/Documents/My Redoubt/Access.txt" 2>/dev/null \
        || echo "credentials: cat \"$HOME/Documents/My Redoubt/Access.txt\""
    fi
    ;;
  update)
    if [ -x /etc/redoubt/redoubt-update.sh ]; then
      /etc/redoubt/redoubt-update.sh
    else
      echo "updater missing (older install); re-run the kit"
    fi
    ;;
  guide)
    GUIDE="$HOME/Documents/My Redoubt/Welcome Guide.txt"
    if [ -n "$GUM" ] && [ -f "$GUIDE" ]; then
      "$GUM" format < "$GUIDE"
    else
      cat "$GUIDE" 2>/dev/null || echo "guide not found"
    fi
    ;;
  qr)
    if ! command -v qrencode >/dev/null 2>&1; then
      echo "qrencode is missing; re-run the installer"
      exit 1
    fi
    P=/etc/redoubt/qr-payloads.txt
    [ -r "$P" ] || { echo "qr payloads missing; re-run the kit"; exit 1; }
    if [ -n "${2:-}" ] && [ "$2" -ge 1 ] 2>/dev/null; then
      N="$2"
    else
      N=""
      if [ "$TERM" = "linux" ]; then
        # the bare console has no scrollback: list the codes and let
        # the caller pick one at a time
        I=1
        while IFS='|' read -r NAME URL; do
          [ -n "$NAME" ] || continue
          echo "$I) $NAME"
          echo "   $URL"
          I=$((I+1))
        done < "$P"
        echo "run: redoubt qr <number> to print one code"
        exit 0
      fi
    fi
    I=1
    while IFS='|' read -r NAME URL; do
      [ -n "$NAME" ] || continue
      if [ -n "$N" ] && [ "$I" -ne "$N" ]; then
        I=$((I+1))
        continue
      fi
      if [ "$TERM" = "linux" ]; then
        # glyph QRs detect but do not decode on VGA consoles (the font
        # leaves gaps between cells). draw the code as a real PNG and
        # show it fullscreen on the framebuffer: a pixel-perfect QR
        # with its quiet zone, which the phone always decodes. fbi
        # installs on demand, headless machines only
        QRP=/tmp/redoubt-qr.png
        { command -v openvt >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; } || apt-get install -y -qq kbd >/dev/null 2>&1 || true
        if [ -e /dev/fb0 ] && command -v fbi >/dev/null 2>&1 && command -v openvt >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1 && qrencode -o "$QRP" -s 8 -m 4 --foreground=34D399 --background=D4D4D8 "$URL" 2>/dev/null; then
          echo "scan the code, it closes on its own"
          openvt -s -- fbi -a --noverbose "$QRP" >/dev/null 2>&1 || true
          sleep 30
          pkill -x fbi 2>/dev/null || true
          chvt 1 2>/dev/null || true
          rm -f "$QRP"
        else
          # no framebuffer painter on this box: the colored matrix
          # still scans from the text console (same style as the SSO)
          qrencode -t ANSI256 -s 2 -m 1 "$URL"
          echo "$URL"
        fi
      else
        echo "== $NAME =="
        qrencode -t ANSI256 -s 2 -m 1 "$URL"
        echo "$URL"
        echo ""
      fi
      I=$((I+1))
    done < "$P"
    ;;
  ""|status)
    if [ -n "$GUM" ]; then
      "$GUM" style --foreground 212 --bold "YOUR REDOUBT - live services"
      printf 'SERVICE\tSTATUS\tPORTS\n'
      docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
    else
      docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
    fi
    ;;
  *) echo "redoubt [status|creds|update|guide|qr]"; exit 1 ;;
esac
REDOUBT
mv -f /usr/local/bin/redoubt.tmp /usr/local/bin/redoubt
chmod 755 /usr/local/bin/redoubt
dbg "OK: the redoubt dashboard is installed (run: redoubt)"

# ============ pass safety net comes down: the install is complete ============
# every network change this pass made is in place and verified by now,
# so the snapshot's job is done: mark the pass complete, disarm the
# watcher and the boot failsafe, and drop the snapshot. From here on
# only the reveal is left, and the reveal changes nothing.
if [ -n "${WATCH_PID:-}" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
  : > /etc/redoubt/.install-complete
  chmod 600 /etc/redoubt/.install-complete
  rm -f /etc/redoubt/.pass-in-progress
  kill "$WATCH_PID" 2>/dev/null || true
  dbg "OK: pass safety net disarmed (install complete)"
  systemctl disable redoubt-failsafe >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/redoubt-failsafe.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf /etc/redoubt/.pass-snapshot
  # the completed state must survive a cut right after the pass: sync
  # so .install-complete and the disarmed failsafe reach the disk, or
  # the next boot would roll back a finished install
  sync
fi

# stop the painter before the final screen: a live background job can
# hold the shell in wait at exit and leave the installer lock behind
if [ -n "${ANIM_PID:-}" ]; then
  kill -9 "$ANIM_PID" 2>/dev/null || true
  ANIM_PID=""
fi

# ============ the guardian (Cerberus): the box's own caretaker ============
# A dedicated user runs Hermes with the Cerberus profile and the local
# brain (llama-server + the tier model). Nothing here is root, nothing
# phones home, and the panel's assistant talks to Cerberus over the
# internal docker subnet. Every piece is idempotent: re-runs reuse what
# is already in place.

GUARDIAN_USER="guardian"
GUARDIAN_PORT=8642
BRAIN_PORT=8686
GATEWAY_SVC="hermes-gateway-redoubt"
HERMES_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"
HERMES_INSTALL_SHA="abf338605dae6dd2"
GUARDIAN_PROFILE_URL="${REDOUBT_GUARDIAN_PROFILE_URL:-https://install.tryredoubt.com/install/guardian-profile.tar.gz}"
GUARDIAN_PROFILE_SHA="246fbc95b66cefb2"
BRAIN_IMAGE="ghcr.io/ggml-org/llama.cpp:server@sha256:c77881bba21e863bc56391995511f361040952f7ed6033cf1589da7f77a04eff"
BRAIN_MODEL_URL="${REDOUBT_BRAIN_MODEL_URL:-https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf}"
BRAIN_MODEL_SHA="00fe7986ff5f6b463e622b97d2ad18b5e7ccb1be6cd4c8e39e1c1de84a4421e5"
BRAIN_MODEL_FILE="qwen35-4b-q4km.gguf"
PANEL_DB_HOST="/var/lib/docker/volumes/redoubt_homarr-data/_data/db/db.sqlite"

# one place maps a tier to its parameters: the heuristics and the lab
# override both land here, never in separate if-chains. The 9B and the
# GPU image land in a later release; today every tier runs the verified
# 4B, full only widens the context budget.
set_tier_params() {
  case "$1" in
    full)
      BRAIN_MODEL_FILE="qwen35-4b-q4km.gguf"; BRAIN_CTX=131072 ;;
    standard)
      BRAIN_MODEL_FILE="qwen35-4b-q4km.gguf"; BRAIN_CTX=131072 ;;
    tiny)
      BRAIN_MODEL_FILE="qwen35-4b-q4km.gguf"; BRAIN_CTX=65536 ;;
  esac
}

# what this machine can carry. full = discrete GPU with 6GB+ VRAM,
# standard = 10GB+ RAM and no GPU, tiny = the honest floor (AVX2
# required). REDOUBT_TIER forces a tier for lab runs.
detect_tier() {
  local ram_gb vram gpu_line avx2

  if [ -n "${REDOUBT_TIER:-}" ]; then
    TIER="$REDOUBT_TIER"
    set_tier_params "$TIER"
    TIER_NOTE="forced by REDOUBT_TIER (lab only)"
    return
  fi

  ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)

  gpu_line=""
  vram=""
  if command -v lspci >/dev/null 2>&1; then
    gpu_line=$(lspci -nn 2>/dev/null | grep -iE "vga compatible|3d controller|display controller" | grep -viE "virtio|qxl|vmware|bochs|cirrus|red hat" | head -1)
  fi
  if [ -n "$gpu_line" ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
      vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d " ")
    elif command -v rocm-smi >/dev/null 2>&1; then
      vram=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oE "[0-9]+" | head -1)
    fi
  fi

  avx2=0
  grep -q avx2 /proc/cpuinfo 2>/dev/null && avx2=1

  if [ -n "$vram" ] && [ "$vram" -ge 6144 ]; then
    TIER="full"
    TIER_NOTE="gpu with $vram MiB vram"
  elif [ "$ram_gb" -lt 10 ]; then
    TIER="tiny"
    TIER_NOTE="low ram, 64K context"
  else
    TIER="standard"
    TIER_NOTE=""
  fi

  if [ "$avx2" -ne 1 ]; then
    TIER="tiny"
    TIER_NOTE="${TIER_NOTE:+$TIER_NOTE, }no avx2, reduced"
  fi

  set_tier_params "$TIER"
}

install_guardian_user() {
  if ! id "$GUARDIAN_USER" >/dev/null 2>&1; then
    useradd -r -m -s /bin/bash "$GUARDIAN_USER"
    echo "guardian: user $GUARDIAN_USER created"
  fi
  usermod -aG docker "$GUARDIAN_USER" 2>/dev/null || true
}

install_guardian_hermes() {
  local inst="/home/$GUARDIAN_USER/hermes-install.sh"
  echo "guardian: downloading hermes (this takes a minute) ..."
  # -# keeps the transfer visible: a silent multi-minute fetch on a slow
  # link looks frozen, and owners kill frozen things
  su - "$GUARDIAN_USER" -c "curl -fL --progress-bar '$HERMES_INSTALL_URL' -o '$inst'"
  local got
  got=$(sha256sum "$inst" | cut -d' ' -f1)
  if [ "$got" != "$HERMES_INSTALL_SHA" ]; then
    rm -f "$inst"
    echo "guardian: hermes installer sha mismatch ($got) - refusing to run it"
    return 1
  fi
  # the installer runs as the guardian user: the whole hermes tree lands
  # under /home/guardian/.local, nowhere near root
  su - "$GUARDIAN_USER" -c "bash '$inst' && rm -f '$inst'"
  local ver
  ver=$(su - "$GUARDIAN_USER" -c "~/.local/bin/hermes --version" 2>/dev/null \
        | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
  [ -n "$ver" ] && echo "guardian: hermes $ver installed" \
                || echo "guardian: WARNING could not read hermes version"
}

install_guardian_profile() {
  local pf="/home/$GUARDIAN_USER/guardian-profile.tar.gz"
  su - "$GUARDIAN_USER" -c "curl -fsSL '$GUARDIAN_PROFILE_URL' -o '$pf'"
  local got
  got=$(sha256sum "$pf" | cut -d' ' -f1)
  if [ "$got" != "$GUARDIAN_PROFILE_SHA" ]; then
    rm -f "$pf"
    echo "guardian: profile sha mismatch ($got) - refusing to import it"
    return 1
  fi
  su - "$GUARDIAN_USER" -c "~/.local/bin/hermes profile import '$pf'"
  rm -f "$pf"
  echo "guardian: Cerberus profile imported"
}

guardian_key() {
  local env="/home/$GUARDIAN_USER/.hermes/profiles/redoubt/.env"
  mkdir -p "$(dirname "$env")"
  if ! grep -q "^API_SERVER_KEY=" "$env" 2>/dev/null; then
    local key
    key=$(openssl rand -hex 32)
    printf 'API_SERVER_KEY=%s\nAPI_SERVER_MODEL_NAME=Cerberus\n' "$key" >> "$env"
    chown "$GUARDIAN_USER:$GUARDIAN_USER" "$env"
    chmod 600 "$env"
    echo "guardian: api key generated"
  fi
}

guardian_brain() {
  local mdir="/var/lib/redoubt/brain/models"
  local mf="$mdir/$BRAIN_MODEL_FILE"
  mkdir -p "$mdir"
  if [ ! -f "$mf" ]; then
    echo "guardian: downloading the brain model ($BRAIN_MODEL_FILE) ..."
    curl -fL --retry 3 -o "$mf" "$BRAIN_MODEL_URL" || return 1
    local got
    got=$(sha256sum "$mf" | cut -d' ' -f1)
    if [ "$got" != "$BRAIN_MODEL_SHA" ]; then
      rm -f "$mf"
      echo "guardian: model sha mismatch ($got) - refusing to run it"
      return 1
    fi
  fi
  local cores
  cores=$(nproc)
  cat > /opt/redoubt/brain-compose.yml <<BRAIN
name: redoubt
services:
  brain:
    image: $BRAIN_IMAGE
    container_name: redoubt-brain-1
    restart: always
    command:
      - -m
      - /models/$BRAIN_MODEL_FILE
      - --host
      - 0.0.0.0
      - --port
      - "$BRAIN_PORT"
      - -c
      - "${BRAIN_CTX:-65536}"
      - -ctk
      - q4_0
      - -t
      - "$cores"
      - --chat-template-kwargs
      - '{"enable_thinking": false}'
    volumes:
      - $mdir:/models:ro
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/127.0.0.1/$BRAIN_PORT'"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 120s
    networks:
      - default
networks:
  default:
    external: true
    name: redoubt_default
BRAIN
  docker compose -f /opt/redoubt/brain-compose.yml up -d
  echo "guardian: brain up (ctx ${BRAIN_CTX:-65536}, $cores cores, tier $TIER)"
}

guardian_gateway() {
  su - "$GUARDIAN_USER" -c \
    "~/.local/bin/hermes -p redoubt gateway install --force" >/dev/null 2>&1
  loginctl enable-linger "$GUARDIAN_USER" 2>/dev/null || true
  su - "$GUARDIAN_USER" -c \
    "systemctl --user enable $GATEWAY_SVC 2>/dev/null; systemctl --user restart $GATEWAY_SVC" \
    >/dev/null 2>&1
  echo "guardian: gateway service up"
}

guardian_ufw() {
  # the guardian is native on the host; container traffic to it crosses
  # the docker gateway and DOES hit ufw, so open the port for the subnet
  if command -v ufw >/dev/null 2>&1; then
    ufw allow from 172.28.0.0/16 to any port "$GUARDIAN_PORT" proto tcp >/dev/null 2>&1 || true
    echo "guardian: ufw rule for the panel subnet"
  fi
}

guardian_wire_assistant() {
  # the panel needs a few seconds of first boot before its DB exists
  local i
  for i in $(seq 1 30); do
    [ -f "$PANEL_DB_HOST" ] && break
    sleep 5
  done
  [ -f "$PANEL_DB_HOST" ] || { echo "guardian: panel DB not found - wiring skipped"; return 1; }

  local key cipher back
  key=$(grep "^API_SERVER_KEY=" "/home/$GUARDIAN_USER/.hermes/profiles/redoubt/.env" | cut -d= -f2)
  # encrypt inside the panel container with its own SECRET_ENCRYPTION_KEY
  # (node lives there; the host has no guarantee of a crypto lib)
  cipher=$(docker exec redoubt-homarr-1 node -e '
    const c = require("crypto");
    const k = Buffer.from(process.env.SECRET_ENCRYPTION_KEY, "hex");
    const iv = c.randomBytes(16);
    const ci = c.createCipheriv("aes-256-cbc", k, iv);
    const out = Buffer.concat([ci.update(process.argv[1], "utf8"), ci.final()]);
    console.log(out.toString("hex") + "." + iv.toString("hex"));
  ' "$key" 2>/dev/null)
  [ -n "$cipher" ] || { echo "guardian: could not encrypt the api key"; return 1; }

  # roundtrip before the UPDATE: decrypt what we would store and compare
  back=$(docker exec redoubt-homarr-1 node -e '
    const c = require("crypto");
    const k = Buffer.from(process.env.SECRET_ENCRYPTION_KEY, "hex");
    const [data, iv] = process.argv[1].split(".");
    const d = c.createDecipheriv("aes-256-cbc", k, Buffer.from(iv, "hex"));
    const out = Buffer.concat([d.update(Buffer.from(data, "hex")), d.final()]);
    console.log(out.toString("utf8"));
  ' "$cipher" 2>/dev/null)
  [ "$back" = "$key" ] || { echo "guardian: encrypt roundtrip failed"; return 1; }

  python3 - "$PANEL_DB_HOST" "$cipher" <<'WIRE'
import sqlite3, sys
db, cipher = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db)
c.execute("""UPDATE assistant_configuration SET
             provider='custom',
             base_url='http://172.28.0.1:8642/v1',
             model_discovery_path='/models',
             model_id='Cerberus',
             encrypted_api_key=?,
             encrypted_headers=NULL,
             enabled=1
             WHERE id='default'""", (cipher,))
c.commit()
row = c.execute("SELECT provider, model_id, enabled FROM assistant_configuration WHERE id='default'").fetchone()
print('guardian: assistant wired', row)
WIRE
}

guardian_warmup() {
  local key i
  key=$(grep "^API_SERVER_KEY=" "/home/$GUARDIAN_USER/.hermes/profiles/redoubt/.env" | cut -d= -f2)
  for i in $(seq 1 60); do
    curl -fsS -m 3 http://127.0.0.1:8642/health >/dev/null 2>&1 && break
    sleep 5
  done
  curl -s -m 900 http://127.0.0.1:8642/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d '{"model":"Cerberus","messages":[{"role":"user","content":"Stand by."}],"max_tokens":32}' \
    >/dev/null 2>&1
  echo "guardian: warm-up request done (the system prompt is cached now)"
}

guardian_verify() {
  local key resp
  key=$(grep "^API_SERVER_KEY=" "/home/$GUARDIAN_USER/.hermes/profiles/redoubt/.env" | cut -d= -f2)
  resp=$(curl -s -m 900 http://127.0.0.1:8642/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d '{"model":"Cerberus","messages":[{"role":"user","content":"Are the gates closed?"}],"max_tokens":64}')
  if printf '%s' "$resp" | grep -q '"content"'; then
    echo "guardian: VERIFIED - Cerberus answered (tier $TIER)"
    return 0
  fi
  echo "guardian: verification FAILED - the guardian did not answer"
  return 1
}

guardian() {
  detect_tier
  install_guardian_user || return 1
  install_guardian_hermes || return 1
  install_guardian_profile || return 1
  guardian_key
  guardian_brain || return 1
  guardian_gateway
  guardian_ufw
  guardian_wire_assistant
  guardian_warmup
  guardian_verify || echo "guardian: WARNING the end-to-end check failed"
}

guardian


# ============ the reveal: one clean screen, not a wall ==================
{
  GUM_BIN=/opt/redoubt/bin/gum
  [ -x "$GUM_BIN" ] || GUM_BIN=/usr/local/bin/gum
  [ -x "$GUM_BIN" ] || GUM_BIN=""
  if [ -n "$GUM_BIN" ]; then
    print_bastion
    echo ""
    echo ""
    cursor_show
    "$GUM_BIN" style --width 46 --margin "0 0 0 7" --align center --foreground "#34d399" --bold "Your cloud is alive"
    echo ""
    "$GUM_BIN" style --foreground "#34d399" --bold "YOUR APPS"
    printf "  photos   ${EM3}https://${APPS_HOST}:%s\n" "$PORT_EDGE1" | "$GUM_BIN" style --no-strip-ansi --foreground "#6ee7b7"
    printf "  files    ${EM3}https://${APPS_HOST}:%s\n" "$PORT_EDGE2" | "$GUM_BIN" style --no-strip-ansi --foreground "#6ee7b7"
    printf "  search   ${EM3}https://${APPS_HOST}:%s\n" "$PORT_EDGE3" | "$GUM_BIN" style --no-strip-ansi --foreground "#6ee7b7"
    printf "  dockge   ${EM3}http://127.0.0.1:%s\n" "$PORT_DOCKGE" | "$GUM_BIN" style --no-strip-ansi --foreground "#6ee7b7"
    printf "  panel    ${EM3}https://${APPS_HOST}:%s\n" "$PORT_EDGE4" | "$GUM_BIN" style --no-strip-ansi --foreground "#6ee7b7"
    printf "  ad shield ${EM3}https://redoubt.lan:%s/admin\n" "$PORT_EDGE5" | "$GUM_BIN" style --no-strip-ansi --foreground "#6ee7b7"
if [ "$MESH_MODE" = "selfhost" ]; then
      "$GUM_BIN" style --foreground 240 --bold "your mesh"
      printf '  console https://%s:%s (NetBird dashboard, your owner login)\n' "$REMOTE_HOST" "$PORT_DASH" | "$GUM_BIN" style --foreground 240
      if [ "${FW_DECISION:-}" = "on" ]; then
        "$GUM_BIN" style --foreground 240 --bold "home wifi"
        printf '  photos  https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE1" | "$GUM_BIN" style --foreground 240
        printf '  files   https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE2" | "$GUM_BIN" style --foreground 240
        printf '  search  https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE3" | "$GUM_BIN" style --foreground 240
        printf '  panel   https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE4" | "$GUM_BIN" style --foreground 240
      else
        "$GUM_BIN" style --foreground 240 "  the wifi sees nothing: your apps answer only to your mesh devices"
      fi
else
      "$GUM_BIN" style --foreground 240 --bold "home wifi"
      printf '  photos  https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE1" | "$GUM_BIN" style --foreground 240
      printf '  files   https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE2" | "$GUM_BIN" style --foreground 240
      printf '  search  https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE3" | "$GUM_BIN" style --foreground 240
      printf '  panel   https://%s:%s\n' "$LAN_HOST" "$PORT_EDGE4" | "$GUM_BIN" style --foreground 240
      printf '  console https://app.netbird.io (your NetBird account)\n' | "$GUM_BIN" style --foreground 240
fi
    printf '  ad shield https://redoubt.lan:%s/admin\n' "$PORT_EDGE5" | "$GUM_BIN" style --foreground 240
    echo ""
    "$GUM_BIN" style --foreground "#34d399" --bold "YOUR DEVICES"
    printf '  %s\n' "${ACCESS_MESH#device mesh: }" | "$GUM_BIN" style --foreground "#6ee7b7"
    printf "  phone cert: ${EM3}http://%s:8086/ca${EM2}  (open on the device, install it)\n" "${MESH_IP:-$LAN_IP}" | "$GUM_BIN" style --no-strip-ansi --foreground "#6ee7b7"
    echo ""
    if [ "$REINSTALL" != "1" ]; then
      "$GUM_BIN" style --foreground "#34d399" --bold "CREDENTIALS"
      sed 's/^/  /' /etc/redoubt/credentials.txt 2>/dev/null | "$GUM_BIN" style --foreground 255
    else
      "$GUM_BIN" style --foreground 240 "credentials: redoubt creds (kept from your first install)"
    fi
    echo ""
    "$GUM_BIN" style --foreground 240 "Run: redoubt (status | creds | update | guide${QR_HINT})"
    if [ "${FF_RUNNING:-0}" = "1" ]; then
      "$GUM_BIN" style --foreground 240 "Browser was open during the install: close and reopen it for the green padlock (or run: redoubt update)"
    fi
  else
    print_bastion
    # the tagline centers on the bastion's visual core, not on the
    # terminal width: the pad lands its center over the main tower
    printf -v _ALIVEPAD '%*s' "$(( 20 ))" ''
    cursor_show
    printf "${EM1}%sYour cloud is alive${RESET}\n" "$_ALIVEPAD"
    print_rule
    printf "${EM1}  YOUR APPS${RESET}\n"
    printf "${EM2}  photos:  ${EM3}https://${APPS_HOST}:%s${RESET}\n" "$PORT_EDGE1"
    printf "${EM2}  files:   ${EM3}https://${APPS_HOST}:%s${RESET}\n" "$PORT_EDGE2"
    printf "${EM2}  search:  ${EM3}https://${APPS_HOST}:%s${RESET}\n" "$PORT_EDGE3"
    printf "${EM2}  dockge:  ${EM3}http://127.0.0.1:%s${RESET}\n" "$PORT_DOCKGE"
    printf "${EM2}  panel:   ${EM3}https://${APPS_HOST}:%s${RESET}\n" "$PORT_EDGE4"
    printf "${EM2}  ad shield: ${EM3}https://redoubt.lan:%s/admin${RESET}\n" "$PORT_EDGE5"
if [ "$MESH_MODE" = "selfhost" ]; then
        printf "${EM1}  your mesh${RESET}\n"
        printf "${EM2}    console https://${REMOTE_HOST}:%s (NetBird dashboard, your owner login)${RESET}\n" "$PORT_DASH"
        if [ "${FW_DECISION:-}" = "on" ]; then
          printf "${EM1}  home wifi${RESET}\n"
          printf "${EM2}    photos  https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE1"
          printf "${EM2}    files   https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE2"
          printf "${EM2}    search  https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE3"
          printf "${EM2}    panel   https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE4"
        else
          printf "${EM2}    the wifi sees nothing: your apps answer only to your mesh devices${RESET}\n"
        fi
else
        printf "${EM1}  home wifi${RESET}\n"
        printf "${EM2}    photos  https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE1"
        printf "${EM2}    files   https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE2"
        printf "${EM2}    search  https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE3"
        printf "${EM2}    panel   https://${LAN_HOST}:%s${RESET}\n" "$PORT_EDGE4"
        printf "${EM2}    console https://app.netbird.io (your NetBird account)${RESET}\n"
fi
      printf "${EM2}    ad shield https://redoubt.lan:%s/admin${RESET}\n" "$PORT_EDGE5"
    printf "${EM1}  YOUR DEVICES${RESET}\n"
    printf "${EM2}  %s${RESET}\n" "${ACCESS_MESH#device mesh: }"
    printf "${EM2}  phone cert: ${EM3}http://%s:8086/ca${EM2}  (open on the device, install it)${RESET}\n" "${MESH_IP:-$LAN_IP}"
    echo "  run: redoubt (creds, guide, status, update${QR_HINT})"
    if [ "${FF_RUNNING:-0}" = "1" ]; then
      echo "  Browser was open during the install: close and reopen it for the green padlock (or run: redoubt update)"
    fi
    if [ "$HAS_GUI" = "0" ]; then
      echo "  no screen here: redoubt guide prints the phone steps as text"
    fi
    print_rule
  fi
} >&3

exit $RC

