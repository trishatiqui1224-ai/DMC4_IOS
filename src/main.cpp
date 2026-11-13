#include "dmc4_init.h"

#include <rex/platform.h>
#include <rex/rex_app.h>
#include <rex/cvar.h>

#if REX_PLATFORM_IOS
#include <algorithm>
#include <filesystem>
#include <string>

#include <rex/audio/downmix.h>
#include <rex/filesystem.h>
#include <rex/graphics/vulkan/graphics_system.h>
#include <rex/input/input_system.h>

#include "dmc4_ios_runtime.h"
#include "dmc4_touch_driver.h"
#endif

REXCVAR_DEFINE_BOOL(dmc4_no_shader_cache, false, "DMC4",
                   "Disable the persistent shader cache for boot diagnostics");

REXCVAR_DEFINE_STRING(dmc4_shader_dump_dir, "", "DMC4",
                     "Directory for Xenos shader dumps during desktop diagnostics");

namespace {

class Dmc4App final : public rex::ReXApp {
 public:
  explicit Dmc4App(rex::ui::WindowedAppContext& context)
      : ReXApp(context, "dmc4", PPCImageConfig) {}

  void OnConfigurePaths(rex::PathConfig& paths) override {
#if REX_PLATFORM_IOS
    const auto opts = dmc4::ios::GetLaunchOptions();
    if (!opts.game_path.empty()) {
      paths.game_data_root = opts.game_path;
    }
    if (!opts.user_data_dir.empty()) {
      paths.user_data_root = opts.user_data_dir;
      paths.config_path = std::filesystem::path(opts.user_data_dir) / "dmc4.toml";
    }
    if (!opts.cache_dir.empty()) {
      paths.cache_root = opts.cache_dir;
    }
#endif
    if (REXCVAR_GET(dmc4_no_shader_cache)) {
      paths.cache_root.clear();
    }
  }

#if REX_PLATFORM_IOS
  void OnConfigureLogging(rex::LogConfig& config) override {
    const auto opts = dmc4::ios::GetLaunchOptions();
    if (!opts.documents_dir.empty()) {
      config.log_dir = std::filesystem::path(opts.documents_dir) / "logs";
    } else if (!opts.cache_dir.empty()) {
      config.log_dir = std::filesystem::path(opts.cache_dir) / "logs";
    } else if (!opts.user_data_dir.empty()) {
      config.log_dir = std::filesystem::path(opts.user_data_dir) / "logs";
    } else {
      config.log_dir = rex::filesystem::GetUserFolder() / "dmc4" / "logs";
    }

    // Immediate flush so crash logs on iOS are never lost in RAM buffers
    config.flush_level = spdlog::level::trace;
    if (opts.debug_logging) {
      config.default_level = spdlog::level::debug;
    }
  }

  void OnPreSetup(rex::RuntimeConfig& config) override {
    const auto opts = dmc4::ios::GetLaunchOptions();
    const std::string scale = std::to_string(std::clamp(opts.resolution_scale, int32_t(1), int32_t(8)));
    rex::cvar::SetFlagByName("resolution_scale", scale);
    rex::cvar::SetFlagByName("draw_resolution_scale_x", scale);
    rex::cvar::SetFlagByName("draw_resolution_scale_y", scale);
    rex::cvar::SetFlagByName("vsync", opts.frame_rate >= 120 ? "false" : "true");
    rex::cvar::SetFlagByName("audio_mute", opts.mute_audio ? "true" : "false");
    rex::audio::SetOutputGain(std::clamp(opts.master_volume, 0.0f, 1.0f));
    rex::cvar::SetFlagByName("vibration", opts.controller_vibration ? "true" : "false");

    // Performance optimizations for Apple Silicon / iOS
    rex::cvar::SetFlagByName("native_2x_msaa", opts.msaa ? "true" : "false");
    rex::cvar::SetFlagByName("async_shader_compilation", "true");
    rex::cvar::SetFlagByName("readback_memexport_fast", "true");
    rex::cvar::SetFlagByName("readback_resolve", "none");
    rex::cvar::SetFlagByName("vulkan_sparse_shared_memory", "true");
    rex::cvar::SetFlagByName("vulkan_dynamic_rendering", "true");

    // Automatically resolve Xbox 360 system dialogs (storage prompt, profile, etc.)
    // on iOS since modal ImGui dialogs cannot receive touch/controller input on mobile.
    rex::cvar::SetFlagByName("headless", "true");

    if (opts.debug_logging) {
      rex::cvar::SetFlagByName("log_level", "debug");
      rex::cvar::SetFlagByName("log_verbose", "true");
    }

    if (!config.graphics) {
      config.graphics = std::make_unique<rex::graphics::vulkan::VulkanGraphicsSystem>();
    }

    auto orig_input_factory = std::move(config.input_factory);
    config.input_factory = [orig = std::move(orig_input_factory)](bool tool_mode) {
      std::unique_ptr<rex::input::InputSystem> input;
      if (orig) {
        input = std::unique_ptr<rex::input::InputSystem>(
            static_cast<rex::input::InputSystem*>(orig(tool_mode).release()));
      } else {
        input = rex::input::CreateDefaultInputSystem(tool_mode);
      }
      if (input) {
        input->AddDriver(std::make_unique<dmc4::input::Dmc4TouchInputDriver>(nullptr, 0));
        REXLOG_INFO("[DMC4 Input] Registered Dmc4TouchInputDriver for iOS on-screen controls");
      }
      return input;
    };
  }
#endif

  void OnPostSetup() override {
    const auto& directory = REXCVAR_GET(dmc4_shader_dump_dir);
    if (!directory.empty() && !rex::cvar::SetFlagByName("dump_shaders", directory)) {
      REXLOG_WARN("The active GPU plugin does not expose shader dumping.");
    }
  }

  static std::unique_ptr<rex::ui::WindowedApp> Create(rex::ui::WindowedAppContext& context) {
    return std::make_unique<Dmc4App>(context);
  }
};

}  // namespace

REX_DEFINE_APP(dmc4, Dmc4App::Create)

