// RECEIVER B — BEGINNER EDITION — USB port previously COM4.
// One complete sketch; no project headers or custom classes.
// Start with setup() and loop() below. This board creates the private Wi-Fi network.
// -----------------------------------------------------------------------------
// Shared packet format and data patterns (ordinary functions, no custom classes).
// This section is repeated in both sketches so each .ino is self-contained.
// -----------------------------------------------------------------------------
#include <Arduino.h>
#include <WiFi.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <lwip/sockets.h>
#include <lwip/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <limits.h>

const char* WIFI_NAME = "ESP32_RF_WS702";
const char* WIFI_PASSWORD = "RFProof1MbpsLab!";
const uint16_t UDP_PORT = 34568;
const uint32_t PAYLOAD_RATE = 1000000;
const size_t PAYLOAD_BYTES = 1250;
const size_t HEADER_BYTES = 40;
const size_t MAX_TEXT_BYTES = 32;
const uint64_t PACKET_INTERVAL_US = 10000;  // 1,250 bytes every 10 ms = 1 Mbps.
const uint32_t PACKET_MAGIC = 0x52465032;

enum SourceMode { PRBS7 = 0, PRBS15, ASCII_S, COUNTER, USER_TEXT };
enum PacketKind { PING = 1, PONG, BEGIN_RUN, READY, DATA, END_RUN, RESULT };
enum RunState { IDLE, ARMED, STREAMING, DRAINING, FINAL, PARTIAL };

// A struct only groups related values. There are no methods hidden inside it.
struct Settings {
  uint32_t mode;
  size_t textLength;
  uint8_t text[MAX_TEXT_BYTES];
};

struct PacketHeader {
  uint32_t kind, boot, run;
  uint64_t sequence;
  uint32_t a, b;
  uint64_t value;
  // DATA: a = configuration hash, b = source mode.
  // PING/PONG: a = enabled flag. PONG b = receiver boot ID.
  // END_RUN: sequence = attempted count, value = elapsed microseconds.
};

// Prototypes make the order explicit for Arduino's sketch preprocessor.
uint32_t read32(const uint8_t* bytes);
uint64_t read64(const uint8_t* bytes);
void write32(uint8_t* bytes, uint32_t value);
void write64(uint8_t* bytes, uint64_t value);
void encodeHeader(uint8_t* bytes, const PacketHeader& header);
bool decodeHeader(const uint8_t* bytes, size_t length, PacketHeader& header);
bool parseUnsigned(const char* text, uint32_t& value);
int splitCommand(char* text, char** fields, int capacity);
int hexDigit(char character);
bool parseSettings(uint32_t mode, const char* hexText, Settings& result);
uint32_t settingsHash(const Settings& value);
uint8_t nextPrbsByte(uint32_t& state, unsigned width);
void preparePatterns();
uint8_t patternByte(const Settings& value, uint64_t offset);
bool validFinalCounts(uint64_t attempted, uint64_t accepted, uint64_t unique,
                      uint64_t observed, uint64_t elapsed);
void reportError(uint32_t requestId, const char* message);
void handleGuiCommand(char* line);
void readGuiCommands();
void startRun(uint32_t requestId, uint32_t newRunId, const Settings& requested);
void stopStream(bool orderly);
void sendHello();
void sendState();
void sendStatistics();

// Look-up tables preserve the FPGA's PRBS taps, all-ones seeds and MSB-first order.
uint8_t prbs7Bytes[127];
uint8_t prbs15Bytes[32767];

// These values are RAM only. Firmware stays in flash, but a new boot starts OFF.
Settings settings = {};
RunState runState = IDLE;
bool enabled = false;
uint32_t bootId = 0;
uint32_t runId = 0;
uint32_t lastGuiMessageMs = 0;
char guiLine[256] = {};
size_t guiLineLength = 0;
bool discardGuiLine = false;

// -----------------------------------------------------------------------------
// RECEIVER B: state used by the ordinary functions below.
// -----------------------------------------------------------------------------
const size_t REORDER_WINDOW = 2048;
int udpSocket = -1;
sockaddr_in senderAddress = {};
bool accessPointStarted = false;
bool haveSender = false;
uint32_t senderBootId = 0;
uint32_t lastSenderMessageMs = 0;
uint32_t stateStartedMs = 0;
uint32_t lastReportMs = 0;
uint32_t bytesReceivedThisSecond = 0;
uint32_t receiveBitsPerSecond = 0;
uint64_t startedUs = 0;
uint64_t elapsedUs = 0;
uint64_t firstReceivedUs = 0;
uint64_t lastReceivedUs = 0;
uint64_t senderAttempted = 0;
uint64_t senderAccepted = 0;
uint64_t highestSequence = 0;
uint64_t uniquePackets = 0;
uint64_t errorBits = 0;
uint64_t duplicatePackets = 0;
uint64_t reorderedPackets = 0;
uint64_t latePackets = 0;
uint64_t malformedPackets = 0;
bool haveData = false;
uint8_t seenPackets[REORDER_WINDOW / 8] = {};
uint8_t outgoing[HEADER_BYTES + PAYLOAD_BYTES] = {};
uint8_t incoming[HEADER_BYTES + PAYLOAD_BYTES + 1] = {};
uint8_t receivedSample[MAX_TEXT_BYTES] = {};
size_t sampleLength = 0;
uint64_t sampleOffset = 0;
bool samplePending = false;

bool senderIsAlive();
uint64_t observedPackets();
uint64_t runDurationUs();
const char* stateName();
void clearMeasurements();
void failAndStop(const char* reason);
void openUdpSocket();
bool sendControlPacket(const PacketHeader& header, const uint8_t* payload, size_t length);
bool acceptSequence(uint64_t sequence);
void checkPayload(const PacketHeader& header, const uint8_t* payload);
void sendFinalResult();
void handleRadioPacket(const PacketHeader& header, const uint8_t* payload, size_t length,
                       const sockaddr_in& from);
void readRadioPackets();
void finishStoppedRun();
void reportOncePerSecond();

// -----------------------------------------------------------------------------
// START READING HERE: setup() runs once; loop() repeats.
// -----------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);                 // USB: commands, statistics and short samples.
  bootId = esp_random();
  if (bootId == 0) bootId = 1;
  preparePatterns();
  clearMeasurements();
  WiFi.persistent(false);
  WiFi.mode(WIFI_AP);                   // B creates the private Wi-Fi network.
  IPAddress address(192, 168, 4, 1);
  IPAddress mask(255, 255, 255, 0);
  accessPointStarted = WiFi.softAPConfig(address, address, mask) &&
                       WiFi.softAP(WIFI_NAME, WIFI_PASSWORD, 6, false, 1);
  if (!accessPointStarted) reportError(0, "AP_START_FAILED");
  WiFi.setSleep(false);
  lastGuiMessageMs = lastReportMs = millis();
  sendHello();
  sendState();                         // Payload reception starts OFF.
}

void loop() {
  readGuiCommands();

  if (enabled && uint32_t(millis() - lastGuiMessageMs) > 4000) {
    stopStream(false);
    Serial.println("EVENT|LEASE_EXPIRED");
  }

  openUdpSocket();
  readRadioPackets();                  // Receive and check the actual RF payload.
  finishStoppedRun();                  // Finish the final-count exchange after Stop.
  reportOncePerSecond();
  delay(1);
}

// -----------------------------------------------------------------------------
// Main receiving job: count each valid packet once, then compare its bits.
// -----------------------------------------------------------------------------
void checkPayload(const PacketHeader& header, const uint8_t* payload) {
  if (!acceptSequence(header.sequence)) return;
  uint64_t offset = header.sequence * PAYLOAD_BYTES;

  for (size_t i = 0; i < PAYLOAD_BYTES; ++i) {
    uint8_t difference = uint8_t(payload[i] ^ patternByte(settings, offset + i));
    while (difference != 0) {
      difference = uint8_t(difference & (difference - 1));  // Clear one differing bit.
      ++errorBits;
    }
  }

  bytesReceivedThisSecond += PAYLOAD_BYTES;
  lastReceivedUs = uint64_t(esp_timer_get_time());
  if (firstReceivedUs == 0) firstReceivedUs = lastReceivedUs;

  // Never display the expected USB text as if it had arrived over RF.
  // Copy only actual received DATA bytes. Rotate text into the beginning of its cycle.
  sampleLength = settings.mode == USER_TEXT ? settings.textLength : MAX_TEXT_BYTES;
  sampleOffset = offset;
  for (size_t i = 0; i < sampleLength; ++i) {
    size_t destination = settings.mode == USER_TEXT ? size_t((offset + i) % sampleLength) : i;
    receivedSample[destination] = payload[i];
  }
  samplePending = true;
}

bool acceptSequence(uint64_t sequence) {
  // A small circular bitmap remembers recent packet numbers without growing forever.
  if (!haveData) {
    haveData = true;
    highestSequence = sequence;
  } else if (sequence > highestSequence) {
    uint64_t gap = sequence - highestSequence;
    if (gap >= REORDER_WINDOW) {
      memset(seenPackets, 0, sizeof(seenPackets));
    } else {
      for (uint64_t value = highestSequence + 1; value <= sequence; ++value) {
        size_t slot = size_t(value % REORDER_WINDOW);
        seenPackets[slot / 8] &= uint8_t(~(1U << (slot % 8)));
      }
    }
    highestSequence = sequence;
  } else if (highestSequence - sequence >= REORDER_WINDOW) {
    ++latePackets;
    return false;
  }

  size_t slot = size_t(sequence % REORDER_WINDOW);
  uint8_t mask = uint8_t(1U << (slot % 8));
  if ((seenPackets[slot / 8] & mask) != 0) {
    ++duplicatePackets;
    return false;
  }
  seenPackets[slot / 8] |= mask;
  if (sequence < highestSequence) ++reorderedPackets;
  ++uniquePackets;
  return true;
}

void clearMeasurements() {
  memset(seenPackets, 0, sizeof(seenPackets));
  haveData = false;
  highestSequence = uniquePackets = errorBits = duplicatePackets = 0;
  reorderedPackets = latePackets = malformedPackets = 0;
  startedUs = elapsedUs = firstReceivedUs = lastReceivedUs = 0;
  senderAttempted = senderAccepted = 0;
  bytesReceivedThisSecond = receiveBitsPerSecond = 0;
  sampleLength = 0;
  samplePending = false;
}

void startRun(uint32_t requestId, uint32_t newRunId, const Settings& requested) {
  if (runId == newRunId) {
    if (!enabled || settingsHash(settings) != settingsHash(requested)) {
      reportError(requestId, "RUN_ALREADY_USED");
      return;
    }
  } else {
    if (enabled) {
      reportError(requestId, "BUSY");
      return;
    }
    settings = requested;
    runId = newRunId;
    enabled = true;
    runState = ARMED;
    stateStartedMs = millis();
    clearMeasurements();
    lastReportMs = millis();
  }
  lastGuiMessageMs = millis();
  Serial.printf("ACK|%lu|1|%lu\n", (unsigned long)requestId, (unsigned long)runId);
  sendState();
}

void stopStream(bool orderly) {
  (void)orderly;                        // Only A initiates the final RF exchange.
  if (!enabled) return;
  elapsedUs = runDurationUs();
  if (runState != FINAL) runState = PARTIAL;
  enabled = false;
  sendState();
}

void failAndStop(const char* reason) {
  stopStream(false);
  reportError(0, reason);
}

// -----------------------------------------------------------------------------
// Wi-Fi UDP. B learns A's address from a heartbeat instead of a hard-coded MAC.
// -----------------------------------------------------------------------------
bool senderIsAlive() {
  return haveSender && accessPointStarted &&
         uint32_t(millis() - lastSenderMessageMs) < 3000;
}

void openUdpSocket() {
  if (udpSocket >= 0 || !accessPointStarted) return;
  udpSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (udpSocket < 0) return;
  sockaddr_in local = {};
  local.sin_family = AF_INET;
  local.sin_port = htons(UDP_PORT);
  local.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(udpSocket, reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0 ||
      fcntl(udpSocket, F_SETFL, O_NONBLOCK) < 0) {
    close(udpSocket);
    udpSocket = -1;
  }
}

bool sendControlPacket(const PacketHeader& header, const uint8_t* payload, size_t length) {
  if (udpSocket < 0 || !haveSender || length > PAYLOAD_BYTES) return false;
  encodeHeader(outgoing, header);
  if (length > 0) memcpy(outgoing + HEADER_BYTES, payload, length);
  int sent = sendto(udpSocket, outgoing, HEADER_BYTES + length, 0,
                    reinterpret_cast<sockaddr*>(&senderAddress), sizeof(senderAddress));
  return sent == int(HEADER_BYTES + length);
}

void handleRadioPacket(const PacketHeader& header, const uint8_t* payload, size_t length,
                       const sockaddr_in& from) {
  if (header.kind == PING && length == 0 && header.a <= 1) {
    if (senderBootId != 0 && senderBootId != header.boot) failAndStop("PEER_RESTARTED");
    senderAddress = from;
    haveSender = true;
    senderBootId = header.boot;
    lastSenderMessageMs = millis();
    PacketHeader pong = {PONG, header.boot, runId, header.sequence,
                         uint32_t(enabled), bootId, 0};
    sendControlPacket(pong, nullptr, 0);
    return;
  }

  if (!haveSender || from.sin_addr.s_addr != senderAddress.sin_addr.s_addr ||
      from.sin_port != senderAddress.sin_port ||
      header.boot != senderBootId || header.run != runId || runId == 0) return;

  if (header.kind == BEGIN_RUN && length == 0 && enabled &&
      (runState == ARMED || runState == STREAMING)) {
    if (header.a != settingsHash(settings) || header.b != settings.mode ||
        header.value != PAYLOAD_RATE) {
      reportError(0, "CONFIGURATION_MISMATCH");
      return;
    }
    if (runState == ARMED) {
      runState = STREAMING;
      startedUs = uint64_t(esp_timer_get_time());
    }
    PacketHeader ready = {READY, senderBootId, runId, 0,
                          settingsHash(settings), settings.mode, PAYLOAD_RATE};
    sendControlPacket(ready, nullptr, 0);
    return;
  }

  if (header.kind == DATA && enabled && (runState == STREAMING || runState == DRAINING)) {
    if (length != PAYLOAD_BYTES || header.a != settingsHash(settings) ||
        header.b != settings.mode || header.sequence > UINT64_MAX / (PAYLOAD_BYTES * 8)) {
      ++malformedPackets;
      return;
    }
    checkPayload(header, payload);
    return;
  }

  if (header.kind == END_RUN && length == 8 && enabled) {
    if (runState == FINAL) {
      sendFinalResult();                // A may have missed our previous RESULT.
      return;
    }
    uint64_t accepted = read64(payload);
    if ((runState != STREAMING && runState != DRAINING) ||
        !validFinalCounts(header.sequence, accepted, uniquePackets, observedPackets(),
                          header.value)) return;
    if (runState != DRAINING) {
      senderAttempted = header.sequence;
      senderAccepted = accepted;
      elapsedUs = header.value;
      runState = DRAINING;
      stateStartedMs = millis();
    }
  }
}

void readRadioPackets() {
  if (udpSocket < 0) return;
  for (unsigned count = 0; count < 12; ++count) {
    sockaddr_in from = {};
    socklen_t fromLength = sizeof(from);
    int length = recvfrom(udpSocket, incoming, sizeof(incoming), 0,
                          reinterpret_cast<sockaddr*>(&from), &fromLength);
    if (length < 0) break;
    if (length > int(HEADER_BYTES + PAYLOAD_BYTES)) continue;
    PacketHeader header = {};
    if (decodeHeader(incoming, size_t(length), header)) {
      handleRadioPacket(header, incoming + HEADER_BYTES, size_t(length) - HEADER_BYTES, from);
    }
  }
}

void sendFinalResult() {
  uint8_t results[24];
  write64(results, errorBits);
  write64(results + 8, duplicatePackets);
  write64(results + 16, reorderedPackets);
  PacketHeader result = {RESULT, senderBootId, runId, uniquePackets, 0, 0, elapsedUs};
  sendControlPacket(result, results, sizeof(results));
}

void finishStoppedRun() {
  if (!enabled) return;
  if ((runState == ARMED || runState == STREAMING) &&
      uint32_t(millis() - stateStartedMs) > 15000 && !senderIsAlive()) {
    failAndStop("PEER_TIMEOUT");
    return;
  }

  // Keep receiving in-flight DATA for 500 ms after A's END_RUN packet.
  if (runState == DRAINING && uint32_t(millis() - stateStartedMs) >= 500) {
    if (!validFinalCounts(senderAttempted, senderAccepted, uniquePackets,
                          observedPackets(), elapsedUs)) {
      failAndStop("INVALID_FINAL_COUNTS");
      return;
    }
    uint64_t receiveSpan = lastReceivedUs > firstReceivedUs ? lastReceivedUs - firstReceivedUs : 0;
    if (receiveSpan > elapsedUs) elapsedUs = receiveSpan;
    runState = FINAL;
    sendStatistics();
    sendFinalResult();
  }
}

// -----------------------------------------------------------------------------
// Measurements sent to the existing v2 GUI. No full-speed payload over USB.
// -----------------------------------------------------------------------------
uint64_t observedPackets() {
  return haveData ? highestSequence + 1 : 0;
}

uint64_t runDurationUs() {
  if ((runState == STREAMING || runState == DRAINING) && startedUs != 0) {
    return uint64_t(esp_timer_get_time()) - startedUs;
  }
  return elapsedUs;
}

const char* stateName() {
  switch (runState) {
    case IDLE: return "IDLE";
    case ARMED: return "ARMED";
    case STREAMING:
    case DRAINING: return "LIVE";
    case FINAL: return "FINAL";
    default: return "PARTIAL";
  }
}

void sendHello() {
  Serial.printf("HELLO|2|AP|1000000|%s/%08lX\n",
                WiFi.softAPmacAddress().c_str(), (unsigned long)bootId);
}

void sendState() {
  Serial.printf("STATE|AP|%u|%u|%u|1000000|%lu|%u|0\n",
                unsigned(enabled), unsigned(accessPointStarted), unsigned(senderIsAlive()),
                (unsigned long)runId, unsigned(runState == STREAMING));
}

void sendStatistics() {
  uint64_t offered = runState == FINAL ? senderAttempted : observedPackets();
  Serial.printf("STATS|AP|%lu|%s|%llu|%llu|%llu|%llu|%llu|%llu|%llu|%llu|%llu|%llu|0|%lu\n",
                (unsigned long)runId, stateName(), (unsigned long long)runDurationUs(),
                (unsigned long long)senderAttempted, (unsigned long long)senderAccepted,
                (unsigned long long)uniquePackets, (unsigned long long)errorBits,
                (unsigned long long)duplicatePackets, (unsigned long long)reorderedPackets,
                (unsigned long long)latePackets, (unsigned long long)malformedPackets,
                (unsigned long long)offered, (unsigned long)receiveBitsPerSecond);
}

void reportOncePerSecond() {
  uint32_t nowMs = millis();
  uint32_t intervalMs = uint32_t(nowMs - lastReportMs);
  if (intervalMs < 1000) return;
  receiveBitsPerSecond = uint32_t(uint64_t(bytesReceivedThisSecond) * 8000 / intervalMs);
  bytesReceivedThisSecond = 0;
  lastReportMs = nowMs;
  sendState();
  sendStatistics();

  if (samplePending) {
    const char* digits = "0123456789ABCDEF";
    char hexSample[MAX_TEXT_BYTES * 2 + 1] = {};
    for (size_t i = 0; i < sampleLength; ++i) {
      hexSample[2 * i] = digits[receivedSample[i] >> 4];
      hexSample[2 * i + 1] = digits[receivedSample[i] & 15];
    }
    Serial.printf("SAMPLE|%lu|%lu|%llu|%s\n", (unsigned long)runId,
                  (unsigned long)settings.mode, (unsigned long long)sampleOffset, hexSample);
    samplePending = false;
  }
}

// -----------------------------------------------------------------------------
// Helper details: read this section after setup(), loop() and the data functions.
// -----------------------------------------------------------------------------

// Network byte order stores the most significant byte first, independent of CPU.
uint32_t read32(const uint8_t* bytes) {
  return uint32_t(bytes[0]) << 24 | uint32_t(bytes[1]) << 16 |
         uint32_t(bytes[2]) << 8 | bytes[3];
}

uint64_t read64(const uint8_t* bytes) {
  return uint64_t(read32(bytes)) << 32 | read32(bytes + 4);
}

void write32(uint8_t* bytes, uint32_t value) {
  bytes[0] = uint8_t(value >> 24);
  bytes[1] = uint8_t(value >> 16);
  bytes[2] = uint8_t(value >> 8);
  bytes[3] = uint8_t(value);
}

void write64(uint8_t* bytes, uint64_t value) {
  write32(bytes, uint32_t(value >> 32));
  write32(bytes + 4, uint32_t(value));
}

void encodeHeader(uint8_t* bytes, const PacketHeader& header) {
  write32(bytes, PACKET_MAGIC);
  write32(bytes + 4, header.kind);
  write32(bytes + 8, header.boot);
  write32(bytes + 12, header.run);
  write64(bytes + 16, header.sequence);
  write32(bytes + 24, header.a);
  write32(bytes + 28, header.b);
  write64(bytes + 32, header.value);
}

bool decodeHeader(const uint8_t* bytes, size_t length, PacketHeader& header) {
  if (length < HEADER_BYTES || read32(bytes) != PACKET_MAGIC) return false;
  header.kind = read32(bytes + 4);
  header.boot = read32(bytes + 8);
  header.run = read32(bytes + 12);
  header.sequence = read64(bytes + 16);
  header.a = read32(bytes + 24);
  header.b = read32(bytes + 28);
  header.value = read64(bytes + 32);
  return header.boot != 0 && header.kind >= PING && header.kind <= RESULT;
}

bool parseUnsigned(const char* text, uint32_t& value) {
  if (text == nullptr || *text == '\0') return false;
  uint32_t number = 0;
  while (*text != '\0') {
    if (*text < '0' || *text > '9') return false;
    uint32_t digit = uint32_t(*text - '0');
    if (number > (UINT32_MAX - digit) / 10) return false;
    number = number * 10 + digit;
    ++text;
  }
  value = number;
  return true;
}

int splitCommand(char* text, char** fields, int capacity) {
  int count = 1;
  fields[0] = text;
  while (*text != '\0') {
    if (*text == '|') {
      if (count == capacity) return -1;
      *text = '\0';
      fields[count++] = text + 1;
    }
    ++text;
  }
  return count;
}

int hexDigit(char character) {
  if (character >= '0' && character <= '9') return character - '0';
  if (character >= 'A' && character <= 'F') return character - 'A' + 10;
  if (character >= 'a' && character <= 'f') return character - 'a' + 10;
  return -1;
}

bool parseSettings(uint32_t mode, const char* hexText, Settings& result) {
  if (mode > USER_TEXT) return false;
  result.mode = mode;
  result.textLength = 0;
  if (mode != USER_TEXT) return strcmp(hexText, "-") == 0;

  // The GUI encodes UTF-8 bytes as hex so delimiters/newlines cannot break a command.
  size_t digits = strlen(hexText);
  if (digits == 0 || digits % 2 != 0 || digits / 2 > MAX_TEXT_BYTES) return false;
  for (size_t i = 0; i < digits; i += 2) {
    int high = hexDigit(hexText[i]);
    int low = hexDigit(hexText[i + 1]);
    if (high < 0 || low < 0) return false;
    result.text[i / 2] = uint8_t(high * 16 + low);
  }
  result.textLength = digits / 2;
  return true;
}

uint32_t settingsHash(const Settings& value) {
  uint32_t hash = 2166136261U;
  hash = (hash ^ value.mode) * 16777619U;
  hash = (hash ^ uint32_t(value.textLength)) * 16777619U;
  for (size_t i = 0; i < value.textLength; ++i) {
    hash = (hash ^ value.text[i]) * 16777619U;
  }
  return hash;
}

uint8_t nextPrbsByte(uint32_t& state, unsigned width) {
  uint8_t result = 0;
  for (unsigned bit = 0; bit < 8; ++bit) {
    uint32_t outputBit = (state >> (width - 1)) & 1U;
    uint32_t previousBit = (state >> (width - 2)) & 1U;
    result = uint8_t((result << 1) | outputBit);
    state = ((state << 1) | (outputBit ^ previousBit)) & ((1U << width) - 1U);
  }
  return result;
}

void preparePatterns() {
  uint32_t state = 127;
  for (size_t i = 0; i < 127; ++i) prbs7Bytes[i] = nextPrbsByte(state, 7);
  state = 32767;
  for (size_t i = 0; i < 32767; ++i) prbs15Bytes[i] = nextPrbsByte(state, 15);
}

uint8_t patternByte(const Settings& value, uint64_t offset) {
  switch (value.mode) {
    case PRBS7: return prbs7Bytes[offset % 127];
    case PRBS15: return prbs15Bytes[offset % 32767];
    case ASCII_S: return 0x53;                  // ASCII character 'S'.
    case COUNTER: return uint8_t(offset);      // 00, 01, ... FF, 00, ...
    case USER_TEXT:
      return value.textLength == 0 ? 0 : value.text[offset % value.textLength];
    default: return 0;
  }
}

bool validFinalCounts(uint64_t attempted, uint64_t accepted, uint64_t unique,
                      uint64_t observed, uint64_t elapsed) {
  return attempted <= UINT64_MAX / (PAYLOAD_BYTES * 8) &&
         accepted <= attempted && unique <= accepted &&
         observed <= attempted && elapsed > 0;
}

void reportError(uint32_t requestId, const char* message) {
  Serial.printf("ERROR|%lu|%s\n", (unsigned long)requestId, message);
}

// Wire format is unchanged, so the existing continuous-v2 GUI still understands it.
void handleGuiCommand(char* line) {
  char* fields[6] = {};
  int count = splitCommand(line, fields, 6);

  if (count == 1 && strcmp(fields[0], "HELLO") == 0) {
    sendHello();
    sendState();
    return;
  }
  if (count == 1 && strcmp(fields[0], "KEEPALIVE") == 0) {
    lastGuiMessageMs = millis();
    return;
  }

  uint32_t requestId = 0;
  if (count < 2 || !parseUnsigned(fields[1], requestId) || requestId == 0) {
    reportError(0, "BAD_COMMAND");
    return;
  }
  if (count == 2 && strcmp(fields[0], "STOP") == 0) {
    stopStream(true);
    lastGuiMessageMs = millis();
    Serial.printf("ACK|%lu|0|%lu\n", (unsigned long)requestId, (unsigned long)runId);
    sendState();
    sendStatistics();
    return;
  }
  if (count == 5 && strcmp(fields[0], "START") == 0) {
    uint32_t newRunId = 0;
    uint32_t mode = 0;
    Settings requested = {};
    if (!parseUnsigned(fields[2], newRunId) || newRunId == 0 ||
        !parseUnsigned(fields[3], mode) || !parseSettings(mode, fields[4], requested)) {
      reportError(requestId, "BAD_CONFIGURATION");
      return;
    }
    startRun(requestId, newRunId, requested);
    return;
  }
  reportError(requestId, "BAD_COMMAND");
}

void readGuiCommands() {
  // Limit work per loop so USB traffic cannot starve the RF work.
  for (unsigned count = 0; count < 128 && Serial.available(); ++count) {
    char character = char(Serial.read());
    if (character == '\r') continue;
    if (character == '\n') {
      if (discardGuiLine) reportError(0, "LINE_TOO_LONG");
      else if (guiLineLength > 0) {
        guiLine[guiLineLength] = '\0';
        handleGuiCommand(guiLine);
      }
      guiLineLength = 0;
      discardGuiLine = false;
    } else if (!discardGuiLine) {
      if (character == '\0' || guiLineLength >= sizeof(guiLine) - 1) {
        discardGuiLine = true;
      } else {
        guiLine[guiLineLength++] = character;
      }
    }
  }
}
