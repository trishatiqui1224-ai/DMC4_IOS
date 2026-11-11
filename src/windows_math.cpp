#include <cmath>

// Clang can emit this C23 call when lowering the guest's nearest-even rounding.
// The Windows Universal CRT used by the SDK does not provide the symbol.
extern "C" float roundevenf(float value) noexcept {
  const float magnitude = std::fabs(value);
  if (!(magnitude < 0x1p23f)) {
    return value;  // Already integral, infinite, or NaN.
  }
  const float whole = std::floor(magnitude);
  const float fraction = magnitude - whole;
  const bool odd = (static_cast<unsigned>(whole) & 1U) != 0;
  const float result = fraction > 0.5f || (fraction == 0.5f && odd) ? whole + 1.0f : whole;
  return std::copysign(result, value);
}
