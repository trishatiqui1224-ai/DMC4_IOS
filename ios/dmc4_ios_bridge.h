#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Dmc4IosLaunchConfig {
  const char* game_path;
  const char* user_data_dir;
  const char* cache_dir;
  int32_t resolution_scale;
  int32_t frame_rate;
  float master_volume;
  bool mute_audio;
  bool touch_controls;
  bool controller_vibration;
} Dmc4IosLaunchConfig;

bool dmc4_ios_runtime_available(void);
bool dmc4_ios_launch(const Dmc4IosLaunchConfig* config, char* error_buf, int32_t error_buf_size);

#ifdef __cplusplus
}
#endif

