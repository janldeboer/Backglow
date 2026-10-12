#pragma once
#include <cstdint>

struct CRGB {
  uint8_t r, g, b;
  CRGB(uint8_t red = 0, uint8_t green = 0, uint8_t blue = 0)
      : r(red), g(green), b(blue) {}
  static const CRGB Black;
};
inline const CRGB CRGB::Black = CRGB();
inline constexpr int WS2812B = 1;
inline constexpr int GRB = 1;

struct FakeFastLED {
  int shown = 0;
  int count = 0;
  template<int, int, int> void addLeds(CRGB *, int length) { count = length; }
  void setBrightness(uint8_t) {}
  void show() { ++shown; }
};
inline FakeFastLED FastLED;

inline void fill_solid(CRGB *leds, int count, CRGB color) {
  for (int index = 0; index < count; ++index) leds[index] = color;
}
