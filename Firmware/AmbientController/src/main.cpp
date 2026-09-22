#include <Arduino.h>
#include <FastLED.h>
#include <string.h>

#if defined(ESP32)
#include <Preferences.h>
#elif defined(ESP8266)
#include <LittleFS.h>
#else
#error This firmware supports ESP32 and ESP8266 only.
#endif

// AL3 control protocol: magic, message, one-byte length, payload, CRC16-CCITT.
// The historical led/index/RGB and les color stream remains unchanged.
static constexpr uint8_t kMaximumLEDs = 255;
static constexpr uint8_t kDefaultLEDs = 70;
static constexpr uint8_t kProfileBytes = 24;
static constexpr uint8_t kMaximumPayload = 64;
static constexpr uint8_t kRecordBytes = 4 + 4 + kProfileBytes + 2;
static constexpr uint8_t kMagic[] = {'A', 'L', '3', '!'};

enum Message : uint8_t {
  kHello = 1, kGetProfile = 2, kProfile = 3, kSetProfile = 4,
  kSaved = 5, kError = 6, kNoProfile = 7, kInitializeStorage = 8
};

enum ErrorCode : uint8_t {
  kMalformed = 1, kStorageUnavailable = 2, kRevisionConflict = 3,
  kInvalidProfile = 4, kWriteFailed = 5, kUnsupportedSchema = 6
};

CRGB leds[kMaximumLEDs];
uint8_t profile[kProfileBytes] = {};
uint32_t revision = 0;
bool hasProfile = false;
bool storageReady = false;
bool unsupportedProfile = false;
int8_t activeSlot = -1;
uint8_t outputLEDs = kDefaultLEDs;
uint32_t restartAt = 0;

uint16_t read16(const uint8_t *data) {
  return uint16_t(data[0]) | (uint16_t(data[1]) << 8);
}

uint32_t read32(const uint8_t *data) {
  return uint32_t(read16(data)) | (uint32_t(read16(data + 2)) << 16);
}

void write16(uint8_t *data, uint16_t value) {
  data[0] = uint8_t(value);
  data[1] = uint8_t(value >> 8);
}

void write32(uint8_t *data, uint32_t value) {
  write16(data, uint16_t(value));
  write16(data + 2, uint16_t(value >> 16));
}

uint16_t crc16(const uint8_t *data, size_t length) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < length; ++i) {
    crc ^= uint16_t(data[i]) << 8;
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x8000) ? uint16_t((crc << 1) ^ 0x1021) : uint16_t(crc << 1);
    }
  }
  return crc;
}

bool validProfile(const uint8_t *data) {
  const uint16_t physical = read16(data + 1);
  const uint16_t active = read16(data + 3);
  const uint8_t rows = data[5];
  const uint8_t columns = data[6];
  const uint16_t zones = 2 * (uint16_t(rows) + columns) - 4;
  if (data[0] != 1 || physical == 0 || physical > kMaximumLEDs ||
      rows < 2 || rows > 50 || columns < 2 || columns > 50 ||
      active == 0 || active > physical || active > zones ||
      read16(data + 7) >= zones || (data[9] & ~uint8_t(3))) return false;
  const uint16_t values[7] = {
      read16(data + 10), read16(data + 12), read16(data + 14),
      read16(data + 16), read16(data + 18), read16(data + 20),
      read16(data + 22)};
  return values[0] <= 20000 && values[1] >= 2500 && values[1] <= 30000 &&
         values[2] <= 20000 && values[3] <= 20000 && values[4] <= 20000 &&
         values[5] <= 10000 && values[6] <= 9500;
}

bool readSlot(uint8_t slot, uint8_t *record) {
#if defined(ESP32)
  Preferences preferences;
  if (!preferences.begin("ambient-v3", true)) return false;
  const char *key = slot == 0 ? "profileA" : "profileB";
  const bool ok = preferences.getBytesLength(key) == kRecordBytes &&
                  preferences.getBytes(key, record, kRecordBytes) == kRecordBytes;
  preferences.end();
  return ok;
#else
  File file = LittleFS.open(slot == 0 ? "/al3-a.bin" : "/al3-b.bin", "r");
  if (!file) return false;
  const bool ok = file.size() == kRecordBytes &&
                  file.read(record, kRecordBytes) == kRecordBytes;
  file.close();
  return ok;
#endif
}

bool writeSlot(uint8_t slot, const uint8_t *record) {
#if defined(ESP32)
  Preferences preferences;
  if (!preferences.begin("ambient-v3", false)) return false;
  const bool ok = preferences.putBytes(slot == 0 ? "profileA" : "profileB",
                                        record, kRecordBytes) == kRecordBytes;
  preferences.end();
  return ok;
#else
  File file = LittleFS.open(slot == 0 ? "/al3-a.bin" : "/al3-b.bin", "w");
  if (!file) return false;
  const bool ok = file.write(record, kRecordBytes) == kRecordBytes;
  file.close();
  return ok;
#endif
}

bool validRecordEnvelope(const uint8_t *record) {
  return memcmp(record, "AL3P", 4) == 0 &&
         read16(record + kRecordBytes - 2) == crc16(record, kRecordBytes - 2);
}

void loadProfile() {
#if defined(ESP8266)
  LittleFSConfig config;
  config.setAutoFormat(false);
  LittleFS.setConfig(config);
  storageReady = LittleFS.begin();
#else
  Preferences preferences;
  storageReady = preferences.begin("ambient-v3", false);
  if (storageReady) preferences.end();
#endif
  if (!storageReady) return;
  uint8_t record[kRecordBytes];
  for (uint8_t slot = 0; slot < 2; ++slot) {
    if (!readSlot(slot, record) || !validRecordEnvelope(record)) continue;
    const uint32_t foundRevision = read32(record + 4);
    if (activeSlot < 0 || foundRevision > revision) {
      revision = foundRevision;
      activeSlot = slot;
      hasProfile = validProfile(record + 8);
      unsupportedProfile = !hasProfile;
      if (hasProfile) memcpy(profile, record + 8, kProfileBytes);
    }
  }
  if (hasProfile) outputLEDs = uint8_t(read16(profile + 1));
}

bool persistProfile(const uint8_t *newProfile) {
  const uint8_t target = activeSlot == 0 ? 1 : 0;
  uint8_t record[kRecordBytes];
  memcpy(record, "AL3P", 4);
  write32(record + 4, revision + 1);
  memcpy(record + 8, newProfile, kProfileBytes);
  write16(record + kRecordBytes - 2, crc16(record, kRecordBytes - 2));
  if (!writeSlot(target, record)) return false;
  uint8_t check[kRecordBytes];
  if (!readSlot(target, check) || memcmp(check, record, kRecordBytes) != 0 ||
      !validRecordEnvelope(check) || !validProfile(check + 8)) return false;
  revision += 1;
  activeSlot = target;
  hasProfile = true;
  memcpy(profile, newProfile, kProfileBytes);
  return true;
}

void sendFrame(Message message, const uint8_t *payload = nullptr, uint8_t length = 0) {
  uint8_t body[2 + kMaximumPayload];
  body[0] = message;
  body[1] = length;
  if (length) memcpy(body + 2, payload, length);
  const uint16_t checksum = crc16(body, size_t(length) + 2);
  Serial.write(kMagic, 4);
  Serial.write(body, size_t(length) + 2);
  Serial.write(uint8_t(checksum));
  Serial.write(uint8_t(checksum >> 8));
}

void sendHello() {
  uint8_t storageState = storageReady ? 1 : 3;
#if defined(ESP8266)
  if (!storageReady) storageState = 0;
#endif
  if (unsupportedProfile) storageState = 2;
  uint8_t payload[8] = {1, uint8_t(kMaximumLEDs), 0, storageState, 0, 0, 0, 0};
#if defined(ESP32)
  write32(payload + 4, uint32_t(ESP.getEfuseMac()));
#else
  write32(payload + 4, ESP.getChipId());
#endif
  sendFrame(kHello, payload, sizeof(payload));
}

void handleCommand(uint8_t message, const uint8_t *payload, uint8_t length) {
  if (message == kInitializeStorage) {
    if (length) { uint8_t code = kMalformed; sendFrame(kError, &code, 1); return; }
#if defined(ESP8266)
    if (!storageReady && !unsupportedProfile) {
      storageReady = LittleFS.format() && LittleFS.begin();
    }
#endif
    if (!storageReady || unsupportedProfile) {
      uint8_t code = unsupportedProfile ? kUnsupportedSchema : kStorageUnavailable;
      sendFrame(kError, &code, 1);
    } else {
      sendHello();
      if (!hasProfile) sendFrame(kNoProfile);
    }
    return;
  }
  if (unsupportedProfile) {
    uint8_t code = kUnsupportedSchema;
    sendFrame(kError, &code, 1);
    return;
  }
  if (message == kGetProfile) {
    if (length) { uint8_t code = kMalformed; sendFrame(kError, &code, 1); return; }
    if (!hasProfile) { sendFrame(kNoProfile); return; }
    uint8_t answer[4 + kProfileBytes];
    write32(answer, revision);
    memcpy(answer + 4, profile, kProfileBytes);
    sendFrame(kProfile, answer, sizeof(answer));
    return;
  }
  if (message != kSetProfile) return;
  uint8_t code = 0;
  if (length != 4 + kProfileBytes) code = kMalformed;
  else if (!storageReady) code = kStorageUnavailable;
  else if (read32(payload) != revision) code = kRevisionConflict;
  else if (!validProfile(payload + 4)) code = kInvalidProfile;
  if (code) { sendFrame(kError, &code, 1); return; }
  const uint8_t oldCount = outputLEDs;
  if (!hasProfile || memcmp(profile, payload + 4, kProfileBytes) != 0) {
    if (!persistProfile(payload + 4)) {
      code = kWriteFailed;
      sendFrame(kError, &code, 1);
      return;
    }
  }
  uint8_t answer[4];
  write32(answer, revision);
  sendFrame(kSaved, answer, sizeof(answer));
  if (oldCount != read16(profile + 1)) restartAt = millis() + 1800;
}

// The two parsers only recognize a new command at a boundary between complete
// historical LED records. Arbitrary RGB bytes cannot become control commands.
uint8_t legacyState = 0;
uint8_t ledIndex = 0, red = 0, green = 0;
uint8_t frameLEDs = 0;
uint8_t controlPrefix = 0;
uint8_t controlState = 0;
uint8_t controlMessage = 0, controlLength = 0, controlUsed = 0;
uint8_t controlPayload[kMaximumPayload];
uint8_t controlBody[2 + kMaximumPayload];
uint8_t checksumLow = 0;

void consume(uint8_t byte) {
  if (controlState != 0) {
    if (controlState == 1) { controlMessage = byte; controlBody[0] = byte; controlState = 2; return; }
    if (controlState == 2) {
      controlLength = byte;
      controlBody[1] = byte;
      controlUsed = 0;
      controlState = byte > kMaximumPayload ? 0 : (byte == 0 ? 4 : 3);
      return;
    }
    if (controlState == 3) {
      controlPayload[controlUsed] = byte;
      controlBody[2 + controlUsed] = byte;
      if (++controlUsed == controlLength) controlState = 4;
      return;
    }
    if (controlState == 4) { checksumLow = byte; controlState = 5; return; }
    controlState = 0;
    if (uint16_t(checksumLow) + (uint16_t(byte) << 8) ==
        crc16(controlBody, size_t(controlLength) + 2)) {
      handleCommand(controlMessage, controlPayload, controlLength);
    }
    return;
  }
  if (legacyState != 0) {
    switch (legacyState) {
      case 1: legacyState = byte == 'e' ? 2 : 0; break;
      case 2:
        if (byte == 's') {
          for (uint16_t index = frameLEDs; index < outputLEDs; ++index) leds[index] = CRGB::Black;
          FastLED.show();
          frameLEDs = 0;
          legacyState = 0;
        }
        else legacyState = byte == 'd' ? 3 : 0;
        break;
      case 3: ledIndex = byte; legacyState = byte < outputLEDs ? 4 : 0; break;
      case 4: red = byte; legacyState = 5; break;
      case 5: green = byte; legacyState = 6; break;
      case 6:
        leds[ledIndex] = CRGB(red, green, byte);
        if (ledIndex >= frameLEDs) frameLEDs = ledIndex + 1;
        legacyState = 0;
        break;
    }
    return;
  }
  if (controlPrefix != 0 || byte == 'A') {
    const uint8_t prefix[] = {'A', 'L', '3'};
    if (controlPrefix < 3 && byte == prefix[controlPrefix]) {
      ++controlPrefix;
      return;
    }
    if (controlPrefix == 3 && byte == '?') { controlPrefix = 0; sendHello(); return; }
    if (controlPrefix == 3 && byte == '!') { controlPrefix = 0; controlState = 1; return; }
    controlPrefix = byte == 'A' ? 1 : 0;
    if (controlPrefix) return;
  }
  if (byte == 'l') legacyState = 1;
}

void setup() {
  Serial.begin(230400);
  loadProfile();
  FastLED.addLeds<WS2812B, LED_DATA_PIN, GRB>(leds, outputLEDs);
  FastLED.setBrightness(50); // Retain the legacy sketch's output limit.
  fill_solid(leds, outputLEDs, CRGB::Black);
  FastLED.show();
  sendHello();
}

void loop() {
  while (Serial.available() > 0) consume(uint8_t(Serial.read()));
  if (restartAt && int32_t(millis() - restartAt) >= 0) ESP.restart();
}
