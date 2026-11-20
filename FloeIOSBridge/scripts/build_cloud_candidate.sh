#!/bin/bash
# Build a new, source-verified candidate without claiming the author's binary hash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
: "${GITHUB_SHA:?Run this candidate build at an explicit GitHub commit}"
: "${DEVELOPER_DIR:?Select the pinned Xcode toolchain}"
: "${FLOE_BRIDGE_CACHE:?Set the app build directory}"
: "${FLOE_IDEVICE_CACHE:?Set the native build directory}"
: "${FLOE_IDEVICE_SOURCE_ROOT:?Set the native source directory}"
: "${FLOE_BRIDGE_SCRATCH_DIR:?Set the build scratch directory}"
: "${FLOE_BRIDGE_ARTIFACT_DIR:?Set the artifact directory}"
test "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$GITHUB_SHA"
mkdir -p "$FLOE_BRIDGE_ARTIFACT_DIR" "$FLOE_BRIDGE_SCRATCH_DIR" "$FLOE_IDEVICE_CACHE"

python3 -B "$SCRIPT_DIR/package_bridge.py" --check --mode product-qualification \
    --project "$PROJECT_DIR/project.yml" --repo-root "$REPO_ROOT" \
    --source-ref "$GITHUB_SHA" > "$FLOE_BRIDGE_SCRATCH_DIR/preflight-check.json"

# Keep the original archive, patch, Cargo.lock, Rust and SDK pins unchanged.
python3 -B "$PROJECT_DIR/Vendor/verify_idevice.py" \
    --lock "$PROJECT_DIR/Vendor/idevice.lock.json" --project "$PROJECT_DIR" \
    --prepare "$FLOE_IDEVICE_SOURCE_ROOT"
SOURCE="$FLOE_IDEVICE_SOURCE_ROOT/source"
export CARGO_TARGET_DIR="$FLOE_IDEVICE_CACHE/target"
export IPHONEOS_DEPLOYMENT_TARGET=26.0
printf -v CARGO_ENCODED_RUSTFLAGS '%s\037%s' \
    "--remap-path-prefix=$SOURCE=/floe/idevice" \
    "--remap-path-prefix=$HOME/.cargo/registry/src=/floe/cargo"
export CARGO_ENCODED_RUSTFLAGS
FEATURES="ring,cryptexd,tunnel_tcp_stack,mobile_image_mounter,tss,tcp"
cargo test --manifest-path "$SOURCE/Cargo.toml" -p idevice-ffi --locked \
    --no-default-features --features "$FEATURES" -j "${FLOE_IDEVICE_JOBS:-3}" \
    --lib ddi_control::tests 2>&1 | tee "$FLOE_BRIDGE_ARTIFACT_DIR/native-tests.log"
cargo rustc --manifest-path "$SOURCE/Cargo.toml" -p idevice-ffi --locked \
    --release --target aarch64-apple-ios --no-default-features \
    --features "$FEATURES" -j "${FLOE_IDEVICE_JOBS:-3}" --lib --crate-type staticlib \
    2>&1 | tee "$FLOE_BRIDGE_ARTIFACT_DIR/native-build.log"

python3 -B - "$PROJECT_DIR" "$SOURCE" "$FLOE_IDEVICE_CACHE" "$FLOE_BRIDGE_ARTIFACT_DIR" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys

project, source, cache, artifacts = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("native_verifier", project / "Vendor/verify_idevice.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
lock = json.loads((project / "Vendor/idevice.lock.json").read_text())
recipe = verifier.check(lock, project)
verifier.require(verifier.source_digest(source) == recipe["patchedSourceSHA256"], "native source drift")
verifier.require(verifier.sha(source / "Cargo.lock") == recipe["cargoLockSHA256"], "native dependency drift")
rust = subprocess.check_output(["rustc", "-V"], text=True).strip()
sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True).strip()
verifier.require(rust == recipe["rustc"] and sdk == recipe["sdk"], "native toolchain drift")
library = cache / "target/aarch64-apple-ios/release/libidevice_ffi.a"
header = source / "ffi/idevice.h"
verifier.require(verifier.sha(header) == recipe["headerSHA256"], "native public header changed")
sysroot = pathlib.Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
host = next(line.split(": ", 1)[1] for line in subprocess.check_output(["rustc", "-vV"], text=True).splitlines() if line.startswith("host: "))
nm = sysroot / "lib/rustlib" / host / "bin/llvm-nm"
symbols = subprocess.check_output([str(nm), "-g", "--defined-only", str(library)], text=True)
required = [
    "floe_ddi_abi_version", "floe_ddi_scope_begin", "floe_ddi_scope_stop_reason",
    "floe_ddi_scope_reconcile", "floe_ddi_scope_end", "cryptexd_install_ddi",
    "image_mounter_mount_personalized_with_callback_rsd",
    "rp_pairing_file_from_bytes", "rp_pairing_file_free",
]
for symbol in required:
    verifier.require(symbol in header.read_text(), "native header ABI missing " + symbol)
    verifier.require(any(line.rstrip().endswith(" _" + symbol) for line in symbols.splitlines()), "native binary ABI missing " + symbol)
verifier.require("arm64" in subprocess.check_output(["lipo", "-info", str(library)], text=True), "native binary is not arm64")
destination = cache / "IDevice.xcframework"
headers = destination / "ios-arm64/Headers"
headers.mkdir(parents=True, exist_ok=True)
shutil.copy2(library, destination / "ios-arm64/libidevice_ffi.a")
shutil.copy2(header, headers / "idevice.h")
(headers / "module.modulemap").write_text('module IDevice {\n  header "idevice.h"\n  export *\n}\n')
with (destination / "Info.plist").open("wb") as stream:
    plistlib.dump({"AvailableLibraries": [{"LibraryIdentifier": "ios-arm64", "LibraryPath": "libidevice_ffi.a", "HeadersPath": "Headers", "SupportedArchitectures": ["arm64"], "SupportedPlatform": "ios"}], "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0"}, stream)
metadata = {key: recipe[key] for key in ["sourceArchiveSHA256", "patchSHA256", "patchedSourceSHA256", "cargoLockSHA256"]}
metadata.update(
    abiVersion=1, upstreamCommit=lock["commit"], target="aarch64-apple-ios",
    librarySHA256=verifier.sha(library), headerSHA256=verifier.sha(header), rustc=rust, sdk=sdk,
    buildOrigin="github-actions-source-build", sourceVerified=True, requiredABIVerified=True,
    historicalQualifiedLibrarySHA256=recipe["librarySHA256"],
    matchesHistoricalQualifiedOutput=verifier.sha(library) == recipe["librarySHA256"],
)
verifier.require(verifier.sha(destination / "ios-arm64/libidevice_ffi.a") == metadata["librarySHA256"], "native copy changed")
metadata_text = json.dumps(metadata, sort_keys=True, indent=2) + "\n"
(destination / ".floe-native.json").write_text(metadata_text)
(artifacts / "native-source-build.json").write_text(metadata_text)
print(metadata_text)
link = project / "Frameworks/IDevice.xcframework"
link.parent.mkdir(exist_ok=True)
verifier.require(not link.exists() or link.is_symlink(), "refusing to replace an existing native framework")
if link.is_symlink():
    link.unlink()
link.symlink_to(destination, target_is_directory=True)
PY

FLOE_BRIDGE_SCRATCH="$FLOE_BRIDGE_SCRATCH_DIR" \
FLOE_BRIDGE_CHECK_OUTPUT="$FLOE_BRIDGE_ARTIFACT_DIR" \
    bash "$SCRIPT_DIR/run_core_checks.sh"

XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
COMMON_ARGS=(
    -project "$PROJECT_DIR/FloeIOSBridge.xcodeproj"
    -configuration Release -destination "generic/platform=iOS"
    -derivedDataPath "$FLOE_BRIDGE_CACHE" -jobs "${FLOE_BRIDGE_JOBS:-3}"
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
)
"$XCODEBUILD" "${COMMON_ARGS[@]}" -scheme BridgeTests build \
    2>&1 | tee "$FLOE_BRIDGE_ARTIFACT_DIR/build-test.log"
"$XCODEBUILD" "${COMMON_ARGS[@]}" -scheme BridgeHost build \
    2>&1 | tee "$FLOE_BRIDGE_ARTIFACT_DIR/build-host.log"

BUILD_DIR="$FLOE_BRIDGE_CACHE/Build/Products/Release-iphoneos"
XCTEST_PATH="$BUILD_DIR/BridgeTests-Runner.app/PlugIns/BridgeTests.xctest"
if [ ! -d "$XCTEST_PATH" ]; then XCTEST_PATH="$BUILD_DIR/BridgeTests.xctest"; fi
test -d "$XCTEST_PATH"
DSYMS=()
for candidate in "$BUILD_DIR/BridgeHost.app.dSYM" "$BUILD_DIR/BridgeTunnel.appex.dSYM" \
    "$BUILD_DIR/BridgeCore.framework.dSYM" "$(dirname "$XCTEST_PATH")/BridgeTests.xctest.dSYM"; do
    if [ -d "$candidate" ]; then DSYMS+=(--dSYM "$candidate"); fi
done
python3 -B "$SCRIPT_DIR/package_bridge.py" --app "$BUILD_DIR/BridgeHost.app" \
    --xctest "$XCTEST_PATH" --output-dir "$FLOE_BRIDGE_ARTIFACT_DIR" \
    --repo-root "$REPO_ROOT" --project "$PROJECT_DIR/project.yml" \
    --mode product-qualification --source-ref "$GITHUB_SHA" \
    --ipa-name Floe-iOS-Bridge-1.0.0-import-fix-unsigned.ipa "${DSYMS[@]}" \
    | tee "$FLOE_BRIDGE_ARTIFACT_DIR/package-result.json"
python3 -B "$SCRIPT_DIR/verify_bridge.py" \
    --ipa "$FLOE_BRIDGE_ARTIFACT_DIR/Floe-iOS-Bridge-1.0.0-import-fix-unsigned.ipa" \
    --mode product-qualification --project "$PROJECT_DIR/project.yml" \
    --source-ref "$GITHUB_SHA" --expected-version 1.0.0 --expected-build 18 \
    > "$FLOE_BRIDGE_ARTIFACT_DIR/verify.txt"
