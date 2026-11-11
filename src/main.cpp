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

#include "dmc4_ios_runtime.h"
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
    if (!opts.cache_dir.empty()) {
      config.log_dir = std::filesystem::path(opts.cache_dir) / "logs";
    } else if (!opts.user_data_dir.empty()) {
      config.log_dir = std::filesystem::path(opts.user_data_dir) / "logs";
    } else {
      config.log_dir = rex::filesystem::GetUserFolder() / "dmc4" / "logs";
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

    if (!config.graphics) {
      config.graphics = std::make_unique<rex::graphics::vulkan::VulkanGraphicsSystem>();
    }
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

