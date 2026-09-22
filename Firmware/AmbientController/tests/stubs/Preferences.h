#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

struct Preferences {
  static inline std::map<std::string, std::vector<uint8_t>> slots;
  bool begin(const char *, bool) { return true; }
  void end() {}
  size_t getBytesLength(const char *key) const {
    auto found = slots.find(key);
    return found == slots.end() ? 0 : found->second.size();
  }
  size_t getBytes(const char *key, void *buffer, size_t count) const {
    auto found = slots.find(key);
    if (found == slots.end() || found->second.size() != count) return 0;
    std::memcpy(buffer, found->second.data(), count);
    return count;
  }
  size_t putBytes(const char *key, const void *buffer, size_t count) {
    const auto *start = static_cast<const uint8_t *>(buffer);
    slots[key] = std::vector<uint8_t>(start, start + count);
    return count;
  }
};
