cmake_minimum_required(VERSION 3.25)
option(DMC4_DESKTOP_BOOT "Build the ReXGlue desktop boot target" OFF)
if(DMC4_DESKTOP_BOOT)
    project(dmc4 LANGUAGES CXX)
    set(CMAKE_CXX_STANDARD 23)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    include(generated/rexglue.cmake)
    if(NOT REXGLUE_ENTRYPOINT_GENERATED_SOURCES)
        message(FATAL_ERROR "Run ReXGlue codegen before building the desktop boot target.")
    endif()
    if(WIN32)
        add_executable(dmc4 WIN32 src/main.cpp)
        if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
            target_sources(dmc4 PRIVATE src/windows_math.cpp)
        endif()
    else()
        add_executable(dmc4 src/main.cpp)
    endif()
    rexglue_setup_target(dmc4 GPU_PLUGINS xenos)
    return()
endif()

project(DMC4 LANGUAGES C CXX OBJCXX Swift)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 23)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(REXSDK_DIR "" CACHE PATH "Path to rexglue-sdk source tree")
set(DMC4_MOLTENVK_XCFRAMEWORK "" CACHE PATH "Path to MoltenVK.xcframework (optional)")

if(NOT REXSDK_DIR AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/build/rexglue-source/CMakeLists.txt")
    set(REXSDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/build/rexglue-source")
endif()

set(_dmc4_has_rexglue OFF)
if(REXSDK_DIR)
    set(REXGLUE_BUILD_CODEGEN_TOOL OFF CACHE BOOL "" FORCE)
    set(REXGLUE_ENABLE_FIDELITYFX OFF CACHE BOOL "" FORCE)
    add_subdirectory("${REXSDK_DIR}" rexglue-sdk)
    set(_dmc4_has_rexglue ON)
    message(STATUS "Using ReXGlue SDK from source tree for iOS: ${REXSDK_DIR}")
else()
    find_package(rexglue 0.10.1 QUIET CONFIG)
    if(rexglue_FOUND)
        set(_dmc4_has_rexglue ON)
        message(STATUS "Found installed ReXGlue SDK for iOS: ${rexglue_DIR}")
    endif()
endif()

set(app_assets ios/Assets.xcassets)
set_source_files_properties(${app_assets} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

add_executable(DMC4 MACOSX_BUNDLE
    ios/Launcher.swift
    ios/GameFiles.swift
    ios/dmc4_ios_bridge.mm
    ${app_assets}
)

set(_dmc4_has_runtime OFF)
if(_dmc4_has_rexglue AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/build/recompiled/sources.cmake")
    include("${CMAKE_CURRENT_SOURCE_DIR}/build/recompiled/sources.cmake")
    set(_dmc4_recomp_include_dir "${CMAKE_CURRENT_SOURCE_DIR}/build/recompiled")
    # Ensure iOS ARM64 16KB host page offsets match Memory::PhysicalHostOffset even
    # when build/recompiled/dmc4_pch.h was emitted by stock desktop rexglue 0.10.1.
    file(READ "${_dmc4_recomp_include_dir}/dmc4_pch.h" _dmc4_pch_text)
    string(REPLACE
        "REX_PLATFORM_WIN32 || (REX_PLATFORM_MAC && REX_ARCH_ARM64)"
        "REX_PLATFORM_WIN32 || (REX_PLATFORM_APPLE && REX_ARCH_ARM64)"
        _dmc4_pch_patched "${_dmc4_pch_text}")
    if(NOT _dmc4_pch_patched STREQUAL "${_dmc4_pch_text}")
        file(WRITE "${_dmc4_recomp_include_dir}/dmc4_pch.h" "${_dmc4_pch_patched}")
    endif()
    set(_dmc4_recomp_options -gline-tables-only)
    set_source_files_properties(${GENERATED_SOURCES}
        PROPERTIES COMPILE_OPTIONS "${_dmc4_recomp_options}"
    )

    add_library(DMC4_recomp OBJECT ${GENERATED_SOURCES})
    target_include_directories(DMC4_recomp PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
        "${_dmc4_recomp_include_dir}"
    )
    target_link_libraries(DMC4_recomp PRIVATE rex::runtime)
    rexglue_apply_target_settings(DMC4_recomp)
    target_precompile_headers(DMC4_recomp PRIVATE "${_dmc4_recomp_include_dir}/dmc4_pch.h")
    target_compile_options(DMC4_recomp PRIVATE ${_dmc4_recomp_options})

    target_sources(DMC4 PRIVATE src/main.cpp)
    target_include_directories(DMC4 PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
        "${_dmc4_recomp_include_dir}"
    )
    target_link_libraries(DMC4 PRIVATE DMC4_recomp rex::runtime)
    rexglue_configure_target(DMC4 NO_SDL_MAIN GPU_PLUGINS xenos)
    target_compile_definitions(DMC4 PRIVATE DMC4_IOS_HAS_RUNTIME=1)
    set(_dmc4_has_runtime ON)
elseif(_dmc4_has_rexglue)
    target_link_libraries(DMC4 PRIVATE rex::runtime)
    rexglue_configure_target(DMC4 NO_SDL_MAIN GPU_PLUGINS xenos)
    target_compile_definitions(DMC4 PRIVATE DMC4_IOS_HAS_RUNTIME=0)
else()
    target_compile_definitions(DMC4 PRIVATE DMC4_IOS_HAS_RUNTIME=0)
endif()

set(_dmc4_mvk_slice "ios-arm64")
if(CMAKE_OSX_SYSROOT MATCHES "iphonesimulator")
    set(_dmc4_mvk_slice "ios-arm64_x86_64-simulator")
endif()

set(_dmc4_mvk_candidates)
if(DMC4_MOLTENVK_XCFRAMEWORK)
    list(APPEND _dmc4_mvk_candidates
        "${DMC4_MOLTENVK_XCFRAMEWORK}/${_dmc4_mvk_slice}/MoltenVK.framework"
        "${DMC4_MOLTENVK_XCFRAMEWORK}/MoltenVK.framework"
        "${DMC4_MOLTENVK_XCFRAMEWORK}"
    )
endif()
list(APPEND _dmc4_mvk_candidates
    "${CMAKE_CURRENT_SOURCE_DIR}/build/moltenvk/MoltenVK.xcframework/${_dmc4_mvk_slice}/MoltenVK.framework"
)
if(REXSDK_DIR)
    list(APPEND _dmc4_mvk_candidates
        "${REXSDK_DIR}/thirdparty/moltenvk/Package/Latest/MoltenVK/dynamic/MoltenVK.xcframework/${_dmc4_mvk_slice}/MoltenVK.framework"
        "${REXSDK_DIR}/thirdparty/moltenvk/Package/Release/MoltenVK/dynamic/MoltenVK.xcframework/${_dmc4_mvk_slice}/MoltenVK.framework"
    )
endif()

set(_dmc4_mvk_framework "")
foreach(_cand IN LISTS _dmc4_mvk_candidates)
    if(EXISTS "${_cand}/Info.plist" OR EXISTS "${_cand}/MoltenVK")
        set(_dmc4_mvk_framework "${_cand}")
        break()
    endif()
endforeach()

if(_dmc4_mvk_framework)
    message(STATUS "Embedding MoltenVK framework for iOS: ${_dmc4_mvk_framework}")
    set_target_properties(DMC4 PROPERTIES
        XCODE_EMBED_FRAMEWORKS "${_dmc4_mvk_framework}"
        XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY ON
    )
elseif(_dmc4_has_rexglue)
    message(WARNING "MoltenVK.framework not found for slice ${_dmc4_mvk_slice}; set DMC4_MOLTENVK_XCFRAMEWORK or run tools/ios/prepare_rexglue.py --build-moltenvk")
endif()

set_target_properties(DMC4 PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist"
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.dmc4recomp.launcher"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/ios/dmc4_ios_bridge.h"
    XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES YES
    XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY "libc++"
    XCODE_ATTRIBUTE_ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES YES
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)

if(NOT CMAKE_OSX_SYSROOT MATCHES "iphonesimulator")
    set_target_properties(DMC4 PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/ios/dmc4.entitlements"
    )
endif()

message(STATUS "DMC4 iOS configuration: ReXGlue=${_dmc4_has_rexglue}, RecompiledRuntime=${_dmc4_has_runtime}")
