#!/bin/zsh
# Puts ONNX Runtime's macOS library and C headers in Vendor/onnxruntime, from Microsoft's NuGet
# package. That library needs only macOS frameworks, so HandFX.app can carry it to other Macs.
set -euo pipefail
cd "${0:A:h}"
VERSION=1.32.0
SHA256=a9150bc2992cbbb6722070da9910e1ffa989a8bfc67bdd5bb8e745ca755641db
OUT=Vendor/onnxruntime
[[ -f $OUT/lib/libonnxruntime.1.dylib && -f $OUT/include/onnxruntime_c_api.h && -f $OUT/notices/LICENSE ]] && exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sSfL -o "$tmp/ort.nupkg" \
  "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$VERSION/microsoft.ml.onnxruntime.$VERSION.nupkg"
echo "$SHA256  $tmp/ort.nupkg" | shasum -a 256 -c --quiet
unzip -q "$tmp/ort.nupkg" 'runtimes/osx-arm64/native/libonnxruntime.dylib' 'build/native/include/*' \
  LICENSE ThirdPartyNotices.txt -d "$tmp/x"
mkdir -p $OUT/lib $OUT/include $OUT/notices
cp "$tmp/x/runtimes/osx-arm64/native/libonnxruntime.dylib" $OUT/lib/libonnxruntime.1.dylib
ln -sf libonnxruntime.1.dylib $OUT/lib/libonnxruntime.dylib
cp "$tmp"/x/build/native/include/*.h $OUT/include/
cp "$tmp/x/LICENSE" "$tmp/x/ThirdPartyNotices.txt" $OUT/notices/  # the app must carry these
echo "ONNX Runtime $VERSION in $OUT"
