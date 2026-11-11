#import <Foundation/Foundation.h>

#include "dmc4_ios_bridge.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

#ifndef DMC4_IOS_HAS_RUNTIME
#define DMC4_IOS_HAS_RUNTIME 0
#endif

#if DMC4_IOS_HAS_RUNTIME
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include <mutex>
#include <system_error>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ui/windowed_app.h>
#include <rex/ui/windowed_app_context_sdl.h>

#include "../src/dmc4_ios_runtime.h"
#endif

namespace {

void WriteError(char* error_buf, int32_t error_buf_size, const char* message) {
  if (!error_buf || error_buf_size <= 0) {
    return;
  }
  if (!message) {
    error_buf[0] = '\0';
    return;
  }
  std::snprintf(error_buf, static_cast<size_t>(error_buf_size), "%s", message);
}

#if DMC4_IOS_HAS_RUNTIME
dmc4::ios::RuntimeLaunchOptions g_ios_launch_options;
std::mutex g_ios_launch_mutex;
#endif

}  // namespace

#if DMC4_IOS_HAS_RUNTIME
namespace dmc4::ios {

void SetLaunchOptions(const RuntimeLaunchOptions& options) {
  std::lock_guard<std::mutex> lock(g_ios_launch_mutex);
  g_ios_launch_options = options;
}

RuntimeLaunchOptions GetLaunchOptions() {
  std::lock_guard<std::mutex> lock(g_ios_launch_mutex);
  return g_ios_launch_options;
}

}  // namespace dmc4::ios
#endif

extern "C" bool dmc4_ios_runtime_available(void) {
#if DMC4_IOS_HAS_RUNTIME
  return true;
#else
  return false;
#endif
}

extern "C" bool dmc4_ios_launch(const Dmc4IosLaunchConfig* config,
                                char* error_buf,
                                int32_t error_buf_size) {
#if !DMC4_IOS_HAS_RUNTIME
  (void)config;
  WriteError(error_buf, error_buf_size,
             "Recompiled DMC4 runtime sources (build/recompiled) are not included in this build.");
  return false;
#else
  if (!config || !config->game_path || config->game_path[0] == '\0') {
    WriteError(error_buf, error_buf_size, "No Xbox 360 game folder or ISO path was provided.");
    return false;
  }

  dmc4::ios::RuntimeLaunchOptions options;
  options.game_path = config->game_path;
  if (config->user_data_dir) {
    options.user_data_dir = config->user_data_dir;
  }
  if (config->cache_dir) {
    options.cache_dir = config->cache_dir;
  }
  options.resolution_scale = std::clamp(config->resolution_scale, int32_t(1), int32_t(8));
  options.frame_rate = config->frame_rate > 0 ? config->frame_rate : 60;
  options.master_volume = std::clamp(config->master_volume, 0.0f, 1.0f);
  options.mute_audio = config->mute_audio;
  options.touch_controls = config->touch_controls;
  options.controller_vibration = config->controller_vibration;

  std::error_code ec;
  if (!options.user_data_dir.empty()) {
    std::filesystem::create_directories(options.user_data_dir, ec);
  }
  if (!options.cache_dir.empty()) {
    std::filesystem::create_directories(options.cache_dir, ec);
  }

  dmc4::ios::SetLaunchOptions(options);

  static std::once_flag init_once;
  std::call_once(init_once, []() {
    char arg0[] = "DMC4";
    char* argv[] = {arg0, nullptr};
    rex::cvar::Init(1, argv);
    rex::cvar::ApplyEnvironment();
    rex::InitLoggingEarly();
    SDL_SetMainReady();
  });

  rex::ui::SDLWindowedAppContext app_context;
  if (!app_context.Initialize()) {
    WriteError(error_buf, error_buf_size, "Failed to initialize SDL3 UIKit video context.");
    return false;
  }

  auto creator = rex::ui::GetWindowedAppCreator();
  if (!creator) {
    WriteError(error_buf, error_buf_size, "DMC4 ReXApp creator is not registered.");
    return false;
  }

  std::unique_ptr<rex::ui::WindowedApp> app = creator(app_context);
  if (!app || !app->OnInitialize()) {
    if (app) {
      app->InvokeOnDestroy();
    }
    WriteError(error_buf, error_buf_size,
               "Failed to initialize DMC4 runtime or Vulkan/MoltenVK presentation.");
    return false;
  }

  const int exit_code = app_context.RunMainMessageLoop();
  app->InvokeOnDestroy();
  if (exit_code != 0) {
    WriteError(error_buf, error_buf_size, "DMC4 runtime exited with a non-zero status.");
    return false;
  }
  return true;
#endif
}
