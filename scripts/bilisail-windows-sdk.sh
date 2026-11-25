#!/usr/bin/env bash
set -euo pipefail
recipe=$PWD
mkdir -p sdk/provenance
git config --global --add safe.directory "$PWD"
git rev-parse HEAD > sdk/provenance/build-recipe.commit
echo "$BUILD_IMAGE" > sdk/provenance/build-image
checkout_source() {
    git init -q "$1"
    git -C "$1" fetch --depth=1 "$2" "$3"
    git -C "$1" checkout --detach FETCH_HEAD
    git -C "$1" rev-parse HEAD > "sdk/provenance/$1.commit"
}
checkout_source ffmpeg https://github.com/FFmpeg/FFmpeg.git dd86debdbcec9ec057304c845859771bd6a10c8c
checkout_source mpv https://github.com/mpv-player/mpv.git 1eb941fdb974fe25dc0ac68a33652c145ff41f9d
git -C ffmpeg apply "$recipe"/packages/ffmpeg-*.patch
git -C mpv apply "$recipe"/packages/mpv-*.patch
# Take the exact component allowlist from the pinned Predidit recipe.
mapfile -t components < <(sed -nE 's/^[[:space:]]*(--(enable|disable)-(decoder|encoder|protocol|filter|parser|bsf|muxer|demuxer)s?(=[^[:space:]]+)?)[[:space:]]*$/\1/p' packages/ffmpeg.cmake)
[[ " ${components[*]} " == *" --enable-muxer=spdif "* ]]
# Use the image's static LGPL codec, TLS and hardware development libraries.
# Restrict codecs/containers after the image configuration, preserving the
# application's range/HLS patch and the renderer's D3D11VA/Dolby metadata.
(cd ffmpeg
 ./configure --prefix="$FFBUILD_PREFIX" --pkg-config-flags=--static \
    $FFBUILD_TARGET_FLAGS $FF_CONFIGURE --extra-cflags="$FF_CFLAGS" \
    --extra-cxxflags="$FF_CXXFLAGS" --extra-libs="$FF_LIBS" --extra-ldflags="$FF_LDFLAGS" \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --nm="$NM" \
    --disable-doc --disable-programs --disable-shared --enable-static --disable-gpl --disable-nonfree \
    --disable-librav1e --disable-librsvg --disable-openal --enable-version3 "${components[@]}" \
    || { tail -100 ffbuild/config.log; exit 1; }
 grep -q '^#define CONFIG_SPDIF_MUXER 1' config_components.h
 grep -q '^#define CONFIG_HTTPS_PROTOCOL 1' config_components.h
 make -s -j"$(nproc)" > build.log 2>&1 || { tail -120 build.log; exit 1; }
 make -s install > /dev/null)
if [[ $SDK_ARCH == x64 ]]; then
  wget -q https://github.com/CKopoer/media-kit/releases/download/native-2026-11-07/ANGLE.7z
  echo 'cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a  ANGLE.7z' | sha256sum -c -
  archive_tool=$(command -v 7zz || command -v 7z)
  "$archive_tool" x ANGLE.7z -oangle >/dev/null
  cp -a angle/include/. "$FFBUILD_PREFIX/include/"
  gl=(-Dgl=enabled -Degl-angle=enabled -Degl-angle-lib=disabled)
else
  gl=(-Dgl=disabled -Degl-angle=disabled)
fi
# This builds a cross SDK. Meson's compiler probe cannot launch a PE file
# through Wine on every hosted runner; the packaged DLL is tested on Windows.
sed '/^[[:space:]]*exe_wrapper[[:space:]]*=/d' /cross.meson > sdk-cross.meson
(cd mpv
 meson setup build --cross-file "$recipe/sdk-cross.meson" --buildtype=release --default-library=shared --prefer-static \
   -Dgpl=false -Dlibmpv=true -Dc_link_args="$FF_LIBS" -Dcpp_link_args="$FF_LIBS" \
   -Dlua=disabled -Djavascript=disabled -Dwin32-smtc=disabled -Dvulkan=disabled \
   -Dd3d11=enabled -Dd3d-hwaccel=enabled -Dspirv-cross=enabled "${gl[@]}"
 ninja -C build libmpv-2.dll > build.log 2>&1 || { tail -120 build.log; exit 1; })
mkdir -p sdk/include/mpv
cp mpv/build/libmpv-2.dll mpv/build/libmpv.dll.a sdk/
cp mpv/include/mpv/*.h sdk/include/mpv/
"${FFBUILD_CROSS_PREFIX}strip" sdk/libmpv-2.dll
test -s sdk/include/mpv/render_d3d11.h
cp ffmpeg/config_components.h ffmpeg/ffbuild/config.log mpv/build/meson-info/intro-buildoptions.json sdk/provenance/
cp mpv/LICENSE.LGPL mpv/Copyright ffmpeg/COPYING.LGPLv3 sdk/provenance/
cp scripts/bilisail-windows-sdk.sh sdk/provenance/
while IFS= read -r -d '' notice; do
  relative=${notice#"$FFBUILD_PREFIX/share/"}
  mkdir -p "sdk/provenance/licenses/$(dirname "$relative")"
  cp "$notice" "sdk/provenance/licenses/$relative"
done < <(find "$FFBUILD_PREFIX/share" -type f \( -iname '*license*' -o -iname '*copying*' -o -iname '*copyright*' -o -iname '*notice*' \) -print0)
python3 -m zipfile -c "mpv-dev-windows-$SDK_ARCH.zip" sdk/*
