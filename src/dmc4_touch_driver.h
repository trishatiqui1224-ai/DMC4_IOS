#pragma once

#include <cstring>
#include <vector>

#include <rex/input/device.h>
#include <rex/input/input.h>
#include <rex/input/input_driver.h>
#include <rex/system/xtypes.h>

#include "../ios/dmc4_touch_state.h"

namespace rex::input {

class Dmc4TouchInputDriver final : public InputDriver {
 public:
  explicit Dmc4TouchInputDriver(rex::ui::Window* window, size_t window_z_order)
      : InputDriver(window, window_z_order) {}

  ~Dmc4TouchInputDriver() override = default;

  X_STATUS Setup() override {
    return X_STATUS_SUCCESS;
  }

  void EnumerateDevices(std::vector<DeviceInfo>& out) override {
    DeviceInfo info;
    info.id = DeviceId(9001);
    info.ordinal = 0;
    info.name = "DMC4 iOS Touch Screen Controller";
    info.guid = "dmc4_touch_screen";
    info.subtype = 0x01;   // XINPUT_DEVSUBTYPE_GAMEPAD
    info.synthetic = true;  // Synthetics feed guest user 0 (Player 1)
    out.push_back(info);
  }

  X_RESULT GetDeviceState(DeviceId id, X_INPUT_STATE* out_state) override {
    (void)id;
    if (!out_state) return X_ERROR_BAD_ARGUMENTS;

    auto& state = dmc4::touch::GetSharedTouchGamepad();
    out_state->packet_number = state.packet_number.load(std::memory_order_relaxed);
    out_state->gamepad.buttons = state.buttons.load(std::memory_order_relaxed);
    out_state->gamepad.left_trigger = state.left_trigger.load(std::memory_order_relaxed);
    out_state->gamepad.right_trigger = state.right_trigger.load(std::memory_order_relaxed);
    out_state->gamepad.thumb_lx = state.thumb_lx.load(std::memory_order_relaxed);
    out_state->gamepad.thumb_ly = state.thumb_ly.load(std::memory_order_relaxed);
    out_state->gamepad.thumb_rx = state.thumb_rx.load(std::memory_order_relaxed);
    out_state->gamepad.thumb_ry = state.thumb_ry.load(std::memory_order_relaxed);

    return X_ERROR_SUCCESS;
  }

  X_RESULT GetDeviceCapabilities(DeviceId id, uint32_t flags,
                                 X_INPUT_CAPABILITIES* out_caps) override {
    (void)id;
    (void)flags;
    if (!out_caps) return X_ERROR_BAD_ARGUMENTS;
    std::memset(out_caps, 0, sizeof(*out_caps));
    out_caps->type = 0x01;       // XINPUT_DEVTYPE_GAMEPAD
    out_caps->sub_type = 0x01;   // XINPUT_DEVSUBTYPE_GAMEPAD
    out_caps->flags = 0;
    out_caps->gamepad.buttons = 0xFFFF;
    out_caps->gamepad.left_trigger = 255;
    out_caps->gamepad.right_trigger = 255;
    out_caps->gamepad.thumb_lx = 32767;
    out_caps->gamepad.thumb_ly = 32767;
    out_caps->gamepad.thumb_rx = 32767;
    out_caps->gamepad.thumb_ry = 32767;
    return X_ERROR_SUCCESS;
  }

  X_RESULT SetDeviceVibration(DeviceId id, X_INPUT_VIBRATION* vibration) override {
    (void)id;
    if (vibration) {
      if (vibration->left_motor_speed > 30000 || vibration->right_motor_speed > 30000) {
        dmc4::touch::SetHapticFeedback(3);  // heavy
      } else if (vibration->left_motor_speed > 10000 || vibration->right_motor_speed > 10000) {
        dmc4::touch::SetHapticFeedback(2);  // medium
      } else if (vibration->left_motor_speed > 0 || vibration->right_motor_speed > 0) {
        dmc4::touch::SetHapticFeedback(1);  // light
      }
    }
    return X_ERROR_SUCCESS;
  }

  X_RESULT GetDeviceKeystroke(DeviceId id, uint32_t flags,
                              X_INPUT_KEYSTROKE* out_keystroke) override {
    (void)id;
    (void)flags;
    (void)out_keystroke;
    return X_ERROR_EMPTY;
  }
};

}  // namespace rex::input

namespace dmc4::input {
using Dmc4TouchInputDriver = rex::input::Dmc4TouchInputDriver;
}
