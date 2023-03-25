#!/bin/bash
set -euo pipefail

BUILD_DIR="$1"
CLT_TMP_DIR="$BUILD_DIR/apple-clts"

mkdir -p "$CLT_TMP_DIR"

# extract mounted "Command Line Developer Tools" installers
for d in "/Volumes/Command Line Developer Tools"*; do
  [ -d "$d" ] || continue
  ID=
  DISK_IMAGE="$(hdiutil info | grep -B20 "$d" | grep image-path |
    awk '{print $3 $4 $5 $6 $7}' || true)"
  if [ -f "$DISK_IMAGE" ]; then
    ID=$(shasum "$DISK_IMAGE" | cut -d' ' -f1)
  else
    ID=$(shasum <<< "$d" | cut -d' ' -f1)
  fi
  SUBDIR="$CLT_TMP_DIR/$ID"
  if [ -f "$SUBDIR/processed.mark" ]; then
    echo "skipping already-processed $(relpath "$SUBDIR")"
    continue
  fi
  echo "extracting $(relpath "$d")"
  mkdir -p "$SUBDIR"
  pushd "$SUBDIR"
  pkg="$(echo "$d/Command Line Tools"*.pkg)"
  if [ -f "$pkg" ]; then
    # extra .pkg wrapper
    echo "  xar -xf $pkg"
    xar -xf "$pkg"
  else
    # pre 10.14 SDKs didn't have that wrapper
    echo "  cp" "$d"/*_SDK_macOS*.pkg "."
    cp -a "$d"/*_SDK_macOS*.pkg .
  fi
  for f in *_mac*_SDK.pkg *_SDK_macOS*.pkg; do
    [ -e "$f" ] || continue
    payload_file="$f/Payload"
    if [ -f "$f" ]; then
      echo "  xar -xf $f"
      xar -xf "$f"
      payload_file="Payload"
    fi
    echo "  pbzx -n $payload_file | cpio -i"
    pbzx -n "$payload_file" | cpio -i 2>/dev/null &
  done
  printf "  ..." ; wait ; echo
  rm -rf Payload Bom PackageInfo Distribution Resources *.pkg
  popd
  touch "$SUBDIR/processed.mark"
done

