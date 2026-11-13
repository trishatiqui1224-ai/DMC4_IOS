#pragma once

#include <cstdint>
#include <string>

namespace dmc4::ios {

struct RuntimeLaunchOptions {
  std::string game_path;
  std::string user_data_dir;
  std::string cache_dir;
  std::string documents_dir;
  int32_t resolution_scale = 1;
  int32_t frame_rate = 60;
  float master_volume = 1.0f;
  bool mute_audio = false;
  bool touch_controls = true;
  bool touch_haptics = true;
  bool controller_vibration = true;
  bool debug_logging = false;
  bool msaa = true;
};

void SetLaunchOptions(const RuntimeLaunchOptions& options);
RuntimeLaunchOptions GetLaunchOptions();

}  // namespace dmc4::ios
