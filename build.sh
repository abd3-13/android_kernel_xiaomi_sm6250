
#!/bin/bash
#
# Build the miatoll kernel with optional Droidspaces and USB Arsenal add-ons.
#
# Environment overrides:
#   OUT               output directory
#   DEFCONFIG         base kernel defconfig
#   DEFCONFIG_CHOICE  droidspace | usbarsenal | both
#   PATCH_CHOICE      droidspace | usbarsenal | both
#   BUILD_MODE        configured | clean
#   JOBS              parallel make jobs
#   CCACHE_MAXSIZE    ccache size limit
#   TANGGAL           zip timestamp
#

set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

export ARCH="${ARCH:-arm64}"
OUT="${OUT:-out}"
DEFCONFIG="${DEFCONFIG:-arch/arm64/configs/vendor/xiaomi/miatoll_defconfig}"
DEFCONFIG_CHOICE="${DEFCONFIG_CHOICE:-both}"
PATCH_CHOICE="${PATCH_CHOICE:-both}"
BUILD_MODE="${BUILD_MODE:-configured}"
JOBS="${JOBS:-$(nproc --all)}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-25G}"
TANGGAL="${TANGGAL:-$(date +"%Y%m%d-%H")}"

export LC_ALL=C
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-android-build}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-kim_chi_96}"

# Keep local shell customisations working, but never let them abort the build.
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc" >/dev/null 2>&1 || true
[ -f "$HOME/.profile" ] && . "$HOME/.profile" >/dev/null 2>&1 || true

# shellcheck source=/dev/null
[ -f "$ROOT/addons/addons.env" ] && . "$ROOT/addons/addons.env"

ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/Amritorock/AnyKernel3}"
ANYKERNEL_REF="${ANYKERNEL_REF:-560fd55ddf072309e316315684ba57eaef795632}"

# Validate workflow inputs before modifying the build.
case "$BUILD_MODE" in
	configured|clean) ;;
	*)
		echo "Invalid BUILD_MODE: $BUILD_MODE" >&2
		exit 1
		;;
esac

case "$DEFCONFIG_CHOICE" in
	droidspace|usbarsenal|both) ;;
	*)
		echo "Invalid DEFCONFIG_CHOICE: $DEFCONFIG_CHOICE" >&2
		exit 1
		;;
esac

case "$PATCH_CHOICE" in
	droidspace|usbarsenal|both) ;;
	*)
		echo "Invalid PATCH_CHOICE: $PATCH_CHOICE" >&2
		exit 1
		;;
esac

echo "========================================"
echo "Kernel build configuration"
echo "Build mode:        $BUILD_MODE"
echo "Defconfig choice:  $DEFCONFIG_CHOICE"
echo "Patch choice:      $PATCH_CHOICE"
echo "Base defconfig:    $DEFCONFIG"
echo "Output directory:  $OUT"
echo "Jobs:              $JOBS"
echo "========================================"

CCACHE_CMD=""
if command -v ccache >/dev/null 2>&1; then
	ccache -M "$CCACHE_MAXSIZE" >/dev/null
	CCACHE_CMD="ccache "
fi

clone_toolchain() {
	local dest="$1" url="$2" marker="$3"

	[ -e "$marker" ] && return 0

	echo "Cloning toolchain: $url"
	rm -rf "$dest"
	git clone --depth=1 "$url" "$dest"
}

clone_toolchain clang \
	https://github.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-6443078 \
	clang/bin/clang || exit 1

clone_toolchain gcc64 \
	https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 \
	gcc64/bin/aarch64-linux-android-as || exit 1

clone_toolchain gcc32 \
	https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9 \
	gcc32/bin/arm-linux-androideabi-as || exit 1

# Prepare kernel configuration and optional add-ons.
if [[ "$BUILD_MODE" == "clean" ]]; then
	echo "Clean mode: skipping add-on patches and configuration fragments."

	# A fresh runner still needs a base kernel .config.
	make O="$OUT" ARCH="$ARCH" "$DEFCONFIG" || {
		echo "Failed to initialize base kernel defconfig"
		exit 1
	}
else
	echo "Configured mode: preparing selected add-ons."

	# These environment variables must be handled by apply-addons.sh.
	DEFCONFIG_CHOICE="$DEFCONFIG_CHOICE" \
	PATCH_CHOICE="$PATCH_CHOICE" \
	bash ./addons/apply-addons.sh prepare \
		--defconfig "$DEFCONFIG" \
		--out "$OUT" || {
		echo "Failed to prepare kernel add-ons"
		exit 1
	}
fi

echo "Building kernel ($JOBS jobs)..."

PATH="$ROOT/clang/bin:$ROOT/gcc32/bin:$ROOT/gcc64/bin:$PATH" \
	make -j"$JOBS" O="$OUT" \
		ARCH="$ARCH" \
		CC="${CCACHE_CMD}clang" \
		HOSTCC="${CCACHE_CMD}gcc" \
		CLANG_TRIPLE=aarch64-linux-gnu- \
		CROSS_COMPILE="$ROOT/gcc64/bin/aarch64-linux-android-" \
		CROSS_COMPILE_ARM32="$ROOT/gcc32/bin/arm-linux-androideabi-" \
		LD=ld.lld \
		CONFIG_NO_ERROR_ON_MISMATCH=y || {
	echo "Kernel build failed"
	exit 1
}

zimage="$OUT/arch/arm64/boot/Image.gz"
if [ ! -f "$zimage" ]; then
	echo "Failed to compile kernel: $zimage not found"
	exit 1
fi

echo "Kernel compile successful"

rm -rf AnyKernel
git clone --depth=1 "$ANYKERNEL_REPO" AnyKernel || {
	echo "Failed to clone $ANYKERNEL_REPO"
	exit 1
}

git -C AnyKernel fetch --depth=1 origin "$ANYKERNEL_REF" || {
	echo "Failed to fetch AnyKernel3 ref $ANYKERNEL_REF"
	exit 1
}

git -C AnyKernel checkout --detach "$ANYKERNEL_REF" || {
	echo "Failed to check out AnyKernel3 ref $ANYKERNEL_REF"
	exit 1
}

cp "$zimage" AnyKernel/ || {
	echo "Failed to copy $zimage into AnyKernel"
	exit 1
}

zip_name="BlackHole-v2.1_KSU-miatoll-${TANGGAL}.zip"

(
	cd AnyKernel || exit 1
	zip -r9 "$zip_name" * >/dev/null || exit 1
	sha256sum "$zip_name" > "$zip_name.sha256" || exit 1
) || {
	echo "Failed to create $zip_name"
	exit 1
}

zip_path="$ROOT/AnyKernel/$zip_name"
echo "Release zip: $zip_path"
cat "$zip_path.sha256"
