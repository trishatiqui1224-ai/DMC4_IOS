#include "dmc4_touch_state.h"

namespace dmc4::touch {

static TouchGamepadState g_touch_state;
static std::atomic<uint8_t> g_pending_haptic{0};

TouchGamepadState& GetSharedTouchGamepad() {
  return g_touch_state;
}

void ResetTouchGamepad() {
  g_touch_state.buttons.store(0, std::memory_order_relaxed);
  g_touch_state.left_trigger.store(0, std::memory_order_relaxed);
  g_touch_state.right_trigger.store(0, std::memory_order_relaxed);
  g_touch_state.thumb_lx.store(0, std::memory_order_relaxed);
  g_touch_state.thumb_ly.store(0, std::memory_order_relaxed);
  g_touch_state.thumb_rx.store(0, std::memory_order_relaxed);
  g_touch_state.thumb_ry.store(0, std::memory_order_relaxed);
  g_touch_state.packet_number.fetch_add(1, std::memory_order_relaxed);
}

void SetButton(uint16_t button_mask, bool pressed) {
  uint16_t current = g_touch_state.buttons.load(std::memory_order_relaxed);
  uint16_t updated = pressed ? (current | button_mask) : (current & ~button_mask);
  if (current != updated) {
    g_touch_state.buttons.store(updated, std::memory_order_relaxed);
    g_touch_state.packet_number.fetch_add(1, std::memory_order_relaxed);
  }
}

void SetLeftTrigger(uint8_t value) {
  uint8_t current = g_touch_state.left_trigger.load(std::memory_order_relaxed);
  if (current != value) {
    g_touch_state.left_trigger.store(value, std::memory_order_relaxed);
    g_touch_state.packet_number.fetch_add(1, std::memory_order_relaxed);
  }
}

void SetRightTrigger(uint8_t value) {
  uint8_t current = g_touch_state.right_trigger.load(std::memory_order_relaxed);
  if (current != value) {
    g_touch_state.right_trigger.store(value, std::memory_order_relaxed);
    g_touch_state.packet_number.fetch_add(1, std::memory_order_relaxed);
  }
}

void SetLeftThumb(int16_t x, int16_t y) {
  g_touch_state.thumb_lx.store(x, std::memory_order_relaxed);
  g_touch_state.thumb_ly.store(y, std::memory_order_relaxed);
  g_touch_state.packet_number.fetch_add(1, std::memory_order_relaxed);
}

void SetRightThumb(int16_t x, int16_t y) {
  g_touch_state.thumb_rx.store(x, std::memory_order_relaxed);
  g_touch_state.thumb_ry.store(y, std::memory_order_relaxed);
  g_touch_state.packet_number.fetch_add(1, std::memory_order_relaxed);
}

void SetHapticFeedback(uint8_t style) {
  g_pending_haptic.store(style, std::memory_order_relaxed);
}

uint8_t ConsumeHapticFeedback() {
  return g_pending_haptic.exchange(0, std::memory_order_relaxed);
}

}  // namespace dmc4::touch
