#!/usr/bin/env bash
#
# rog-menu.sh — a numbered-menu front end for asusctl
#
# Targets asusctl 6.3+ (nested subcommand syntax: `profile set`, `battery limit`,
# `leds set`). Written with the ROG Zephyrus G14 (GA402) in mind, but menus are
# shown or hidden based on what `asusctl info --show-supported` reports.
#
# Usage: ./rog-menu.sh [--all] [--dry-run] [--setup] [--help]
#   --all, -a      show every menu even if the hardware doesn't report support
#   --dry-run, -n  print changing commands instead of running them
#   --setup, -s    open the setup / install menu first (CachyOS / Arch)
#   --help, -h     show this help
#
# If a command fails because asusctl's syntax changed in your version, use the
# "Command help / reference" menu to check the current syntax, then edit the
# matching function below. Each menu lives in its own function.

set -o pipefail

readonly MIN_ASUSCTL_VERSION="6.3.0"

SHOW_ALL=0
START_SETUP=0
DRY_RUN=0
SUPPORTED=""
ASUSCTL_VERSION="unknown"
WARN_COUNT=0
LAST_LED_LEVEL="med"
CHOICE=0
PICKED=""
REPLY_VAL=""
COLOR=""
PROFILES=()

# ---------------------------------------------------------------------------
# Colors and output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
  C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim 2>/dev/null || true)
  C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

info()    { printf '%s\n' "${C_CYAN}$*${C_RESET}"; }
ok()      { printf '%s\n' "${C_GREEN}✔ $*${C_RESET}"; }
warn()    { printf '%s\n' "${C_YELLOW}⚠ $*${C_RESET}"; WARN_COUNT=$((WARN_COUNT + 1)); }
err()     { printf '%s\n' "${C_RED}✖ $*${C_RESET}" >&2; }
die()     { err "$*"; exit 1; }
section() { printf '\n%s\n' "${C_BOLD}--- $* ---${C_RESET}"; }
pause()   { echo; read -rp "Press Enter to continue..." _ || exit 0; }

clear_screen() { if [[ -t 1 ]]; then clear; fi; }
header() { clear_screen; printf '%s\n\n' "${C_BOLD}=== $* ===${C_RESET}"; }

# ---------------------------------------------------------------------------
# Command runners
# ---------------------------------------------------------------------------

# Run a command that changes something. Honors --dry-run.
run_cmd() {
  printf '%s\n' "${C_DIM}\$ $*${C_RESET}"
  if (( DRY_RUN )); then info "(dry run, not executed)"; return 0; fi
  "$@"
  local rc=$?
  if (( rc == 0 )); then ok "Done."; else err "Command failed (exit $rc). Check the syntax in the help menu."; fi
  return "$rc"
}

# Run a read-only command (runs even in dry-run mode, since it changes nothing).
run_show() {
  printf '%s\n' "${C_DIM}\$ $*${C_RESET}"
  if ! command -v "$1" >/dev/null 2>&1; then err "$1 is not installed."; return 1; fi
  "$@"
  local rc=$?
  (( rc == 0 )) || err "Command failed (exit $rc)."
  return "$rc"
}

# Try several syntax variants of the same command, in order, until one works.
# Used where asusctl's syntax has changed between versions.
# Each argument is one full command string; arguments within it must not contain spaces.
run_alt() {
  local alt i=0 n=$# out rc earlier=""
  local -a parts
  for alt in "$@"; do
    i=$((i + 1))
    read -r -a parts <<<"$alt"
    if (( DRY_RUN )); then
      printf '%s\n' "${C_DIM}\$ $alt${C_RESET}"; info "(dry run, not executed)"; return 0
    fi
    if (( i < n )); then
      if out=$("${parts[@]}" 2>&1); then
        printf '%s\n' "${C_DIM}\$ $alt${C_RESET}"
        [[ -n $out ]] && printf '%s\n' "$out"
        ok "Done."; return 0
      fi
      earlier+="  \$ $alt"$'\n'"$(sed 's/^/      /' <<<"$out")"$'\n'
    else
      printf '%s\n' "${C_DIM}\$ $alt${C_RESET}"
      "${parts[@]}"; rc=$?
      if (( rc == 0 )); then ok "Done."; return 0; fi
      err "Command failed (exit $rc)."
      if [[ -n $earlier ]]; then
        printf '%s\n%s' "${C_YELLOW}Earlier syntax variant(s) also failed:${C_RESET}" "$earlier"
      fi
      return "$rc"
    fi
  done
}

# Print a command's output for a status line, or "unavailable".
quiet_out() {
  local out
  if out=$("$@" 2>/dev/null) && [[ -n $out ]]; then
    printf '%s\n' "$out" | head -n 3
  else
    echo "unavailable"
  fi
}

# ---------------------------------------------------------------------------
# Input helpers
# ---------------------------------------------------------------------------

# choose "Title" "option 1" "option 2" ...  -> sets CHOICE (0 = back)
# Set BACK_LABEL in the environment to rename the 0 option.
choose() {
  local title=$1; shift
  local -a opts=("$@")
  local i c
  while true; do
    printf '%s\n' "${C_BOLD}$title${C_RESET}"
    for i in "${!opts[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${opts[i]}"; done
    printf '   0) %s\n\n' "${BACK_LABEL:-Back}"
    read -rp "Select an option: " c || { echo; exit 0; }
    if [[ $c =~ ^[0-9]+$ ]] && (( 10#$c <= ${#opts[@]} )); then
      CHOICE=$((10#$c)); return 0
    fi
    printf '%s\n\n' "${C_YELLOW}Invalid choice: '$c'${C_RESET}"
  done
}

# pick_from "Title" items... -> sets PICKED, returns 1 on cancel
pick_from() {
  local title=$1; shift
  BACK_LABEL="Cancel" choose "$title" "$@"
  (( CHOICE == 0 )) && return 1
  PICKED="${*:CHOICE:1}"
  return 0
}

confirm() {
  local a
  read -rp "$1 [y/N] " a || return 1
  [[ $a =~ ^[Yy]([Ee][Ss])?$ ]]
}

# read_int "Prompt" min max -> sets REPLY_VAL, returns 1 on cancel
read_int() {
  local v
  while true; do
    read -rp "$1 ($2-$3, blank to cancel): " v || return 1
    [[ -z $v ]] && return 1
    if [[ $v =~ ^[0-9]+$ ]] && (( 10#$v >= $2 && 10#$v <= $3 )); then
      REPLY_VAL=$((10#$v)); return 0
    fi
    printf '%s\n' "${C_YELLOW}Please enter a whole number from $2 to $3.${C_RESET}"
  done
}

# pick_color "Title" -> sets COLOR (6-digit hex, no #), returns 1 on cancel
pick_color() {
  local -a names=(Red Orange Yellow Green Cyan Blue Purple Pink White "Custom hex code")
  local -a hexes=(ff0000 ff6600 ffcc00 00ff00 00ffff 0000ff 8000ff ff00aa ffffff "")
  pick_from "${1:-Pick a color:}" "${names[@]}" || return 1
  local idx=$((CHOICE - 1)) h
  if [[ -n ${hexes[idx]} ]]; then COLOR=${hexes[idx]}; return 0; fi
  while true; do
    read -rp "Hex color, e.g. ff8800 (blank to cancel): " h || return 1
    [[ -z $h ]] && return 1
    h=${h#\#}
    if [[ $h =~ ^[0-9a-fA-F]{6}$ ]]; then COLOR=${h,,}; return 0; fi
    printf '%s\n' "${C_YELLOW}Enter exactly 6 hex digits.${C_RESET}"
  done
}

pick_speed() {
  pick_from "Effect speed:" "Low" "Medium" "High" || return 1
  case $CHOICE in 1) PICKED=low ;; 2) PICKED=med ;; 3) PICKED=high ;; esac
}

# ---------------------------------------------------------------------------
# Startup checks
# ---------------------------------------------------------------------------
check_dependencies() {
  if ! command -v asusctl >/dev/null 2>&1; then
    warn "asusctl is not installed."
    if command -v pacman >/dev/null 2>&1 && confirm "Open the setup menu to install it now?"; then
      menu_setup
    fi
    if ! command -v asusctl >/dev/null 2>&1; then
      if (( DRY_RUN )); then
        warn "asusctl not found (continuing because this is a dry run)."
      else
        die "asusctl is required. Run '${0##*/} --setup' to install it."
      fi
    fi
  fi

  if command -v systemctl >/dev/null 2>&1 && command -v asusctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet asusd; then
      warn "The asusd service isn't running, so asusctl commands will fail."
      if confirm "Start it now with sudo?"; then
        sudo systemctl start asusd && ok "asusd started." || err "Couldn't start asusd."
      fi
    fi
    if ! systemctl is-active --quiet power-profiles-daemon && ! systemctl is-active --quiet tuned-ppd; then
      warn "Neither power-profiles-daemon nor tuned-ppd is running; profile switching may not work."
    fi
  fi

}

check_version() {
  command -v asusctl >/dev/null 2>&1 || return
  local out
  out=$(asusctl --version 2>/dev/null || asusctl info 2>/dev/null)
  ASUSCTL_VERSION=$(grep -iE 'asusctl|version' <<<"$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  if [[ -z $ASUSCTL_VERSION ]]; then
    ASUSCTL_VERSION="unknown"
    warn "Couldn't detect the asusctl version."
    return
  fi
  local lowest
  lowest=$(printf '%s\n%s\n' "$MIN_ASUSCTL_VERSION" "$ASUSCTL_VERSION" | sort -V | head -n1)
  if [[ $lowest != "$MIN_ASUSCTL_VERSION" ]]; then
    warn "asusctl $ASUSCTL_VERSION is older than $MIN_ASUSCTL_VERSION; some commands here use newer syntax and may fail."
  fi
}

detect_capabilities() {
  command -v asusctl >/dev/null 2>&1 || return
  SUPPORTED=$(asusctl info --show-supported 2>/dev/null)
  [[ -z $SUPPORTED ]] && warn "Couldn't read supported features; showing all menus."
}

# has_feature "regex" -> true if the hardware reports support for it
has_feature() {
  (( SHOW_ALL )) && return 0
  [[ -z $SUPPORTED ]] && return 0
  grep -iE "$1" <<<"$SUPPORTED" | grep -qviE 'false|unsupported|not supported'
}

# ---------------------------------------------------------------------------
# Profile helpers
# ---------------------------------------------------------------------------
get_profiles() {
  local out
  out=$(asusctl profile list 2>/dev/null)
  mapfile -t PROFILES < <(grep -oE '\b(LowPower|Quiet|Balanced|Performance|Custom)\b' <<<"$out" | awk '!seen[$0]++')
  (( ${#PROFILES[@]} )) || PROFILES=(Quiet Balanced Performance)
}

# resolve_profile name [alt-name...] -> prints the first name this laptop actually uses
resolve_profile() {
  get_profiles
  local want p
  for want in "$@"; do
    for p in "${PROFILES[@]}"; do
      if [[ ${p,,} == "${want,,}" ]]; then echo "$p"; return 0; fi
    done
  done
  echo "$1"
}

pick_profile() {
  get_profiles
  pick_from "${1:-Select a profile:}" "${PROFILES[@]}"
}

# ---------------------------------------------------------------------------
# Menu: status overview
# ---------------------------------------------------------------------------
show_status() {
  header "System Status"
  section "Laptop / asusctl";      run_show asusctl info
  section "Performance profile";   run_show asusctl profile get
  section "Battery";               run_show asusctl battery info
  section "Keyboard brightness";   run_show asusctl leds get
  if has_feature 'fan.?curve'; then
    section "Custom fan curves enabled"; run_show asusctl fan-curve --get-enabled
  fi
  if gpu_available; then
    section "GPU mode"; echo "$(gpu_label "$(gpu_current_mode)")"
  fi
  pause
}

# ---------------------------------------------------------------------------
# Menu: quick presets
# ---------------------------------------------------------------------------
# apply_preset "Label" profile-name(s, |-separated) charge-limit led-level gpu-mode(or "")
apply_preset() {
  local label=$1 profile limit=$3 leds=$4 gpu=$5
  local -a names
  IFS='|' read -r -a names <<<"$2"
  profile=$(resolve_profile "${names[@]}")

  echo "The \"$label\" preset will:"
  echo "  • set the performance profile to $profile"
  echo "  • set the battery charge limit to ${limit}%"
  echo "  • set keyboard brightness to $leds"
  if [[ -n $gpu ]] && gpu_available; then
    echo "  • offer to switch the GPU to $(gpu_label "$gpu") mode (asks separately)"
  fi
  echo
  confirm "Apply it?" || return

  run_cmd asusctl profile set "$profile"
  run_cmd asusctl battery limit "$limit"
  run_cmd asusctl leds set "$leds" && [[ $leds != off ]] && LAST_LED_LEVEL=$leds

  if [[ -n $gpu ]] && gpu_available; then
    echo
    set_gpu_mode "$gpu"
  fi
}

menu_presets() {
  while true; do
    header "Quick Presets"
    choose "Pick a preset to apply:" \
      "Battery saver   (quiet profile, 80% limit, lights off, Eco GPU)" \
      "Everyday        (balanced profile, 80% limit, lights low)" \
      "Gaming          (performance profile, 100% limit, lights high, Optimized GPU)" \
      "Desk / docked   (balanced profile, 60% limit for battery longevity, lights medium)"
    case $CHOICE in
      0) return ;;
      1) apply_preset "Battery saver" "Quiet|LowPower" 80 off eco ;;
      2) apply_preset "Everyday" "Balanced" 80 low "" ;;
      3) apply_preset "Gaming" "Performance" 100 high optimized ;;
      4) apply_preset "Desk / docked" "Balanced" 60 med "" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: performance profiles
# ---------------------------------------------------------------------------
menu_profiles() {
  while true; do
    header "Performance Profiles"
    echo "Current: $(quiet_out asusctl profile get)"; echo
    choose "Choose an action:" \
      "Show current profile" \
      "List available profiles" \
      "Set active profile" \
      "Cycle to next profile" \
      "Set default profile when plugged in (AC)" \
      "Set default profile on battery"
    case $CHOICE in
      0) return ;;
      1) run_show asusctl profile get ;;
      2) run_show asusctl profile list ;;
      3) pick_profile && run_cmd asusctl profile set "$PICKED" ;;
      4) run_cmd asusctl profile next ;;
      5) pick_profile "Profile to use on AC power:" && run_cmd asusctl profile set "$PICKED" -a ;;
      6) pick_profile "Profile to use on battery:" && run_cmd asusctl profile set "$PICKED" -b ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: battery
# ---------------------------------------------------------------------------
menu_battery() {
  while true; do
    header "Battery Charging"
    echo "Current: $(quiet_out asusctl battery info)"; echo
    choose "Choose an action:" \
      "Show battery / charge-limit info" \
      "Limit to 60%  (best longevity if you're mostly plugged in)" \
      "Limit to 80%  (good everyday balance)" \
      "Limit to 100% (full capacity)" \
      "Set a custom limit" \
      "One-time full charge, then return to the limit"
    case $CHOICE in
      0) return ;;
      1) run_show asusctl battery info ;;
      2) run_cmd asusctl battery limit 60 ;;
      3) run_cmd asusctl battery limit 80 ;;
      4) run_cmd asusctl battery limit 100 ;;
      5) read_int "Charge limit percent" 20 100 && run_cmd asusctl battery limit "$REPLY_VAL" ;;
      6) run_cmd asusctl battery oneshot ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: keyboard lighting
# ---------------------------------------------------------------------------
AURA_MODES=()
AURA_MODES_DETECTED=0

set_leds() {
  run_cmd asusctl leds set "$1" && [[ $1 != off ]] && LAST_LED_LEVEL=$1
}

# Read the effects this keyboard supports from `asusctl info --show-supported`,
# e.g. "Supported Aura Modes: [Static, Breathe, Pulse]".
get_aura_modes() {
  local line
  line=$(grep -iE 'aura modes' <<<"$SUPPORTED" | head -n1)
  mapfile -t AURA_MODES < <(grep -oE '[A-Za-z]+' <<<"${line#*:}" | awk '!seen[$0]++')
  if (( ${#AURA_MODES[@]} )); then
    AURA_MODES_DETECTED=1
  else
    AURA_MODES_DETECTED=0
    AURA_MODES=(Static Breathe Pulse RainbowCycle RainbowWave)
  fi
}

# RainbowCycle -> rainbow-cycle
mode_to_subcommand() {
  sed -E 's/([a-z])([A-Z])/\1-\2/g' <<<"$1" | tr '[:upper:]' '[:lower:]'
}

# Find which flag (short or long) an effect's --help offers, e.g. "-c" or "--colour".
# find_flag "help text" short-flag long-regex
find_flag() {
  local help=$1 short=$2 long=$3 found
  if grep -qE -- "(^|[[:space:]])${short}," <<<"$help"; then echo "$short"; return 0; fi
  found=$(grep -oE -- "--${long}" <<<"$help" | head -n1)
  [[ -n $found ]] && { echo "$found"; return 0; }
  return 1
}

set_aura_effect() {
  local mode sub help flag
  local -a cmd

  get_aura_modes
  if (( ! AURA_MODES_DETECTED )); then
    warn "Couldn't read your keyboard's supported effects; showing common ones (some may fail)."
  fi
  pick_from "Choose an effect:" "${AURA_MODES[@]}" || return
  mode=$PICKED
  sub=$(mode_to_subcommand "$mode")

  # Newer asusctl: `aura effect <name>`; older: `aura <name>`.
  if asusctl aura effect "$sub" --help >/dev/null 2>&1; then
    cmd=(asusctl aura effect "$sub")
  elif asusctl aura "$sub" --help >/dev/null 2>&1; then
    cmd=(asusctl aura "$sub")
  else
    err "Your asusctl version doesn't recognize the '$sub' effect."
    info "Check 'asusctl aura --help' in the help menu for the effect names it uses."
    return 1
  fi
  help=$("${cmd[@]}" --help 2>&1)

  # Ask only for the options this effect actually takes.
  if flag=$(find_flag "$help" -c 'colou?r([[:space:]<=]|$)'); then
    pick_color "Color for $mode:" || return; cmd+=("$flag" "$COLOR")
  fi
  if flag=$(find_flag "$help" -C 'colou?r2'); then
    pick_color "Second color for $mode:" || return; cmd+=("$flag" "$COLOR")
  fi
  if flag=$(find_flag "$help" -s 'speed'); then
    pick_speed || return; cmd+=("$flag" "$PICKED")
  fi
  if flag=$(find_flag "$help" -d 'direction'); then
    pick_from "Direction:" "Right" "Left" "Up" "Down" || return
    cmd+=("$flag" "${PICKED,,}")
  fi

  if ! run_cmd "${cmd[@]}"; then
    info "If it says NotSupported, your keyboard can't do this effect even though it was listed."
  fi
}

menu_lighting() {
  while true; do
    header "Keyboard Lighting"
    echo "Brightness: $(quiet_out asusctl leds get)"; echo
    choose "Choose an action:" \
      "Show current brightness" \
      "Lighting off" \
      "Lighting on (restore last brightness: $LAST_LED_LEVEL)" \
      "Brightness: low" \
      "Brightness: medium" \
      "Brightness: high" \
      "Next brightness level" \
      "Next lighting effect" \
      "Previous lighting effect" \
      "Choose a lighting effect (only ones your keyboard supports)"
    case $CHOICE in
      0) return ;;
      1) run_show asusctl leds get ;;
      2) run_cmd asusctl leds set off ;;
      3) set_leds "$LAST_LED_LEVEL" ;;
      4) set_leds low ;;
      5) set_leds med ;;
      6) set_leds high ;;
      7) run_cmd asusctl leds next ;;
      8) run_alt "asusctl aura effect --next-mode" "asusctl aura --next-mode" ;;
      9) run_alt "asusctl aura effect --prev-mode" "asusctl aura --prev-mode" ;;
      10) set_aura_effect ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: fan curves
# ---------------------------------------------------------------------------
# 8 points each, as temperature:fan-percent
readonly CURVE_QUIET="30c:0%,45c:5%,55c:15%,65c:25%,70c:35%,75c:50%,85c:75%,95c:100%"
readonly CURVE_BALANCED="30c:5%,40c:10%,50c:20%,60c:30%,70c:45%,75c:60%,85c:80%,95c:100%"
readonly CURVE_AGGRESSIVE="30c:15%,40c:25%,50c:35%,60c:50%,65c:65%,70c:80%,80c:95%,90c:100%"

# Checks an 8-point curve: temps strictly rising, fan % never falling, all within range.
validate_curve() {
  local curve=$1 point t p prev_t=-1 prev_p=-1 count=0
  local -a points
  IFS=',' read -r -a points <<<"$curve"
  for point in "${points[@]}"; do
    if [[ ! $point =~ ^([0-9]{1,3})c?:([0-9]{1,3})%?$ ]]; then
      err "Bad point '$point'. Use the form 60c:30%"; return 1
    fi
    t=$((10#${BASH_REMATCH[1]})); p=$((10#${BASH_REMATCH[2]}))
    if (( t > 110 || p > 100 )); then err "Point '$point' is out of range (max 110c, 100%)."; return 1; fi
    if (( t <= prev_t )); then err "Temperatures must increase at each point."; return 1; fi
    if (( p < prev_p )); then err "Fan percentage must never decrease."; return 1; fi
    prev_t=$t; prev_p=$p; count=$((count + 1))
  done
  if (( count != 8 )); then err "A curve needs exactly 8 points (you gave $count)."; return 1; fi
  return 0
}

# apply_fan_curve "Label" "curve" [cpu|gpu|both]
apply_fan_curve() {
  local label=$1 curve=$2 fans=${3:-both} profile
  pick_profile "Apply the $label curve to which profile?" || return
  profile=$PICKED
  warn "Custom fan curves change how your laptop cools itself. Watch temperatures after applying."
  confirm "Apply the $label curve ($fans fan(s)) to the $profile profile?" || return

  if [[ $fans == cpu || $fans == both ]]; then
    run_cmd asusctl fan-curve --mod-profile "$profile" --fan cpu --data "$curve" || return
  fi
  if [[ $fans == gpu || $fans == both ]]; then
    run_cmd asusctl fan-curve --mod-profile "$profile" --fan gpu --data "$curve" || return
  fi
  run_cmd asusctl fan-curve --mod-profile "$profile" --enable-fan-curves true
}

custom_fan_curve() {
  local curve fans
  echo "Enter 8 points as temperature:fan%, separated by commas. Example:"
  echo "  $CURVE_BALANCED"
  echo
  while true; do
    read -rp "Curve (blank to cancel): " curve || return
    [[ -z $curve ]] && return
    curve=${curve// /}
    validate_curve "$curve" && break
  done
  pick_from "Which fan(s)?" "CPU fan" "GPU fan" "Both" || return
  case $CHOICE in 1) fans=cpu ;; 2) fans=gpu ;; 3) fans=both ;; esac
  apply_fan_curve "custom" "$curve" "$fans"
}

menu_fans() {
  while true; do
    header "Fan Curves"
    echo "Custom curves enabled for: $(quiet_out asusctl fan-curve --get-enabled)"; echo
    choose "Choose an action:" \
      "Show which profiles have custom curves enabled" \
      "View curves for a profile" \
      "Apply preset curve: Quiet" \
      "Apply preset curve: Balanced" \
      "Apply preset curve: Aggressive" \
      "Enter a custom curve" \
      "Enable custom curves for a profile" \
      "Disable custom curves for a profile (use firmware defaults)" \
      "Reset the active profile's curves to factory defaults"
    case $CHOICE in
      0) return ;;
      1) run_show asusctl fan-curve --get-enabled ;;
      2) pick_profile && run_show asusctl fan-curve --mod-profile "$PICKED" ;;
      3) apply_fan_curve "Quiet" "$CURVE_QUIET" ;;
      4) apply_fan_curve "Balanced" "$CURVE_BALANCED" ;;
      5) apply_fan_curve "Aggressive" "$CURVE_AGGRESSIVE" ;;
      6) custom_fan_curve ;;
      7) pick_profile && run_cmd asusctl fan-curve --mod-profile "$PICKED" --enable-fan-curves true ;;
      8) pick_profile && run_cmd asusctl fan-curve --mod-profile "$PICKED" --enable-fan-curves false ;;
      9)
        echo "Active profile: $(quiet_out asusctl profile get)"
        confirm "Reset this profile's fan curves to factory defaults?" && run_cmd asusctl fan-curve --default ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: GPU mode  (Armoury Crate style: Eco / Optimized / Performance)
#
#   Eco          dGPU powered off, iGPU only        dgpu_disable=1
#   Optimized    iGPU + dGPU (dGPU on demand)        dgpu_disable=0, gpu_mux_mode=1
#   Performance  dGPU only, iGPU bypassed via MUX    gpu_mux_mode=0 (reboot)
#
# Uses asus-armoury firmware attributes through asusctl (Linux 6.19+).
# ---------------------------------------------------------------------------
ARMOURY_DIR=${ROG_ARMOURY_DIR:-/sys/class/firmware-attributes/asus-armoury/attributes}
ARMOURY_LIST_CACHE=""
ARMOURY_LISTED=0
GPU_REBOOT_NEEDED=0

# attr_exists name -> true if the firmware exposes this attribute
attr_exists() {
  [[ -d $ARMOURY_DIR/$1 ]] && return 0
  if (( ! ARMOURY_LISTED )); then
    ARMOURY_LIST_CACHE=$(asusctl armoury list 2>/dev/null); ARMOURY_LISTED=1
  fi
  grep -qw -- "$1" <<<"$ARMOURY_LIST_CACHE"
}

# attr_read name [file] -> value from sysfs (current_value by default), or nothing
attr_read() {
  local f=$ARMOURY_DIR/$1/${2:-current_value}
  if [[ -r $f ]]; then tr -d '[:space:]' <"$f"; fi
}

onoff() { case $1 in 1) echo "ON" ;; 0) echo "OFF" ;; *) echo "unknown" ;; esac; }

# True if the firmware lets asusctl switch GPU modes.
gpu_available() { attr_exists dgpu_disable || attr_exists gpu_mux_mode; }

has_mux() { attr_exists gpu_mux_mode; }

gpu_current_mode() {
  local mux dis
  mux=$(attr_read gpu_mux_mode); dis=$(attr_read dgpu_disable)
  if [[ $mux == 0 ]]; then echo performance
  elif [[ $dis == 1 ]]; then echo eco
  elif [[ $dis == 0 ]]; then echo optimized
  else echo unknown
  fi
}

gpu_reboot_pending() {
  (( GPU_REBOOT_NEEDED )) && return 0
  [[ -r $ARMOURY_DIR/pending_reboot && $(tr -d '[:space:]' <"$ARMOURY_DIR/pending_reboot") == 1 ]]
}

gpu_label() {
  case $1 in eco) echo "Eco" ;; optimized) echo "Optimized" ;; performance) echo "Performance" ;; *) echo "Unknown" ;; esac
}

gpu_desc() {
  case $1 in
    eco)         echo "Eco          dGPU off, iGPU only (best battery life)" ;;
    optimized)   echo "Optimized    iGPU + dGPU, dGPU used when apps need it" ;;
    performance) echo "Performance  dGPU only, iGPU disabled via MUX (needs reboot)" ;;
  esac
}

# set_gpu_mode eco|optimized|performance
set_gpu_mode() {
  local target=$1 current needs_reboot=0
  current=$(gpu_current_mode)

  if ! gpu_available; then
    err "GPU control isn't available: the firmware doesn't expose dgpu_disable / gpu_mux_mode."
    return 1
  fi
  if [[ $target == "$current" ]]; then
    info "Already in $(gpu_label "$target") mode."; return 0
  fi
  if [[ $target == performance ]] && ! has_mux; then
    err "Performance mode needs a MUX switch, and none was detected on this laptop."
    return 1
  fi
  if [[ $current == performance && $target == eco ]]; then
    warn "Eco can't be reached directly from Performance mode, because the iGPU is disabled."
    info "Switch to Optimized now, reboot, then choose Eco."
    confirm "Switch to Optimized?" || return 1
    target=optimized
  fi
  [[ $target == performance || $current == performance ]] && needs_reboot=1

  echo
  echo "Switching from $(gpu_label "$current") to $(gpu_label "$target")."
  case $target in
    eco)
      warn "Close games and any apps using the dGPU first."
      info "You may need to log out and back in." ;;
    optimized)
      if (( needs_reboot )); then info "This takes effect after a reboot."
      else info "You may need to log out and back in."; fi ;;
    performance)
      warn "This takes effect after a reboot. Battery life will be noticeably shorter in this mode." ;;
  esac
  confirm "Continue?" || return 1

  case $target in
    eco)
      run_cmd asusctl armoury set dgpu_disable 1 || return 1 ;;
    optimized)
      if [[ $current == performance ]]; then
        run_cmd asusctl armoury set gpu_mux_mode 1 || return 1
      else
        run_cmd asusctl armoury set dgpu_disable 0 || return 1
      fi ;;
    performance)
      # The dGPU must be powered on before the MUX can route the display to it.
      if [[ $current == eco ]]; then run_cmd asusctl armoury set dgpu_disable 0 || return 1; fi
      run_cmd asusctl armoury set gpu_mux_mode 0 || return 1 ;;
  esac

  if (( needs_reboot )); then
    GPU_REBOOT_NEEDED=1
    warn "Reboot to finish switching to $(gpu_label "$target") mode."
    if confirm "Reboot now?"; then run_cmd systemctl reboot; fi
  fi
}

gpu_details() {
  local a v
  section "Firmware attributes"
  for a in dgpu_disable gpu_mux_mode egpu_enable; do
    v=$(attr_read "$a")
    printf '  %-14s %s\n' "$a" "${v:-not available}"
  done
}

menu_gpu() {
  local current m
  local -a modes labels
  while true; do
    header "GPU Mode"
    if ! gpu_available; then
      err "No GPU control was found."
      info "GPU switching needs Linux 6.19+ so asusctl can use asus-armoury firmware attributes."
      pause; return
    fi
    current=$(gpu_current_mode)
    echo "Current mode: ${C_BOLD}$(gpu_label "$current")${C_RESET}"
    if gpu_reboot_pending; then printf '%s\n' "${C_YELLOW}A reboot is pending to finish a GPU mode change.${C_RESET}"; fi

    modes=(eco optimized)
    if has_mux; then modes+=(performance)
    else echo "Performance mode isn't offered: no MUX switch detected on this laptop."; fi
    echo

    labels=()
    for m in "${modes[@]}"; do
      if [[ $m == "$current" ]]; then labels+=("$(gpu_desc "$m")   <- current")
      else labels+=("$(gpu_desc "$m")"); fi
    done
    labels+=("Show technical details")

    choose "Switch to:" "${labels[@]}"
    if (( CHOICE == 0 )); then return
    elif (( CHOICE <= ${#modes[@]} )); then set_gpu_mode "${modes[CHOICE-1]}"
    else gpu_details
    fi
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: AniMe Matrix (lid LED display on some GA402 configurations)
# ---------------------------------------------------------------------------
menu_anime() {
  while true; do
    header "AniMe Matrix Display"
    choose "Choose an action:" \
      "Turn display on" \
      "Turn display off" \
      "Set brightness" \
      "Enable built-in animations (boot/wake/shutdown)" \
      "Disable built-in animations" \
      "Clear the display"
    case $CHOICE in
      0) return ;;
      1) run_alt "asusctl anime --enable-display true" "asusctl anime -e true" ;;
      2) run_alt "asusctl anime --enable-display false" "asusctl anime -e false" ;;
      3)
        if pick_from "Brightness:" "Off" "Low" "Med" "High"; then
          run_alt "asusctl anime --brightness $PICKED" "asusctl anime -b $PICKED"
        fi ;;
      4) run_alt "asusctl anime --enable-builtins true" "asusctl anime -B true" ;;
      5) run_alt "asusctl anime --enable-builtins false" "asusctl anime -B false" ;;
      6) run_alt "asusctl anime --clear" "asusctl anime -c" ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: Slash LED bar (newer chassis; hidden automatically if unsupported)
# ---------------------------------------------------------------------------
menu_slash() {
  while true; do
    header "Slash LED Bar"
    choose "Choose an action:" \
      "Turn on" \
      "Turn off" \
      "Set brightness" \
      "List animation modes" \
      "Set animation mode"
    case $CHOICE in
      0) return ;;
      1) run_alt "asusctl slash --enable" "asusctl slash -e true" ;;
      2) run_alt "asusctl slash --disable" "asusctl slash -e false" ;;
      3) read_int "Brightness" 0 255 && run_alt "asusctl slash --brightness $REPLY_VAL" "asusctl slash -l $REPLY_VAL" ;;
      4) run_alt "asusctl slash --list" "asusctl slash --help" ;;
      5)
        local mode
        read -rp "Mode name (from the list option; blank to cancel): " mode || mode=""
        if [[ $mode =~ ^[A-Za-z0-9_-]+$ ]]; then
          run_alt "asusctl slash --mode $mode" "asusctl slash -m $mode"
        elif [[ -n $mode ]]; then
          err "Mode names contain only letters, numbers, - and _."
        fi ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Menu: firmware settings (asus-armoury, needs Linux 6.19+)
# ---------------------------------------------------------------------------
TOGGLE_ATTRS=(panel_overdrive boot_sound mcu_powersave)
GPU_ATTRS=" dgpu_disable gpu_mux_mode egpu_enable "

attr_friendly() {
  case $1 in
    panel_overdrive)   echo "Panel overdrive (faster pixel response)" ;;
    boot_sound)        echo "Boot sound" ;;
    mcu_powersave)     echo "MCU power saving (less battery drain when off)" ;;
    ppt_pl1_spl)       echo "CPU sustained power limit (SPL)" ;;
    ppt_pl2_sppt)      echo "CPU short boost power limit (sPPT)" ;;
    ppt_pl3_fppt)      echo "CPU fast boost power limit (fPPT)" ;;
    ppt_apu_sppt)      echo "APU boost power limit" ;;
    ppt_platform_sppt) echo "Platform boost power limit" ;;
    nv_dynamic_boost)  echo "NVIDIA Dynamic Boost" ;;
    nv_temp_target)    echo "NVIDIA temperature target" ;;
    dgpu_tgp)          echo "dGPU power limit (TGP)" ;;
    *)                 echo "$1" ;;
  esac
}

toggle_attr() {
  local name=$1 cur new
  cur=$(attr_read "$name")
  case $cur in
    1) new=0 ;;
    0) new=1 ;;
    *)
      pick_from "$(attr_friendly "$name"): current value unknown. Set it to:" "On" "Off" || return
      if (( CHOICE == 1 )); then new=1; else new=0; fi ;;
  esac
  echo "$(attr_friendly "$name"): $(onoff "$cur") -> $(onoff "$new")"
  run_cmd asusctl armoury set "$name" "$new"
  if [[ $name == boot_sound || $name == mcu_powersave ]]; then
    info "This setting takes effect on the next boot."
  fi
}

# Numeric settings with a min/max range (power limits, temperature targets).
menu_limits() {
  local d name cur min max
  local -a names labels
  while true; do
    header "Power & Thermal Limits"
    names=(); labels=()
    if [[ -d $ARMOURY_DIR ]]; then
      for d in "$ARMOURY_DIR"/*/; do
        name=$(basename "$d")
        [[ $GPU_ATTRS == *" $name "* ]] && continue
        min=$(attr_read "$name" min_value); max=$(attr_read "$name" max_value)
        [[ $min =~ ^-?[0-9]+$ && $max =~ ^-?[0-9]+$ ]] || continue
        (( max > 1 )) || continue
        cur=$(attr_read "$name")
        names+=("$name")
        labels+=("$(attr_friendly "$name"): ${cur:-?}   (range $min-$max)")
      done
    fi
    if (( ${#names[@]} == 0 )); then
      warn "No adjustable limits were found in $ARMOURY_DIR."
      info "These need Linux 6.19+ and a laptop that exposes them. 'Set any attribute' may still work."
      pause; return
    fi
    info "Power limits are in watts. Higher values mean more performance, heat and fan noise."
    info "Changes usually reset when you switch performance profile."; echo
    choose "Pick a setting to change:" "${labels[@]}"
    (( CHOICE == 0 )) && return
    name=${names[CHOICE-1]}
    min=$(attr_read "$name" min_value); max=$(attr_read "$name" max_value)
    if read_int "New value for $(attr_friendly "$name")" "$min" "$max"; then
      confirm "Set $(attr_friendly "$name") to $REPLY_VAL?" && run_cmd asusctl armoury set "$name" "$REPLY_VAL"
    fi
    pause
  done
}

read_attr_name() {
  local name
  read -rp "Attribute name (blank to cancel): " name || return 1
  [[ -z $name ]] && return 1
  if [[ ! $name =~ ^[A-Za-z0-9_]+$ ]]; then err "Attribute names contain only letters, numbers and _."; return 1; fi
  PICKED=$name
}

set_any_attr() {
  local name value min max
  read_attr_name || return
  name=$PICKED
  run_show asusctl armoury get "$name"
  min=$(attr_read "$name" min_value); max=$(attr_read "$name" max_value)
  [[ -n $min && -n $max ]] && echo "Allowed range: $min-$max"
  read -rp "New value (blank to cancel): " value || return
  [[ -z $value ]] && return
  if [[ ! $value =~ ^-?[0-9A-Za-z_]+$ ]]; then err "That value doesn't look valid."; return; fi
  warn "Wrong values (especially power limits) can cause instability or overheating."
  confirm "Set $name to $value?" && run_cmd asusctl armoury set "$name" "$value"
}

menu_armoury() {
  local a
  local -a labels actions act
  while true; do
    header "Firmware Settings"
    labels=(); actions=()
    if gpu_available; then
      labels+=("GPU mode: $(gpu_label "$(gpu_current_mode)")   (Eco / Optimized / Performance)")
      actions+=("menu_gpu")
    fi
    for a in "${TOGGLE_ATTRS[@]}"; do
      attr_exists "$a" || continue
      labels+=("$(attr_friendly "$a"): $(onoff "$(attr_read "$a")")   (select to toggle)")
      actions+=("toggle_attr $a")
    done
    labels+=("Power & thermal limits");      actions+=("menu_limits")
    labels+=("List all firmware attributes"); actions+=("run_show asusctl armoury list")
    labels+=("Set any attribute (expert)");   actions+=("set_any_attr")

    choose "Choose a setting:" "${labels[@]}"
    (( CHOICE == 0 )) && return
    read -r -a act <<<"${actions[CHOICE-1]}"
    "${act[@]}"
    [[ ${act[0]} == menu_* ]] || pause
  done
}

# ---------------------------------------------------------------------------
# Menu: command help / reference
# ---------------------------------------------------------------------------
show_paged() {
  if command -v less >/dev/null 2>&1 && [[ -t 1 ]]; then "$@" 2>&1 | less -R; else "$@" 2>&1; fi
}

menu_help() {
  local -a subs=(profile battery leds aura fan-curve anime slash armoury info)
  while true; do
    header "Command Help / Reference"
    info "Use this to check syntax if a menu option fails on your asusctl version."; echo
    choose "Show help for:" \
      "asusctl (overview)" \
      "${subs[@]/#/asusctl }" \
      "Supported features on this laptop"
    case $CHOICE in
      0) return ;;
      1) show_paged asusctl --help ;;
      $(( ${#subs[@]} + 2 ))) show_paged asusctl info --show-supported ;;
      *) show_paged asusctl "${subs[CHOICE-2]}" --help ;;
    esac
    [[ -t 1 ]] && command -v less >/dev/null 2>&1 || pause
  done
}

# ---------------------------------------------------------------------------
# Menu: setup / install (CachyOS and other Arch-based distros, using pacman)
# ---------------------------------------------------------------------------
# Package          What it's for
#   asusctl                Core tool + asusd daemon (required)
#   power-profiles-daemon  Lets asusctl switch performance profiles
#
# supergfxctl is deprecated in favor of asusctl and isn't used. If it's still
# installed, its daemon can fight asusctl over the GPU, so it's flagged as a conflict.
#   rog-control-center     Optional graphical app for the same settings

SUDO=()
(( EUID == 0 )) || SUDO=(sudo)

pkg_installed() { pacman -Q "$1" >/dev/null 2>&1; }
pkg_version()   { pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }

svc_state() { # svc_state name [--user]
  local -a sc=(systemctl)
  [[ $2 == --user ]] && sc+=(--user)
  if "${sc[@]}" is-active --quiet "$1" 2>/dev/null; then echo "running"
  elif "${sc[@]}" cat "$1" >/dev/null 2>&1; then echo "stopped"
  else echo "not installed"
  fi
}

# Re-read everything after installing, so menus appear without restarting.
refresh_state() {
  ARMOURY_LISTED=0; ARMOURY_LIST_CACHE=""
  check_version
  detect_capabilities
}

pkg_available() { pacman -Si "$1" >/dev/null 2>&1; }

# install_pkgs pkg... -> 0 ok, 1 install failed, 2 a package isn't in the repos
install_pkgs() {
  local p
  local -a missing=() unavailable=()
  for p in "$@"; do
    pkg_installed "$p" && continue
    if pkg_available "$p"; then missing+=("$p"); else unavailable+=("$p"); fi
  done
  if (( ${#unavailable[@]} )); then
    err "Not found in your package repos: ${unavailable[*]}"
    info "If you haven't updated in a while, run a full system update (setup option 6) and try again."
    return 2
  fi
  if (( ${#missing[@]} == 0 )); then info "Already installed: $*"; return 0; fi
  run_cmd "${SUDO[@]}" pacman -S --needed "${missing[@]}" && return 0
  err "Install failed; see pacman's message above."
  return 1
}

kernel_check() {
  local k lowest
  k=$(uname -r | grep -oE '^[0-9]+\.[0-9]+')
  lowest=$(printf '%s\n%s\n' "6.19" "$k" | sort -V | head -n1)
  if [[ $lowest == "6.19" ]]; then echo "$(uname -r)  (OK for firmware settings)"
  else echo "$(uname -r)  (firmware settings like power limits need 6.19+)"
  fi
}

setup_status() {
  local p v
  section "Packages"
  for p in asusctl power-profiles-daemon rog-control-center; do
    if v=$(pkg_version "$p") && [[ -n $v ]]; then
      printf '  %-24s %s\n' "$p" "${C_GREEN}installed ($v)${C_RESET}"
    elif [[ $p == rog-control-center ]]; then
      printf '  %-24s %s\n' "$p" "not installed (optional)"
    else
      printf '  %-24s %s\n' "$p" "${C_YELLOW}not installed${C_RESET}"
    fi
  done
  section "Services"
  printf '  %-24s %s\n' "asusd"                 "$(svc_state asusd)"
  printf '  %-24s %s\n' "power-profiles-daemon" "$(svc_state power-profiles-daemon)"
  pkg_installed tuned-ppd && printf '  %-24s %s\n' "tuned-ppd" "$(svc_state tuned-ppd)"
  printf '  %-24s %s\n' "asusd-user (user)"     "$(svc_state asusd-user --user)"
  section "Kernel"
  echo "  $(kernel_check)"
  section "GPU mode switching"
  if gpu_available; then echo "  Available through asusctl firmware settings."
  else echo "  Not available (needs Linux 6.19+ and firmware support)."; fi
  section "Possible conflicts"
  local found=0
  for p in tlp auto-cpufreq; do
    if pkg_installed "$p"; then echo "  $p is installed and can conflict with power-profiles-daemon."; found=1; fi
  done
  for p in supergfxctl optimus-manager envycontrol; do
    if pkg_installed "$p"; then
      echo "  $p is installed and can interfere with GPU mode switching."
      echo "    Remove it with: sudo pacman -Rns $p"
      found=1
    fi
  done
  (( found )) || echo "  None found."
}

setup_asusctl() {
  install_pkgs asusctl || return 1
  if [[ $(svc_state asusd) != running ]]; then
    run_cmd "${SUDO[@]}" systemctl start asusd
  fi
}

setup_ppd() {
  local p
  if pkg_installed tuned-ppd; then
    info "tuned-ppd is installed and already provides profile switching, so power-profiles-daemon isn't needed."
    [[ $(svc_state tuned-ppd) == running ]] || run_cmd "${SUDO[@]}" systemctl enable --now tuned-ppd
    return 0
  fi
  for p in tlp auto-cpufreq; do
    if pkg_installed "$p"; then
      warn "$p is installed. Running it alongside power-profiles-daemon causes conflicts."
      confirm "Continue anyway? (You'd want to disable $p afterwards.)" || return 1
    fi
  done
  install_pkgs power-profiles-daemon || return 1
  [[ $(svc_state power-profiles-daemon) == running ]] || run_cmd "${SUDO[@]}" systemctl enable --now power-profiles-daemon
}

setup_gui() {
  install_pkgs rog-control-center
}

setup_user_daemon() {
  if ! pkg_installed asusctl; then err "Install asusctl first."; return 1; fi
  info "asusd-user runs custom keyboard lighting and AniMe animations for your user account."
  run_cmd systemctl --user enable --now asusd-user
}

setup_everything() {
  echo "This will install and enable:"
  echo "  • asusctl (and start asusd)"
  echo "  • power-profiles-daemon (unless tuned-ppd already handles profiles)"
  echo "rog-control-center (the graphical app) is optional; add it from this menu if you want it."
  echo
  confirm "Continue?" || return
  local rc=0
  setup_asusctl && setup_ppd || rc=1
  refresh_state
  if (( rc == 0 )); then
    ok "Setup finished."
    if ! gpu_available; then
      info "GPU mode switching isn't available yet; it needs Linux 6.19+ and firmware support."
    fi
  else
    err "Setup stopped early; see the messages above."
  fi
}

menu_setup() {
  if ! command -v pacman >/dev/null 2>&1; then
    header "Setup"
    err "pacman wasn't found. This setup menu supports CachyOS and other Arch-based distros."
    pause; return
  fi
  while true; do
    header "Setup / Install Tools"
    setup_status
    echo
    choose "Choose an action:" \
      "Install everything recommended (asusctl, power-profiles-daemon)" \
      "Install asusctl only" \
      "Install power-profiles-daemon (profile switching)" \
      "Install rog-control-center (optional graphical app)" \
      "Enable asusd-user (custom lighting / AniMe animations)" \
      "Full system update (sudo pacman -Syu)"
    case $CHOICE in
      0) return ;;
      1) setup_everything ;;
      2) setup_asusctl; refresh_state ;;
      3) setup_ppd ;;
      4) setup_gui ;;
      5) setup_user_daemon ;;
      6)
        info "Arch-based systems should be updated as a whole, not package-by-package."
        confirm "Run a full system update now?" && run_cmd "${SUDO[@]}" pacman -Syu ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
  local -a labels funcs
  while true; do
    labels=("Status overview" "Quick presets" "Performance profiles" "Battery charging" "Keyboard lighting")
    funcs=(show_status menu_presets menu_profiles menu_battery menu_lighting)
    if has_feature 'fan.?curve';         then labels+=("Fan curves");                   funcs+=(menu_fans); fi
    if gpu_available || (( SHOW_ALL )); then
      labels+=("GPU mode: $(gpu_label "$(gpu_current_mode)")  (Eco / Optimized / Performance)"); funcs+=(menu_gpu)
    fi
    if has_feature 'anime';              then labels+=("AniMe Matrix display");         funcs+=(menu_anime); fi
    if has_feature 'slash';              then labels+=("Slash LED bar");                funcs+=(menu_slash); fi
    if has_feature 'armoury|firmware' || [[ -d $ARMOURY_DIR ]]; then labels+=("Firmware settings"); funcs+=(menu_armoury); fi
    labels+=("Setup / install tools");    funcs+=(menu_setup)
    labels+=("Command help / reference"); funcs+=(menu_help)

    header "ROG Control Menu  (asusctl $ASUSCTL_VERSION)$( (( DRY_RUN )) && echo '  [DRY RUN]')"
    BACK_LABEL="Exit" choose "Main menu:" "${labels[@]}"
    if (( CHOICE == 0 )); then echo "Bye!"; exit 0; fi
    "${funcs[CHOICE-1]}"
  done
}

usage() {
  cat <<EOF
Usage: ${0##*/} [--all] [--dry-run] [--setup] [--help]

A numbered-menu front end for asusctl.

  -a, --all       show every menu, even ones your laptop doesn't report support for
  -n, --dry-run   print commands that change settings instead of running them
  -s, --setup     open the setup / install menu first
  -h, --help      show this help
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case $arg in
      -a|--all)     SHOW_ALL=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      -s|--setup)   START_SETUP=1 ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage; exit 1 ;;
    esac
  done

  trap 'echo; echo "Bye!"; exit 130' INT

  if (( START_SETUP )); then menu_setup; fi
  check_dependencies
  check_version
  detect_capabilities
  (( DRY_RUN )) && warn "Dry-run mode: commands that change settings will be printed, not run."
  (( WARN_COUNT )) && pause
  main_menu
}

main "$@"
