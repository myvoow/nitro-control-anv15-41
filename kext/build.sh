#!/bin/sh
# Builds NitroWMI.kext with the Command Line Tools (no Xcode needed).
set -e
cd "$(dirname "$0")"
SDK=${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}
K=$SDK/System/Library/Frameworks/Kernel.framework
B=../build/kext
OUT=../build/NitroWMI.kext
rm -rf $B $OUT; mkdir -p $B $OUT/Contents/MacOS

CF="-target x86_64-apple-macos10.15 -isysroot $SDK -mkernel -fapple-kext -fno-builtin -fno-rtti -fno-exceptions \
 -nostdinc -nostdinc++ -I$K/Headers -I$K/Headers/libkern -I../Sources/CNitroWMI/include \
 -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
 -O2 -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-deprecated-declarations"
clang++ -std=gnu++17 $CF -c src/NitroWMI.cpp -o $B/NitroWMI.o
clang   $CF -c src/kmod_info.c -o $B/kmod_info.o

clang++ -target x86_64-apple-macos10.15 -isysroot $SDK -nostdlib -Xlinker -kext \
  $B/NitroWMI.o $B/kmod_info.o \
  -L$SDK/usr/lib -lkmodc++ -lkmod -o $OUT/Contents/MacOS/NitroWMI
cp Info.plist $OUT/Contents/Info.plist
codesign -f -s - $OUT
file $OUT/Contents/MacOS/NitroWMI
