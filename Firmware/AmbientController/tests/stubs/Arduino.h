#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

struct FakeSerial {
  std::deque<uint8_t> input;
  std::vector<uint8_t> output;
  void begin(unsigned long) {}
  int available() const { return int(input.size()); }
  int read() { uint8_t byte = input.front(); input.pop_front(); return byte; }
  size_t write(uint8_t byte) { output.push_back(byte); return 1; }
  size_t write(const uint8_t *bytes, size_t count) {
    output.insert(output.end(), bytes, bytes + count);
    return count;
  }
};
inline FakeSerial Serial;

struct FakeESP {
  uint64_t getEfuseMac() const { return 0x0123456789abcdefULL; }
  void restart() {}
};
inline FakeESP ESP;
inline uint32_t millis() { return 0; }
