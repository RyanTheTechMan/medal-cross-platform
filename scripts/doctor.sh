#!/bin/sh
set -u

printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sw_vers
uname -a
printf 'machine=%s\n' "$(uname -m)"
printf 'arch_command=%s\n' "$(arch)"
printf 'cpu=%s\n' "$(sysctl -n machdep.cpu.brand_string)"

printf '\n[selected developer tools]\n'
xcode-select -p 2>&1 || true
xcodebuild -version 2>&1 || true
xcrun --sdk macosx --show-sdk-version 2>&1 || true
xcrun --sdk macosx --show-sdk-path 2>&1 || true
clang --version 2>&1 || true

for xcode in /Applications/Xcode*.app; do
  [ -d "$xcode" ] || continue
  developer_dir="$xcode/Contents/Developer"
  printf '\n[xcode=%s]\n' "$xcode"
  DEVELOPER_DIR="$developer_dir" xcodebuild -version 2>&1 || true
  DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-version 2>&1 || true
  DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path 2>&1 || true
  DEVELOPER_DIR="$developer_dir" xcrun clang --version 2>&1 || true
done

printf '\n[build and runtime tools]\n'
cmake --version 2>&1 || true
ninja --version 2>&1 || true
node --version 2>&1 || true
npm --version 2>&1 || true
python3 --version 2>&1 || true
ffmpeg -version 2>&1 | sed -n '1,4p'
ffprobe -version 2>&1 | sed -n '1,2p'
pkg-config --version 2>&1 || true
pkg-config --modversion libavformat libavcodec libavutil libswresample 2>&1 || true

printf '\n[input hashes and modes]\n'
shasum -a 256 inputs/Medal-production-2637.461.1-Setup.exe inputs/v2638.2751.1.zip
stat -f '%N mode=%Sp size=%z' inputs/Medal-production-2637.461.1-Setup.exe inputs/v2638.2751.1.zip

