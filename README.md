# Devil May Cry 4 for iOS

This repository contains the iOS launcher/bridge and ReXGlue `0.10.1` configuration for the original Xbox 360 release (`Title ID: 434307DF`, `Media ID: 6729D527`).

- **Windows desktop target (`DMC4_DESKTOP_BOOT=ON`):** builds `dmc4.exe` from `src/main.cpp` and `build/recompiled/`.
- **iOS target (`ios` / `ios-sim` presets):** builds the `DMC4` app bundle combining the SwiftUI launcher (`ios/Launcher.swift`, `ios/GameFiles.swift`), ObjC++ ReXGlue bridge (`ios/dmc4_ios_bridge.mm`), static ReXGlue + `rexgpu-xenos` Vulkan/MoltenVK libraries (`tools/ios/rexglue-ios.patch`), and `build/recompiled/` when generated. Without `build/recompiled/`, it builds the launcher/bridge with **Play** disabled cleanly.

## Xbox 360 recompilation

From the project root, using the official ReXGlue 0.10.1 Windows release:

```powershell
.\build\rexglue\win-amd64\bin\rexglue.exe codegen dmc4_manifest.toml
```

The manifest targets the extracted USA/Europe copy in this workspace. For another dump, update `game_root` and `file_path` to point to its extracted files. The current title ID is `434307DF`, media ID `6729D527`. Generated C++ goes into `build/recompiled`.

The manifest registers indirect guest entry points found in Windows boot tests. It specifies the full startup dispatcher at `0x822D9BD0` so ReXGlue keeps its branch targets together. The Windows boot target builds with the ReXGlue SDK and loads the XEX. Note: iOS runtime linking, MoltenVK compilation, and device execution require macOS/Xcode (`iphoneos` / `iphonesimulator`) and are tested via [`.github/workflows/build-ios.yml`](.github/workflows/build-ios.yml).

## Desktop boot target

Run from a Visual Studio x64 developer shell with Clang and Ninja installed.

```powershell
cmake -S . -B build/desktop -G Ninja -DDMC4_DESKTOP_BOOT=ON -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_PREFIX_PATH=build/rexglue/win-amd64 -DCMAKE_BUILD_TYPE=Release
cmake --build build/desktop
```

Launch `build/desktop/dmc4.exe` with `--gpu_plugin xenos` and `--game_data_root` pointing to the extracted Xbox 360 game directory. Use `--log_file`, `--user_data_root` and `--cache_root` to write diagnostics and runtime data inside your project. Pass `--dmc4_no_shader_cache` to bypass the persistent shader-cache initialization crash during boot tests.

## Shader tools

```powershell
python tools/verify_shaders.py "<game directory>/nativeXenon/system/shader.arc" --extract build/shaders/xenos --extract-ucode build/shaders/ucode
python tools/verify_shaders.py "<game directory>/nativeXenon/system/shader.arc" --compare-dumps build/desktop/shader-dumps
python tools/compile_shaders.py build/shaders/xenos build/shaders/spirv --translator "<XenosRecomp.exe>" --header "<shader_common.h>" --dxc "<dxc.exe>"
```

Use the Windows x64 ReXGlue 0.10.1 SDK for the LZX verifier. The verifier decodes all 26 XFB bundles across their sections and extracts 1,999 unique vertex and pixel shader containers (`497` vertex, `1,502` pixel) plus 1,883 unique raw microcode streams (`435` vertex `.vs`, `1,448` pixel `.ps`) for a direct translator such as ReXGlue/Xenia's Xenos shader translator. `--compare-dumps` checks captured runtime `.ucode.bin.{vert,frag}` dumps against `shader.arc` (matching exact pixel shaders, `vfetch`-patched vertex shaders, and optionally an unpacked XEX via `--xex`). `compile_shaders.py` translates containers with [XenosRecomp](https://github.com/hedge-dev/XenosRecomp) and DXC as offline test outputs; the game still needs runtime pipeline bindings and Metal/MoltenVK validation on iOS.

The launcher uses the [Special Edition cover artwork](https://en.wikipedia.org/wiki/File:DevilMayCry4SpecialEdCover.jpg) as its app icon.

## Build for iOS (macOS + Xcode 16+)

1. Prepare the patched ReXGlue `0.10.1` (`bd833a2`) SDK tree and build dynamic `MoltenVK.xcframework`:

```sh
python3 tools/ios/prepare_rexglue.py --build-moltenvk both
```

2. Configure and build for Simulator (`ios-sim`) or physical device (`ios`):

```sh
cmake --preset ios-sim -DREXSDK_DIR="$(pwd)/build/rexglue-source"
cmake --build build/ios-sim --config Debug --target DMC4 -- CODE_SIGNING_ALLOWED=NO

cmake --preset ios -DREXSDK_DIR="$(pwd)/build/rexglue-source"
cmake --build build/ios --config Release --target DMC4
```

To compile with the recompiled game code (`DMC4_IOS_HAS_RUNTIME=1`), place the `rexglue codegen dmc4_manifest.toml` output under `build/recompiled/` before configuring. For physical devices, open `build/ios/DMC4.xcodeproj`, select the `DMC4` scheme, and configure code signing with `ios/dmc4.entitlements`.

## Game files

Use **Import from Files** to copy either a supported Xbox 360 XDVDFS ISO or a folder containing the extracted game. You can also copy it straight to **On My iPhone → Devil May Cry 4** in Files and tap **Scan app folder**. The launcher checks the title ID in `default.xex` and looks for `nativeXenon/system/shader.arc`. It reads ISO metadata directly, so the ISO can stay intact without creating a second extracted copy. Validation checks these required files and does not establish that every game asset is present.

Imported files use app storage. Copying an ISO or extracted folder from another Files location needs space for the copy. Graphics (`resolutionScale`, `frameRate`), audio (`masterVolume`, `muteAudio`), and `controllerVibration` preferences are applied via CVar/audio settings on launch when `build/recompiled/` is bundled; `touchControls` preference is persisted alongside `GameController` (MFi/Bluetooth controller) support.

The XDVDFS volume offsets follow the [Xenia disc image reader](https://github.com/xenia-project/xenia/blob/master/src/xenia/vfs/devices/disc_image_device.cc).
