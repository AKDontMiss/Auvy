cmake_minimum_required(VERSION 3.22.1)

project("native_dsp")

# Compile raw uncompressed frame transformation matrices into a shared runtime module
add_library(
    native_dsp
    SHARED
    ../../native_dsp.cpp
)

# Bind structural mathematical logging targets
find_library(
    log-lib
    log
)

target_link_libraries(
    native_dsp
    ${log-lib}
)

# 16 KB page-size support (Android 15+ / arm64, x86_64).
# Devices with 16 KB memory pages cannot load shared libraries whose LOAD
# segments are only 4 KB-aligned. Force the linker to align segments to 16 KB so
# this native library loads on 16 KB-page devices. Works on NDK r23+ (current
# toolchain). Both flags are needed: max-page-size aligns segments, and
# common-page-size keeps the in-file layout compact at the same boundary.
target_link_options(
    native_dsp
    PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384"
)