#include <algorithm>
#include <cassert>
#include <cstring>
#include "../src/main.cpp"

void command(uint8_t type, const uint8_t *payload = nullptr, uint8_t length = 0) {
  uint8_t body[2 + kMaximumPayload] = {type, length};
  if (length) memcpy(body + 2, payload, length);
  for (uint8_t byte : kMagic) consume(byte);
  for (size_t i = 0; i < size_t(length) + 2; ++i) consume(body[i]);
  const uint16_t checksum = crc16(body, size_t(length) + 2);
  consume(uint8_t(checksum));
  consume(uint8_t(checksum >> 8));
}

int main() {
  setup();
  assert(!hasProfile && storageReady && outputLEDs == 70);
  assert(Serial.output.size() == 16);
  assert(std::equal(kMagic, kMagic + 4, Serial.output.begin()));
  assert(Serial.output[4] == kHello && Serial.output[5] == 8);
  Serial.output.clear();

  command(kGetProfile);
  assert(Serial.output.size() == 8 && Serial.output[4] == kNoProfile);
  Serial.output.clear();

  uint8_t request[4 + kProfileBytes] = {};
  uint8_t *p = request + 4;
  p[0] = 1;
  write16(p + 1, 70);
  write16(p + 3, 59);
  p[5] = 12; p[6] = 21;
  write16(p + 7, 43);
  p[9] = 1;
  for (int index = 0; index < 6; ++index) write16(p + 10 + index * 2, 10000);
  write16(p + 22, 2500);
  command(kSetProfile, request, sizeof(request));
  assert(hasProfile && revision == 1 && Serial.output[4] == kSaved);
  assert(Preferences::slots.size() == 1);
  Serial.output.clear();

  command(kGetProfile);
  assert(Serial.output[4] == kProfile && Serial.output[5] == 28);
  assert(read32(Serial.output.data() + 6) == 1);
  assert(memcmp(Serial.output.data() + 10, p, kProfileBytes) == 0);
  Serial.output.clear();

  // A stale write is rejected, and repeating an identical write does not touch flash.
  command(kSetProfile, request, sizeof(request));
  assert(Serial.output[4] == kError && Serial.output[6] == kRevisionConflict);
  Serial.output.clear();
  write32(request, 1);
  command(kSetProfile, request, sizeof(request));
  assert(Serial.output[4] == kSaved && Preferences::slots.size() == 1);
  Serial.output.clear();

  const uint8_t oldPacket[] = {'l', 'e', 'd', 0, 255, 7, 9, 'l', 'e', 's'};
  const int before = FastLED.shown;
  for (uint8_t byte : oldPacket) consume(byte);
  assert(leds[0].r == 255 && leds[0].g == 7 && leds[0].b == 9);
  assert(FastLED.shown == before + 1);
  const uint8_t twoLEDs[] = {'l', 'e', 'd', 0, 1, 2, 3,
                             'l', 'e', 'd', 1, 4, 5, 6, 'l', 'e', 's'};
  for (uint8_t byte : twoLEDs) consume(byte);
  for (uint8_t byte : oldPacket) consume(byte);
  assert(leds[1].r == 0 && leds[1].g == 0 && leds[1].b == 0);
  Serial.output.clear();
  for (uint8_t byte : {'A', 'L', '3', '?'}) consume(byte);
  assert(Serial.output.size() == 16 && Serial.output[4] == kHello);

  hasProfile = false; revision = 0; activeSlot = -1; outputLEDs = kDefaultLEDs;
  loadProfile();
  assert(hasProfile && revision == 1 && memcmp(profile, p, kProfileBytes) == 0);
}
