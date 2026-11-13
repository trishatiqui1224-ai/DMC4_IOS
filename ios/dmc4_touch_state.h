#pragma once

#include <atomic>
#include <cstdint>

namespace dmc4::touch {

struct TouchGamepadState {
  std::atomic<uint16_t> buttons{0};
  std::atomic<uint8_t> left_trigger{0};
  std::atomic<uint8_t> right_trigger{0};
  std::atomic<int16_t> thumb_lx{0};
  std::atomic<int16_t> thumb_ly{0};
  std::atomic<int16_t> thumb_rx{0};
  std::atomic<int16_t> thumb_ry{0};
  std::atomic<uint32_t> packet_number{1};
  std::atomic<bool> is_active{true};
};

TouchGamepadState& GetSharedTouchGamepad();

void ResetTouchGamepad();
void SetButton(uint16_t button_mask, bool pressed);
void SetLeftTrigger(uint8_t value);
void SetRightTrigger(uint8_t value);
void SetLeftThumb(int16_t x, int16_t y);
void SetRightThumb(int16_t x, int16_t y);
void SetHapticFeedback(uint8_t style);
uint8_t ConsumeHapticFeedback();
void SetHapticsEnabled(bool enabled);
bool IsHapticsEnabled();

}  // namespace dmc4::touch

