#!/bin/bash
# Build AutoClicker.dylib (arm64) on macOS with Xcode command line tools. No Theos needed.
set -e
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -framework UIKit -framework Foundation \
  -install_name @executable_path/Frameworks/AutoClicker.dylib \
  -o AutoClicker.dylib AutoClicker.m
codesign -f -s - AutoClicker.dylib   # ad-hoc; your sideload tool re-signs it anyway
echo "Built AutoClicker.dylib"
