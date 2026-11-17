#!/usr/bin/env bash
#
# system_inventory.sh — collect hardware/system diagnostic info into a report bundle
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly REQUIRED_TOOLS=("lsblk")
# tool -> apt package, used for the "how to install" hint
declare -A OPTIONAL_TOOLS=(
    [inxi]="inxi"
    [lshw]="lshw"
    [lscpu]="util-linux"
    [cpuid]="cpuid"
    [dmidecode]="dmidecode"
    [decode-dimms]="i2c-tools"
    [smartctl]="smartmontools"
    [upower]="upower"
)

readonly OUTPUT_ROOT="${OUTPUT_ROOT:-./system_inventory}"
OUTPUT_DIR=""
MODEL=""
DISKS=()
declare -A AVAILABLE_TOOLS=()   # set of available optional tools, populated by check_optional_tools

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()  { printf '[i] %s\n' "$*"; }
log_ok()    { printf '[+] %s\n' "$*"; }
log_warn()  { printf '[!] %s\n' "$*" >&2; }
log_error() { printf '[x] %s\n' "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (sudo)."
    fi
}

check_required_tools() {
    local tool missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    if (( ${#missing[@]} > 0 )); then
        die "Missing required tools: ${missing[*]}."
    fi
}

# Populates the AVAILABLE_TOOLS set with optional tools that are actually
# installed, and warns (once) about the ones that are missing.
# NOTE: deliberately a set (assoc. array), not a space-joined string —
# ${array[*]} joins on IFS, and this script sets IFS=$'\n\t', so a
# space-based "contains" check would silently never match.
check_optional_tools() {
    local tool pkg missing=()

    for tool in "${!OPTIONAL_TOOLS[@]}"; do
        if command -v "$tool" &>/dev/null; then
            AVAILABLE_TOOLS[$tool]=1
        else
            pkg="${OPTIONAL_TOOLS[$tool]}"
            missing+=("$tool (sudo apt install $pkg)")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_warn "Optional tools not found, related sections will be skipped:"
        printf '      %s\n' "${missing[@]}"
    fi
}

tool_available() {
    local tool="$1"
    [[ -n "${AVAILABLE_TOOLS[$tool]:-}" ]]
}

# ---------------------------------------------------------------------------
# System model detection
# ---------------------------------------------------------------------------
detect_system_model() {
    local model=""

    # `|| true` on both lookups below: an empty/failed match here (no
    # "Product:" line, dmidecode unreadable, etc.) is a normal outcome,
    # not a script error — without it, `set -o pipefail` would abort
    # the whole run just because grep found nothing.
    if tool_available inxi; then
        model=$(inxi -F 2>/dev/null | grep -i 'Product:' | head -n1 \
                | sed -E 's/.*Product:[[:space:]]*//; s/[[:space:]]+$//') || true
    fi

    if [[ -z "$model" ]] && command -v dmidecode &>/dev/null; then
        model=$(dmidecode -s system-product-name 2>/dev/null | head -n1) || true
    fi

    [[ -z "$model" ]] && model="UNKNOWN_MODEL"

    # sanitize: keep alnum/dot/dash/underscore, collapse everything else to "_"
    model=$(printf '%s' "$model" | tr -c '[:alnum:].-' '_' | sed 's/_\+/_/g; s/^_//; s/_$//')

    MODEL="${model:-UNKNOWN_MODEL}"
}

# ---------------------------------------------------------------------------
# Disk discovery (reused approach from drive_diag.sh)
# ---------------------------------------------------------------------------
discover_disks() {
    mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2=="disk" && $1!~/loop/ && $1!~/ram/ {print $1}')

    if (( ${#DISKS[@]} == 0 )); then
        log_warn "No physical drives found, smartctl section will be empty."
    fi
}

# ---------------------------------------------------------------------------
# Collection helpers
# ---------------------------------------------------------------------------
# run_collect <tool_to_check> <output_filename> <command...>
run_collect() {
    local tool="$1" outfile="$2"
    shift 2

    if ! tool_available "$tool"; then
        return
    fi

    log_info "Collecting: $outfile"
    if ! "$@" > "${OUTPUT_DIR}/${outfile}" 2>&1; then
        log_warn "'$tool' exited with a non-zero status, see ${outfile}"
    fi
}

collect_lsblk_summary() {
    log_info "Collecting: lsblk_summary.txt"
    lsblk -dpno NAME,MODEL,SIZE,TRAN > "${OUTPUT_DIR}/lsblk_summary.txt"
}

collect_lshw()         { run_collect lshw          "lshw.txt"          lshw;         }
collect_lscpu()        { run_collect lscpu         "lscpu.txt"         lscpu;        }
collect_cpuid()        { run_collect cpuid         "cpuid.txt"         cpuid;        }
collect_dmidecode()    { run_collect dmidecode     "dmidecode.txt"     dmidecode;    }
collect_decode_dimms() { run_collect decode-dimms  "decode-dimms.txt"  decode-dimms; }
collect_inxi()         { run_collect inxi          "inxi.txt"          inxi -Fxxxz;  }

collect_smartctl() {
    if ! tool_available smartctl; then
        return
    fi

    local disk name
    for disk in "${DISKS[@]}"; do
        name="$(basename "$disk")"
        log_info "Collecting: smartctl.${name}.txt"
        if ! smartctl -xa "$disk" > "${OUTPUT_DIR}/smartctl.${name}.txt" 2>&1; then
            log_warn "smartctl exited with a non-zero status for $disk (this is often normal — check the file)"
        fi
    done
}

collect_upower() {
    if ! tool_available upower; then
        return
    fi

    local battery
    battery=$(upower -e 2>/dev/null | grep -i BAT || true)

    if [[ -z "$battery" ]]; then
        log_info "No battery device found, skipping upower section."
        return
    fi

    log_info "Collecting: upower.txt"
    upower -i "$battery" > "${OUTPUT_DIR}/upower.txt" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Output handling
# ---------------------------------------------------------------------------
init_output_dir() {
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M")
    OUTPUT_DIR="${OUTPUT_ROOT}/${MODEL}_${timestamp}"
    mkdir -p "$OUTPUT_DIR"
    log_ok "Output directory: $OUTPUT_DIR"
}

archive_results() {
    local archive="${OUTPUT_DIR}.tar.gz"
    tar -czf "$archive" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"
    log_ok "Archive created: $archive"
}

# ---------------------------------------------------------------------------
# Glue
# ---------------------------------------------------------------------------
print_header() {
    echo "=========================================="
    echo "         SYSTEM HARDWARE INVENTORY         "
    echo "=========================================="
}

print_footer() {
    echo ""
    echo "=========================================="
    echo "[SUCCESS] Inventory collection finished."
    echo "Results saved to: $OUTPUT_DIR"
    echo "=========================================="
}

on_exit() {
    local code=$?
    if (( code != 0 )); then
        log_error "Script exited with an error (code $code)."
    fi
}

main() {
    trap on_exit EXIT

    check_root
    check_required_tools

    print_header

    check_optional_tools
    detect_system_model
    log_ok "Detected system model: $MODEL"

    discover_disks
    init_output_dir

    collect_lsblk_summary
    collect_lshw
    collect_lscpu
    collect_cpuid
    collect_dmidecode
    collect_decode_dimms
    collect_inxi
    collect_smartctl
    collect_upower

    archive_results
    print_footer
}

main "$@"

## sudo nvme id-ctrl /dev/nvme0n1 -H | grep -i "Format \| Crypto"
## sudo nvme format /dev/nvme0n1 --ses=1
## sudo head -c 1M /dev/nvme0n1 | hexdump -C
## sudo fdisk -l /dev/nvme0n1
## sudo partprobe /dev/nvme0n1
## lsblk


