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
  const char* documents_dir;
  int32_t resolution_scale;
  int32_t frame_rate;
  float master_volume;
  bool mute_audio;
  bool touch_controls;
  bool touch_haptics;
  bool controller_vibration;
  bool debug_logging;
  bool msaa;
} Dmc4IosLaunchConfig;

bool dmc4_ios_runtime_available(void);
bool dmc4_ios_launch(const Dmc4IosLaunchConfig* config, char* error_buf, int32_t error_buf_size);
void dmc4_ios_set_touch_controls_enabled(bool enabled);
bool dmc4_ios_is_virtual_controller_active(void);
void dmc4_ios_set_touch_haptics_enabled(bool enabled);
bool dmc4_ios_is_touch_haptics_enabled(void);
void dmc4_ios_request_landscape(void);

#ifdef __cplusplus
}
#endif

