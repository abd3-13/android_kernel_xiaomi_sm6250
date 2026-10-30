#!/usr/bin/env bash
#
# Apply the Droidspaces and USB Arsenal add-ons to this kernel tree.
#
# The kernel branch is kept clean: patches are applied to the working tree and
# the config fragments are merged into the generated .config at build time.
# Run this from anywhere; it always works relative to the repository root.
#
# Modes:
#   prepare   apply patches, generate the defconfig, merge the add-on fragments
#             and run olddefconfig (used by build.sh and GitHub Actions)
#   patches   only apply the patches
#   config    only merge the fragments into --config <file>
#
# Examples:
#   ./addons/apply-addons.sh prepare --defconfig arch/arm64/configs/vendor/xiaomi/miatoll_defconfig --out out
#   ./addons/apply-addons.sh patches
#   ./addons/apply-addons.sh config out/.config
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
CACHE_DIR="${ADDONS_CACHE_DIR:-$SCRIPT_DIR/.cache}"
MODE="prepare"
CONFIG_FILE=""

usage() {
	cat <<'EOF'
Usage: apply-addons.sh <mode> [options]

Modes:
  prepare                 apply patches + defconfig + merge fragments
  patches                 apply patches only
  config [--config FILE]  merge fragments into FILE (default: $OUT/.config)

Options:
  --defconfig PATH        defconfig to generate
                          (default: arch/arm64/configs/vendor/xiaomi/miatoll_defconfig)
  --out DIR               kernel output directory (default: out)
  --config FILE           existing .config to merge into (implies mode config)
  -h, --help              show this help

Environment:
  ADDONS_CACHE_DIR        download cache (default: addons/.cache)
  USB_ARSENAL_DIR         local USB-Arsenal checkout instead of downloading
  DROIDSPACES_PATCH_DIR   local non-GKI patch directory instead of downloading
  USB_ARSENAL_REF         override the pinned USB Arsenal commit
  DROIDSPACES_REF         override the pinned Droidspaces commit
EOF
}

msg()  { printf '[addons] %s\n' "$*" >&2; }
warn() { printf '[addons] WARNING: %s\n' "$*" >&2; }
die()  { printf '[addons] ERROR: %s\n' "$*" >&2; exit 1; }

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

mkdir -p "$CACHE_DIR"

detect_kernel_version() {
	local version patchlevel
	version=$(awk '/^VERSION[[:space:]]*=/{print $3; exit}' Makefile)
	patchlevel=$(awk '/^PATCHLEVEL[[:space:]]*=/{print $3; exit}' Makefile)
	[ -n "$version" ] && [ -n "$patchlevel" ] || die "cannot read VERSION/PATCHLEVEL from Makefile"
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
	[ "${#files[@]}" -eq 1 ] || die "expected exactly one patch matching: $pattern (found ${#files[@]})"
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

	if [ -n "$sentinel_file" ] && sentinel_present "$sentinel_file" "$sentinel_pattern"; then
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
		patch -p1 --forward --batch --silent < "$patch" || die "cannot apply $label"
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
	if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/src.tar.gz" "$url"; then
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
	msg "downloading $(basename -- "$dest")"
	if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
		rm -f "$tmp"
		die "download failed: $url"
	fi
	mv -f "$tmp" "$dest"
}

apply_usb_arsenal() {
	local kver src dir p n
	kver=$(detect_kernel_version)
	msg "kernel version: $kver"

	if [ -n "${USB_ARSENAL_DIR:-}" ] && [ -d "$USB_ARSENAL_DIR/kernel-patches" ]; then
		src="$USB_ARSENAL_DIR"
	elif [ -d "$ROOT/external/USB-Arsenal/kernel-patches" ]; then
		src="$ROOT/external/USB-Arsenal"
	else
		src=$(fetch_tarball "${USB_ARSENAL_REPO}" "${USB_ARSENAL_REF}" "USB-Arsenal")
	fi

	dir="$src/kernel-patches/$kver"
	[ -d "$dir" ] || die "USB Arsenal has no kernel-patches/$kver directory"

	case "$kver" in
		4.14)
			# 0001 is already provided by this tree's CAF multi-gadget support.
			# 0002 needs Samsung CONFIG_USB_OLD_CONFIGFS/linked_func (absent).
			# 0003 needs Samsung NCM extras (absent); the generic RX fix is
			# already in this tree's ncm_unwrap_ntb().
			p=$(one_patch "$dir/0004-*.patch")
			apply_one "$p" drivers/usb/gadget/function/f_mass_storage.c 'SFF-8020i'
			p=$(one_patch "$dir/0005-*.patch")
			apply_one "$p" drivers/usb/gadget/function/f_mass_storage.c 'Multi-session info'
			p=$(one_patch "$dir/0006-*.patch")
			apply_one "$p" drivers/usb/gadget/function/storage_common.h 'cd_as_dvd'
			p=$(one_patch "$dir/0007-*.patch")
			apply_one "$p" drivers/usb/gadget/function/f_hid.c 'F_HID_OPT\(interval'

			# 0008-0012 are one f_hid lifetime/rebind series. cdev_alloc()
			# only appears after the last patch, so it is the series sentinel.
			if sentinel_present drivers/usb/gadget/function/f_hid.c 'hidg->cdev = cdev_alloc\(\)'; then
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
		fetch_url "$raw/01.fix_kernel_panic_in_xt_qtaguid.patch" "$p01"
		fetch_url "$raw/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch" "$p02"
	fi

	# 01 only touches xt_qtaguid; this tree does not carry that driver.
	if [ -e net/netfilter/xt_qtaguid.c ]; then
		apply_one "$p01"
	else
		msg "skipping Droidspaces 01: net/netfilter/xt_qtaguid.c is not in this tree"
	fi

	apply_one "$p02" kernel/cgroup/cgroup.c 'kernfs_create_link\(cgrp->kn, name, kn\)'
}

apply_patches() {
	apply_usb_arsenal
	apply_droidspaces
}

REQUIRED_CONFIGS=(
	CONFIG_NAMESPACES
	CONFIG_PID_NS
	CONFIG_UTS_NS
	CONFIG_IPC_NS
	CONFIG_NET_NS
	CONFIG_USER_NS
	CONFIG_SECCOMP
	CONFIG_SECCOMP_FILTER
	CONFIG_CGROUPS
	CONFIG_CGROUP_DEVICE
	CONFIG_MEMCG
	CONFIG_MEMCG_SWAP
	CONFIG_CGROUP_PIDS
	CONFIG_DEVTMPFS
	CONFIG_OVERLAY_FS
	CONFIG_VETH
	CONFIG_BRIDGE
	CONFIG_NF_NAT
	CONFIG_NF_NAT_REDIRECT
	CONFIG_IP_NF_NAT
	CONFIG_IP_NF_TARGET_MASQUERADE
	CONFIG_USB_CONFIGFS
	CONFIG_USB_CONFIGFS_MASS_STORAGE
	CONFIG_USB_CONFIGFS_F_HID
	CONFIG_USB_CONFIGFS_NCM
	CONFIG_USB_CONFIGFS_RNDIS
)

verify_config() {
	local cfg="$1" sym missing=0
	for sym in "${REQUIRED_CONFIGS[@]}"; do
		if ! grep -q "^${sym}=y$" "$cfg"; then
			warn "required option is not enabled: $sym"
			missing=1
		fi
	done

	if grep -q '^CONFIG_SCHED_WALT=y$' "$cfg" && ! grep -q '^CONFIG_CFS_BANDWIDTH=y$' "$cfg"; then
		warn "CONFIG_CFS_BANDWIDTH is unavailable because CONFIG_SCHED_WALT=y (Droidspaces --cpus limit will be skipped)"
	fi

	[ "$missing" -eq 0 ] || die "required kernel options are missing from $cfg"
	msg "config check passed: $cfg"
}

merge_addon_config() {
	local cfg="$1" outdir
	[ -f "$cfg" ] || die "config file not found: $cfg"
	outdir=$(dirname -- "$cfg")

	msg "merging add-on config fragments into $cfg"
	scripts/kconfig/merge_config.sh -m -O "$outdir" "$cfg" \
		"$SCRIPT_DIR/config/droidspace.config" \
		"$SCRIPT_DIR/config/usbarsenal.config" >&2 \
		|| die "merge_config.sh failed"

	make O="$outdir" ARCH="$ARCH" olddefconfig >&2 || die "olddefconfig failed"
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
	make O="$OUT" ARCH="$ARCH" "$target" >&2 || die "defconfig generation failed"
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
