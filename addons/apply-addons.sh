
#!/usr/bin/env bash
#
# Apply the Droidspaces and USB Arsenal add-ons to this kernel tree.
#
# The kernel branch is kept clean: patches are applied to the working tree and
# selected config fragments are merged into the generated .config at build time.
#
# Modes:
#   prepare   apply selected patches, generate defconfig, merge selected fragments
#   patches   apply selected patches only
#   config    merge selected fragments into --config <file>
#
# Environment:
#   DEFCONFIG_CHOICE  droidspace | usbarsenal | both
#   PATCH_CHOICE      droidspace | usbarsenal | both
#   ADDONS_CACHE_DIR  download cache
#   USB_ARSENAL_DIR   local USB-Arsenal checkout
#   DROIDSPACES_PATCH_DIR local Droidspaces patch directory
#   USB_ARSENAL_REF   override USB Arsenal commit
#   DROIDSPACES_REF   override Droidspaces commit
#

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/addons.env" ]; then
	. "$SCRIPT_DIR/addons.env"
fi

ARCH="${ARCH:-arm64}"
OUT="${OUT:-out}"
DEFCONFIG="${DEFCONFIG:-arch/arm64/configs/vendor/xiaomi/miatoll_defconfig}"
DEFCONFIG_CHOICE="${DEFCONFIG_CHOICE:-both}"
PATCH_CHOICE="${PATCH_CHOICE:-both}"
CACHE_DIR="${ADDONS_CACHE_DIR:-$SCRIPT_DIR/.cache}"
MODE="prepare"
CONFIG_FILE=""

usage() {
	cat <<'EOF'
Usage: apply-addons.sh <mode> [options]

Modes:
  prepare                 apply selected patches + defconfig + config fragments
  patches                 apply selected patches only
  config [--config FILE]  merge selected fragments into FILE

Options:
  --defconfig PATH        defconfig to generate
  --out DIR               kernel output directory
  --config FILE           existing .config to merge into (implies config mode)
  -h, --help              show this help

Environment:
  DEFCONFIG_CHOICE        droidspace | usbarsenal | both
  PATCH_CHOICE            droidspace | usbarsenal | both
  ADDONS_CACHE_DIR        download cache (default: addons/.cache)
  USB_ARSENAL_DIR         local USB-Arsenal checkout
  DROIDSPACES_PATCH_DIR   local Droidspaces patch directory
  USB_ARSENAL_REF         override USB Arsenal commit
  DROIDSPACES_REF         override Droidspaces commit
EOF
}

msg()  { printf '[addons] %s\n' "$*" >&2; }
warn() { printf '[addons] WARNING: %s\n' "$*" >&2; }
die()  { printf '[addons] ERROR: %s\n' "$*" >&2; exit 1; }

validate_choice() {
	local name="$1"
	local value="$2"

	case "$value" in
		droidspace|usbarsenal|both) ;;
		*)
			die "invalid $name: $value (expected droidspace, usbarsenal, or both)"
			;;
	esac
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		prepare|patches|config)
			MODE="$1"
			shift
			;;
		--defconfig)
			[ "$#" -ge 2 ] || die "--defconfig needs a path"
			DEFCONFIG="$2"
			shift 2
			;;
		--out)
			[ "$#" -ge 2 ] || die "--out needs a directory"
			OUT="$2"
			shift 2
			;;
		--config)
			[ "$#" -ge 2 ] || die "--config needs a file"
			CONFIG_FILE="$2"
			MODE="config"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1 (try --help)"
			;;
	esac
done

validate_choice DEFCONFIG_CHOICE "$DEFCONFIG_CHOICE"
validate_choice PATCH_CHOICE "$PATCH_CHOICE"

mkdir -p "$CACHE_DIR"

msg "mode: $MODE"
msg "defconfig selection: $DEFCONFIG_CHOICE"
msg "patch selection: $PATCH_CHOICE"

detect_kernel_version() {
	local version patchlevel
	version=$(awk '/^VERSION[[:space:]]*=/{print $3; exit}' Makefile)
	patchlevel=$(awk '/^PATCHLEVEL[[:space:]]*=/{print $3; exit}' Makefile)
	[ -n "$version" ] && [ -n "$patchlevel" ] ||
		die "cannot read VERSION/PATCHLEVEL from Makefile"
	printf '%s.%s\n' "$version" "$patchlevel"
}

is_git_tree() {
	git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

sentinel_present() {
	local file="$1" pattern="$2"
	[ -f "$file" ] && grep -Eq -- "$pattern" "$file"
}

# one_patch <glob> - print exactly one matching file
one_patch() {
	local pattern="$1"
	local -a files=()
	local f

	while IFS= read -r f; do
		[ -n "$f" ] && files+=("$f")
	done < <(compgen -G "$pattern" || true)

	[ "${#files[@]}" -eq 1 ] ||
		die "expected exactly one patch matching: $pattern (found ${#files[@]})"

	printf '%s\n' "${files[0]}"
}

# apply_one <patch> [sentinel-file sentinel-regex]
# Skips when the sentinel proves the change is already in the tree.
apply_one() {
	local patch="$1"
	local sentinel_file="${2:-}"
	local sentinel_pattern="${3:-}"
	local label err

	label=$(basename -- "$patch")

	if [ -n "$sentinel_file" ] &&
		sentinel_present "$sentinel_file" "$sentinel_pattern"; then
		msg "already applied: $label"
		return 0
	fi

	if is_git_tree; then
		if err=$(git apply --check --whitespace=nowarn "$patch" 2>&1); then
			git apply --whitespace=nowarn "$patch"
			msg "applied: $label"
		else
			die "cannot apply $label:
$err"
		fi
	else
		patch -p1 --forward --batch --silent < "$patch" ||
			die "cannot apply $label"
		msg "applied: $label (patch -p1)"
	fi
}

fetch_tarball() {
	local repo="$1" ref="$2" name="$3"
	local dest="$CACHE_DIR/${name}-${ref}"
	local url tmp

	if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
		printf '%s\n' "$dest"
		return 0
	fi

	url="${repo%.git}/archive/${ref}.tar.gz"
	tmp=$(mktemp -d)
	msg "downloading ${repo} @ ${ref}"

	if ! curl -fsSL --retry 3 --retry-delay 2 \
		-o "$tmp/src.tar.gz" "$url"; then
		rm -rf "$tmp"
		die "download failed: $url"
	fi

	mkdir -p "$dest"
	if ! tar -xzf "$tmp/src.tar.gz" -C "$dest" --strip-components=1; then
		rm -rf "$tmp" "$dest"
		die "extract failed: $url"
	fi

	rm -rf "$tmp"
	printf '%s\n' "$dest"
}

fetch_url() {
	local url="$1" dest="$2" tmp="$2.part"

	if [ -s "$dest" ]; then
		return 0
	fi

	mkdir -p "$(dirname -- "$dest")"
	msg "downloading $(basename -- "$dest")"

	if ! curl -fsSL --retry 3 --retry-delay 2 \
		-o "$tmp" "$url"; then
		rm -f "$tmp"
		die "download failed: $url"
	fi

	mv -f "$tmp" "$dest"
}

apply_usb_arsenal() {
	local kver src dir p n

	kver=$(detect_kernel_version)
	msg "USB Arsenal: kernel version $kver"

	if [ -n "${USB_ARSENAL_DIR:-}" ] &&
		[ -d "$USB_ARSENAL_DIR/kernel-patches" ]; then
		src="$USB_ARSENAL_DIR"
	elif [ -d "$ROOT/external/USB-Arsenal/kernel-patches" ]; then
		src="$ROOT/external/USB-Arsenal"
	else
		src=$(fetch_tarball \
			"${USB_ARSENAL_REPO}" \
			"${USB_ARSENAL_REF}" \
			"USB-Arsenal")
	fi

	dir="$src/kernel-patches/$kver"
	[ -d "$dir" ] ||
		die "USB Arsenal has no kernel-patches/$kver directory"

	case "$kver" in
		4.14)
			# 0001 is already provided by this tree's CAF multi-gadget support.
			# 0002 needs Samsung CONFIG_USB_OLD_CONFIGFS/linked_func (absent).
			# 0003 needs Samsung NCM extras (absent); the generic RX fix is
			# already in this tree's ncm_unwrap_ntb().
			p=$(one_patch "$dir/0004-*.patch")
			apply_one "$p" \
				drivers/usb/gadget/function/f_mass_storage.c 'SFF-8020i'

			p=$(one_patch "$dir/0005-*.patch")
			apply_one "$p" \
				drivers/usb/gadget/function/f_mass_storage.c 'Multi-session info'

			p=$(one_patch "$dir/0006-*.patch")
			apply_one "$p" \
				drivers/usb/gadget/function/storage_common.h 'cd_as_dvd'

			p=$(one_patch "$dir/0007-*.patch")
			apply_one "$p" \
				drivers/usb/gadget/function/f_hid.c 'F_HID_OPT\(interval'

			# 0008-0012 are one f_hid lifetime/rebind series.
			if sentinel_present \
				drivers/usb/gadget/function/f_hid.c \
				'hidg->cdev = cdev_alloc\(\)'; then
				msg "already applied: f_hid lifetime series (0008-0012)"
			else
				for n in 0008 0009 0010 0011 0012; do
					p=$(one_patch "$dir/$n-*.patch")
					apply_one "$p"
				done
			fi
			;;
		*)
			die "no curated USB Arsenal patch list for $kver; update addons/apply-addons.sh"
			;;
	esac
}

apply_droidspaces() {
	local dir p01 p02 repo_path raw

	if [ -n "${DROIDSPACES_PATCH_DIR:-}" ]; then
		p01=$(one_patch "$DROIDSPACES_PATCH_DIR/01*.patch")
		p02=$(one_patch "$DROIDSPACES_PATCH_DIR/02*.patch")
	else
		dir="$CACHE_DIR/droidspaces-${DROIDSPACES_REF}"
		mkdir -p "$dir"

		repo_path="${DROIDSPACES_REPO#https://github.com/}"
		repo_path="${repo_path%.git}"
		raw="https://raw.githubusercontent.com/${repo_path}/${DROIDSPACES_REF}/Documentation/resources/kernel-patches/non-GKI"

		p01="$dir/01-fix_kernel_panic_in_xt_qtaguid.patch"
		p02="$dir/02-fix_restore_cgroup_file_prefix_handling.patch"

		fetch_url \
			"$raw/01.fix_kernel_panic_in_xt_qtaguid.patch" "$p01"
		fetch_url \
			"$raw/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch" "$p02"
	fi

	# This tree does not carry xt_qtaguid.
	if [ -e net/netfilter/xt_qtaguid.c ]; then
		apply_one "$p01"
	else
		msg "skipping Droidspaces 01: net/netfilter/xt_qtaguid.c is not in this tree"
	fi

	apply_one "$p02" \
		kernel/cgroup/cgroup.c \
		'kernfs_create_link\(cgrp->kn, name, kn\)'
}

apply_patches() {
	case "$PATCH_CHOICE" in
		droidspace)
			msg "applying Droidspaces patches only"
			apply_droidspaces
			;;
		usbarsenal)
			msg "applying USB Arsenal patches only"
			apply_usb_arsenal
			;;
		both)
			msg "applying USB Arsenal and Droidspaces patches"
			apply_usb_arsenal
			apply_droidspaces
			;;
	esac
}


verify_config() {
    local cfg="$1"
    local fragment symbol expected
    local -a fragments=()
    local -A required_configs=()

    case "${DEFCONFIG_CHOICE:-both}" in
        droidspace)
            fragments+=("$ROOT/addons/config/droidspace.config")
            ;;
        usbarsenal)
            fragments+=("$ROOT/addons/config/usbarsenal.config")
            ;;
        both)
            fragments+=(
                "$ROOT/addons/config/droidspace.config"
                "$ROOT/addons/config/usbarsenal.config"
            )
            ;;
        *)
            echo "ERROR: Invalid DEFCONFIG_CHOICE: ${DEFCONFIG_CHOICE:-both}"
            return 1
            ;;
    esac

    # Collect every explicitly enabled CONFIG option from selected fragments.
    for fragment in "${fragments[@]}"; do
        [[ -f "$fragment" ]] || {
            echo "ERROR: Config fragment not found: $fragment"
            return 1
        }

        while IFS= read -r symbol; do
            [[ -n "$symbol" ]] && required_configs["$symbol"]=y
        done < <(
            sed -nE 's/^[[:space:]]*(CONFIG_[A-Za-z0-9_]+)=y[[:space:]]*$/\1/p' "$fragment"
        )
    done

    echo "Verifying required kernel configuration..."

    local failed=0

    for symbol in "${!required_configs[@]}"; do
        expected="CONFIG_${symbol#CONFIG_}=y"

        if ! grep -qxF "$expected" "$cfg"; then
            echo "ERROR: Required option is not enabled: $symbol"
            failed=1
        fi
    done

    if (( failed )); then
        echo "ERROR: One or more required configuration options are missing."
        return 1
    fi

    echo "All selected fragment configuration options are enabled."

    # Preserve the existing Droidspaces/WALT compatibility warning.
    if [[ "${DEFCONFIG_CHOICE:-both}" == "droidspace" ||
          "${DEFCONFIG_CHOICE:-both}" == "both" ]]; then
        if grep -q '^CONFIG_SCHED_WALT=y$' "$cfg"; then
            echo "WARNING: CONFIG_SCHED_WALT=y detected; verify Droidspaces compatibility."
        fi
    fi
}

merge_addon_config() {
    local cfg="$OUT/.config"
    local -a fragments=()

    case "${DEFCONFIG_CHOICE:-both}" in
        droidspace)
            fragments+=("$ROOT/addons/config/droidspace.config")
            ;;
        usbarsenal)
            fragments+=("$ROOT/addons/config/usbarsenal.config")
            ;;
        both)
            fragments+=(
                "$ROOT/addons/config/droidspace.config"
                "$ROOT/addons/config/usbarsenal.config"
            )
            ;;
        *)
            echo "ERROR: Invalid DEFCONFIG_CHOICE: ${DEFCONFIG_CHOICE:-both}"
            return 1
            ;;
    esac

    for fragment in "${fragments[@]}"; do
        [[ -f "$fragment" ]] || {
            echo "ERROR: Config fragment not found: $fragment"
            return 1
        }
    done

    echo "Merging selected add-on configuration fragments..."

    "$ROOT/scripts/kconfig/merge_config.sh" \
        -m -O "$OUT" "$cfg" "${fragments[@]}"

    make O="$OUT" ARCH="$ARCH" olddefconfig

    verify_config "$cfg"
}


prepare() {
	local target="$DEFCONFIG"

	apply_patches

	case "$target" in
		arch/"$ARCH"/configs/*)
			target="${target#arch/$ARCH/configs/}"
			;;
	esac

	msg "generating $OUT/.config from $target"

	make O="$OUT" ARCH="$ARCH" "$target" >&2 ||
		die "defconfig generation failed"

	merge_addon_config "$OUT/.config"
}

case "$MODE" in
	prepare)
		prepare
		;;
	patches)
		apply_patches
		;;
	config)
		[ -n "$CONFIG_FILE" ] || CONFIG_FILE="$OUT/.config"
		merge_addon_config "$CONFIG_FILE"
		;;
	*)
		die "unknown mode: $MODE"
		;;
esac

msg "done"
