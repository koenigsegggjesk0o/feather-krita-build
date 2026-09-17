# SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# CMakeLists.txt — Build config for the krita_bridge native library.
#
# Builds the `krita_bridge` shared library (.dll / .so / .dylib) that
# Flutter loads via dart:ffi. The library links against Krita's brush
# engine, Qt6, and the rest of the Krita libraries needed to drive
# KisPaintOp / KisPainter / KisPaintDevice.
#
# Usage from the project root:
#
#   cmake -S native/cmake -B build/native \
#         -DCMAKE_BUILD_TYPE=Release \
#         -DKRITA_SOURCE_DIR=/path/to/krita-source \
#         -DKRITA_BUILD_DIR=/path/to/krita-build
#   cmake --build build/native --config Release
#
# The output library is placed under `build/native/<config>/` and the
# Flutter app's loader code (see `lib/ffi/krita_bindings.dart`) finds it
# either from the system PATH (Windows) or via rpath (Linux/macOS).

cmake_minimum_required(VERSION 3.22)

project(feather_krita_bridge
    VERSION 1.0.0
    LANGUAGES CXX
    DESCRIPTION "FFI bridge between Flutter and the Krita brush engine")

# ---------------------------------------------------------------------------
# Build options.
# ---------------------------------------------------------------------------

option(FEATHER_BUILD_TESTS "Build the bridge unit tests" OFF)
option(FEATHER_STATIC_KRITA "Link Krita statically (advanced)" OFF)

# Path to the Krita source tree. The build needs access to:
#   - krita-source/libs/brush/    (KisBrush, KisBrushServer, ...)
#   - krita-source/libs/image/    (KisPaintDevice, KisPainter, ...)
#   - krita-source/libs/pigment/  (KoColorSpace, KoColor, ...)
#   - krita-source/libs/ui/       (KisPaintOpPreset, KisResourcesInterface)
set(KRITA_SOURCE_DIR "" CACHE PATH
    "Path to the Krita source tree (e.g. /path/to/krita-source)")

# Path to a configured Krita build tree. Required so CMake can find the
# generated headers (e.g. libs/global/kritaversion.h) and the .lib / .so
# files produced by Krita's own build.
set(KRITA_BUILD_DIR "" CACHE PATH
    "Path to a configured Krita build tree (e.g. /path/to/krita-build)")

# Output directory for the built shared library. Defaults to
# `${CMAKE_BINARY_DIR}/output`.
set(FEATHER_OUTPUT_DIR "${CMAKE_BINARY_DIR}/output"
    CACHE PATH "Where to place the built krita_bridge library")

# ---------------------------------------------------------------------------
# C++ standard & policies.
# ---------------------------------------------------------------------------

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Position-independent code is required for shared libraries.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# On Windows, export symbols via __declspec(dllexport) implicitly by
# building the bridge as a SHARED library; no extra export macro needed
# because the entire API is `extern "C"`.
if(WIN32)
    set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
endif()

# ---------------------------------------------------------------------------
# Validate Krita paths.
# ---------------------------------------------------------------------------

if(NOT KRITA_SOURCE_DIR OR NOT EXISTS "${KRITA_SOURCE_DIR}/libs")
    message(FATAL_ERROR
        "KRITA_SOURCE_DIR must point to the root of a Krita source tree "
        "containing a 'libs' directory. Got: '${KRITA_SOURCE_DIR}'")
endif()

if(NOT KRITA_BUILD_DIR OR NOT EXISTS "${KRITA_BUILD_DIR}/CMakeCache.txt")
    message(WARNING
        "KRITA_BUILD_DIR is not set or does not look like a configured "
        "Krita build tree. Build will likely fail to find Krita libraries.")
endif()

# ---------------------------------------------------------------------------
# Find Qt6 — Krita depends on Qt6 so we assume it's already on the
# machine.
# ---------------------------------------------------------------------------

find_package(Qt6 REQUIRED COMPONENTS Core Gui)

# ---------------------------------------------------------------------------
# Krita include paths.
# ---------------------------------------------------------------------------

set(_krita_lib_dirs
    libs/brush
    libs/image
    libs/pigment
    libs/pigment/resources
    libs/ui
    libs/global
    libs/widgetutils
    libs/flake
    libs/odf
)

set(KRITA_INCLUDE_DIRS "")
foreach(_d ${_krita_lib_dirs})
    list(APPEND KRITA_INCLUDE_DIRS "${KRITA_SOURCE_DIR}/${_d}")
endforeach()

# Krita's build tree adds a few extra include dirs (for generated
# headers like kritaversion.h).
list(APPEND KRITA_INCLUDE_DIRS
    "${KRITA_BUILD_DIR}"
    "${KRITA_BUILD_DIR}/libs/global"
    "${KRITA_BUILD_DIR}/libs/brush"
    "${KRITA_BUILD_DIR}/libs/image"
    "${KRITA_BUILD_DIR}/libs/pigment"
    "${KRITA_BUILD_DIR}/libs/ui"
)

# Qt's include dirs come via its imported targets below.
include_directories(${KRITA_INCLUDE_DIRS})

# ---------------------------------------------------------------------------
# Krita libraries to link against.
#
# On Windows / MSVC these are typically `kritabrush.lib`, `kritaimage.lib`
# etc. On Linux / macOS they're `libkritabrush.so` / `libkritabrush.dylib`.
# CMake's `find_library` resolves the platform-specific name.
# ---------------------------------------------------------------------------

set(_krita_lib_names
    kritabrush
    kritaimage
    kritapigment
    kritaui
    kritaflake
    kritaodf
    kritawidgetutils
    kritaglobal
)

set(KRITA_LIBRARIES "")
foreach(_lib ${_krita_lib_names})
    find_library(_found_${_lib}
        NAMES ${_lib}
        PATHS
            "${KRITA_BUILD_DIR}/lib"
            "${KRITA_BUILD_DIR}/bin"
            "${KRITA_BUILD_DIR}/libs/brush"
            "${KRITA_BUILD_DIR}/libs/image"
            "${KRITA_BUILD_DIR}/libs/pigment"
            "${KRITA_BUILD_DIR}/libs/ui"
            "${KRITA_BUILD_DIR}/libs/odf"
            "${KRITA_BUILD_DIR}/libs/fluorescence"
        PATH_SUFFIXES
            ""
            "Release"
            "Debug"
            NO_DEFAULT_PATH
        NO_PACKAGE_ROOT_PATH
        NO_CMAKE_PATH
        NO_CMAKE_SYSTEM_PATH
    )
    if(_found_${_lib})
        list(APPEND KRITA_LIBRARIES ${_found_${_lib}})
        message(STATUS "Found Krita lib: ${_lib} -> ${_found_${_lib}}")
    else()
        message(WARNING "Krita lib not found: ${_lib}")
    endif()
    unset(_found_${_lib} CACHE)
endforeach()

# ---------------------------------------------------------------------------
# Bridge library target.
# ---------------------------------------------------------------------------

add_library(krita_bridge SHARED
    "${CMAKE_CURRENT_SOURCE_DIR}/../krita_bridge/krita_bridge.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../krita_bridge/krita_bridge.h"
)

target_include_directories(krita_bridge PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/../krita_bridge"
    ${KRITA_INCLUDE_DIRS}
)

target_link_libraries(krita_bridge PRIVATE
    Qt6::Core
    Qt6::Gui
    ${KRITA_LIBRARIES}
)

# On Linux / macOS we want the resulting .so / .dylib to be self-
# sufficient: rpath points to $ORIGIN so the loader finds the bundled
# Krita libs alongside the bridge.
if(UNIX AND NOT APPLE)
    set_target_properties(krita_bridge PROPERTIES
        INSTALL_RPATH "$ORIGIN"
        BUILD_WITH_INSTALL_RPATH TRUE)
elseif(APPLE)
    set_target_properties(krita_bridge PROPERTIES
        INSTALL_RPATH "@loader_path"
        BUILD_WITH_INSTALL_RPATH TRUE)
endif()

# Output naming. Flutter's loader looks for `krita_bridge.dll` /
# `libkrita_bridge.so` / `libkrita_bridge.dylib`.
set_target_properties(krita_bridge PROPERTIES
    OUTPUT_NAME "krita_bridge"
    LIBRARY_OUTPUT_DIRECTORY "${FEATHER_OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${FEATHER_OUTPUT_DIR}"
    ARCHIVE_OUTPUT_DIRECTORY "${FEATHER_OUTPUT_DIR}"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

# Multi-config generators (Visual Studio, Xcode) put each config in a
# subdirectory; we want a flat output.
foreach(_cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    string(TOUPPER "${_cfg}" _cfg_upper)
    set_target_properties(krita_bridge PROPERTIES
        "LIBRARY_OUTPUT_DIRECTORY_${_cfg_upper}" "${FEATHER_OUTPUT_DIR}"
        "RUNTIME_OUTPUT_DIRECTORY_${_cfg_upper}" "${FEATHER_OUTPUT_DIR}"
        "ARCHIVE_OUTPUT_DIRECTORY_${_cfg_upper}" "${FEATHER_OUTPUT_DIR}")
endforeach()

# ---------------------------------------------------------------------------
# Compiler warnings.
# ---------------------------------------------------------------------------

if(MSVC)
    target_compile_options(krita_bridge PRIVATE /W3 /WX- /permissive- /Zc:__cplusplus)
else()
    target_compile_options(krita_bridge PRIVATE
        -Wall -Wextra -Wpedantic -Wno-unused-parameter
        -Wno-deprecated-declarations)
endif()

# Define KRITA_VERSION_STRING so krita_brush_version() can return it.
if(EXISTS "${KRITA_BUILD_DIR}/libs/global/kritaversion.h")
    file(STRINGS "${KRITA_BUILD_DIR}/libs/global/kritaversion.h" _version_line
        REGEX "^#define KRITA_VERSION_STRING ")
    if(_version_line)
        string(REGEX REPLACE "^#define KRITA_VERSION_STRING \"([^\"]+)\".*$" "\\1"
            _krita_version "${_version_line}")
        target_compile_definitions(krita_bridge PRIVATE
            KRITA_VERSION_STRING="${_krita_version}")
    endif()
endif()

# ---------------------------------------------------------------------------
# Optional tests.
# ---------------------------------------------------------------------------

if(FEATHER_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# ---------------------------------------------------------------------------
# Install rules — useful when packaging the bridge for distribution.
# ---------------------------------------------------------------------------

include(GNUInstallDirs)

install(TARGETS krita_bridge
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

install(FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/../krita_bridge/krita_bridge.h"
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/feather_krita
)

# ---------------------------------------------------------------------------
# Status summary.
# ---------------------------------------------------------------------------

message(STATUS "")
message(STATUS "==== feather_krita_bridge configuration ====")
message(STATUS "  C++ standard:       ${CMAKE_CXX_STANDARD}")
message(STATUS "  Build type:         ${CMAKE_BUILD_TYPE}")
message(STATUS "  Krita source:       ${KRITA_SOURCE_DIR}")
message(STATUS "  Krita build:        ${KRITA_BUILD_DIR}")
message(STATUS "  Output dir:         ${FEATHER_OUTPUT_DIR}")
message(STATUS "  Linked Krita libs:  ${KRITA_LIBRARIES}")
message(STATUS "============================================")
message(STATUS "")
