#!/bin/bash
# Where SwiftPM put this package's build products. The directory belongs to the
# build system the toolchain defaults to: `.build/arm64-apple-macosx/<config>` for
# native, `.build/out/Products/<Config>` for swiftbuild (the default from Swift 6.4).
# `.build/debug` and `.build/release` are only as current as the last build, so a
# tree that has seen both systems can leave them naming the other one's products.
# Scripts ask the toolchain and never spell a layout.

# build_products_dir <package-root> [debug|release] — print the products directory.
# The query takes SwiftPM's .build lock, so it waits for a build running in the same
# tree: under swiftbuild it writes marker files there, and products mid-build are not
# ones to launch anyway.
build_products_dir() {
    local package_root="$1"
    local configuration="${2:-debug}"
    local bin_path
    if ! bin_path="$(swift build --package-path "$package_root" \
        --configuration "$configuration" --show-bin-path 2>/dev/null)" \
        || [[ -z "$bin_path" ]]; then
        echo "error: could not resolve the $configuration build products directory for $package_root (swift build --show-bin-path failed)." >&2
        return 1
    fi
    printf '%s\n' "${bin_path##*$'\n'}"
}

# resource_bundle_contents <bundle> — the directory holding an SPM resource bundle's
# files. Native builds write them at the bundle root; swiftbuild writes a structured
# bundle with Contents/Resources (and a Contents/Info.plist that is the bundle's own,
# which must not land in the app).
resource_bundle_contents() {
    local bundle="$1"
    if [[ -d "$bundle/Contents/Resources" ]]; then
        printf '%s/Contents/Resources\n' "$bundle"
    else
        printf '%s\n' "$bundle"
    fi
}
