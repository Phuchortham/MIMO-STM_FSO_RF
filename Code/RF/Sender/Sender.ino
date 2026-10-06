// SENDER A — BEGINNER EDITION — USB port previously COM5.
// One complete sketch; no project headers or custom classes.
// Start with setup() and loop() below. Do not change packet timing for the 1 Mbps test.
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
// SENDER A: state used by the ordinary functions below.
// -----------------------------------------------------------------------------
int udpSocket = -1;
sockaddr_in receiverAddress = {};
bool haveReceiverAddress = false;
bool receiverEnabled = false;
bool wifiWasConnected = false;
bool waitingForFinalReport = false;
uint32_t receiverBootId = 0;
uint32_t lastReceiverMessageMs = 0;
uint32_t lastPingMs = 0;
uint32_t lastReconnectMs = 0;
uint32_t stateStartedMs = 0;
uint32_t lastRetryMs = 0;
uint32_t lastReportMs = 0;
uint32_t bytesSentThisSecond = 0;
uint32_t transmitBitsPerSecond = 0;
uint64_t startedUs = 0;
uint64_t elapsedUs = 0;
uint64_t nextPacketUs = 0;
uint64_t attemptedPackets = 0;
uint64_t acceptedPackets = 0;
uint8_t outgoing[HEADER_BYTES + PAYLOAD_BYTES] = {};
uint8_t incoming[HEADER_BYTES + PAYLOAD_BYTES + 1] = {};

bool receiverIsAlive();
uint64_t runDurationUs();
const char* stateName();
void failAndStop(const char* reason);
void openUdpSocket();
bool sendControlPacket(const PacketHeader& header, const uint8_t* payload, size_t length);
void handleRadioPacket(const PacketHeader& header, const uint8_t* payload, size_t length);
void readRadioPackets();
void maintainConnection();
void sendDataWhenDue();
void reportOncePerSecond();

// -----------------------------------------------------------------------------
// START READING HERE: setup() runs once; loop() repeats.
// -----------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);                 // USB: commands and statistics, not bulk data.
  bootId = esp_random();
  if (bootId == 0) bootId = 1;
  preparePatterns();
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);                  // A joins the network created by B.
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_NAME, WIFI_PASSWORD);
  WiFi.setSleep(false);
  lastGuiMessageMs = lastReportMs = lastReconnectMs = millis();
  sendHello();
  sendState();                         // Starts OFF; the GUI must request START.
}

void loop() {
  readGuiCommands();

  // If the PC stops controlling us, stop the data stream after four seconds.
  if (enabled && uint32_t(millis() - lastGuiMessageMs) > 4000) {
    stopStream(false);
    Serial.println("EVENT|LEASE_EXPIRED");
  }

  maintainConnection();
  readRadioPackets();                  // B's READY, heartbeat and final result.
  sendDataWhenDue();                    // Generates data here, inside ESP32 A.
  reportOncePerSecond();
  delay(1);                            // Let other ESP32 tasks run.
}

// -----------------------------------------------------------------------------
// Main sending job. The schedule, not the USB baud rate, sets the payload rate.
// -----------------------------------------------------------------------------
void sendDataWhenDue() {
  uint32_t nowMs = millis();

  if (enabled && runState == ARMED) {
    if (uint32_t(nowMs - stateStartedMs) > 12000) {
      failAndStop("RECEIVER_NOT_READY");
      return;
    }
    if (receiverIsAlive() && receiverEnabled &&
        uint32_t(nowMs - lastRetryMs) >= 200) {
      PacketHeader begin = {BEGIN_RUN, bootId, runId, 0,
                            settingsHash(settings), settings.mode, PAYLOAD_RATE};
      sendControlPacket(begin, nullptr, 0);
      lastRetryMs = nowMs;
    }
  } else if (enabled && runState == STREAMING) {
    if (!receiverIsAlive()) {
      failAndStop("PEER_TIMEOUT");
      return;
    }

    uint64_t nowUs = uint64_t(esp_timer_get_time());
    if (nowUs >= nextPacketUs) {
      uint64_t sequence = attemptedPackets++;
      PacketHeader header = {DATA, bootId, runId, sequence,
                             settingsHash(settings), settings.mode, 0};
      encodeHeader(outgoing, header);

      // The offset continues across packets; User Text does not restart at each packet.
      uint64_t offset = sequence * PAYLOAD_BYTES;
      for (size_t i = 0; i < PAYLOAD_BYTES; ++i) {
        outgoing[HEADER_BYTES + i] = patternByte(settings, offset + i);
      }

      int sent = sendto(udpSocket, outgoing, sizeof(outgoing), 0,
                        reinterpret_cast<sockaddr*>(&receiverAddress),
                        sizeof(receiverAddress));
      if (sent == int(sizeof(outgoing))) {
        ++acceptedPackets;             // Accepted by UDP; not proof of delivery.
        bytesSentThisSecond += PAYLOAD_BYTES;
      }

      nextPacketUs += PACKET_INTERVAL_US;
      // Avoid an unlimited catch-up burst after an unusually long scheduling stall.
      if (nowUs > nextPacketUs + 100000) nextPacketUs = nowUs + PACKET_INTERVAL_US;
    }
  }

  // After Stop, only a short final-count exchange continues; no DATA packets.
  if (waitingForFinalReport) {
    if (uint32_t(nowMs - stateStartedMs) > 3500) {
      waitingForFinalReport = false;
      reportError(0, "FINAL_REPORT_TIMEOUT");
    } else if (uint32_t(nowMs - lastRetryMs) >= 200) {
      uint8_t countBytes[8];
      write64(countBytes, acceptedPackets);
      PacketHeader end = {END_RUN, bootId, runId, attemptedPackets, 0, 0, elapsedUs};
      sendControlPacket(end, countBytes, sizeof(countBytes));
      lastRetryMs = nowMs;
    }
  }
}

void startRun(uint32_t requestId, uint32_t newRunId, const Settings& requested) {
  // A retried START may be acknowledged again, but never restart an old stopped run.
  if (runId == newRunId) {
    if (!enabled || settingsHash(settings) != settingsHash(requested)) {
      reportError(requestId, "RUN_ALREADY_USED");
      return;
    }
  } else {
    if (enabled || waitingForFinalReport) {
      reportError(requestId, "BUSY");
      return;
    }
    settings = requested;
    runId = newRunId;
    enabled = true;
    runState = ARMED;
    stateStartedMs = millis();
    lastRetryMs = millis() - 200;
    startedUs = elapsedUs = nextPacketUs = attemptedPackets = acceptedPackets = 0;
    bytesSentThisSecond = transmitBitsPerSecond = 0;
    lastReportMs = millis();
  }
  lastGuiMessageMs = millis();
  Serial.printf("ACK|%lu|1|%lu\n", (unsigned long)requestId, (unsigned long)runId);
  sendState();
}

void stopStream(bool orderly) {
  if (!enabled) return;
  elapsedUs = runDurationUs();
  waitingForFinalReport = orderly && runState == STREAMING;
  if (waitingForFinalReport) {
    runState = FINAL;
    stateStartedMs = millis();
    lastRetryMs = millis() - 200;
  } else if (runState != FINAL) {
    runState = PARTIAL;
  }
  enabled = false;
  sendState();
}

void failAndStop(const char* reason) {
  stopStream(false);
  waitingForFinalReport = false;
  reportError(0, reason);
}

// -----------------------------------------------------------------------------
// Wi-Fi and incoming control packets from B.
// -----------------------------------------------------------------------------
bool receiverIsAlive() {
  return haveReceiverAddress && WiFi.status() == WL_CONNECTED &&
         uint32_t(millis() - lastReceiverMessageMs) < 3000;
}

void openUdpSocket() {
  if (udpSocket >= 0 || WiFi.status() != WL_CONNECTED) return;
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
    return;
  }
  receiverAddress.sin_family = AF_INET;
  receiverAddress.sin_port = htons(UDP_PORT);
  inet_pton(AF_INET, "192.168.4.1", &receiverAddress.sin_addr);
  haveReceiverAddress = true;
}

bool sendControlPacket(const PacketHeader& header, const uint8_t* payload, size_t length) {
  if (udpSocket < 0 || !haveReceiverAddress || length > PAYLOAD_BYTES) return false;
  encodeHeader(outgoing, header);
  if (length > 0) memcpy(outgoing + HEADER_BYTES, payload, length);
  int sent = sendto(udpSocket, outgoing, HEADER_BYTES + length, 0,
                    reinterpret_cast<sockaddr*>(&receiverAddress), sizeof(receiverAddress));
  return sent == int(HEADER_BYTES + length);
}

void maintainConnection() {
  uint32_t nowMs = millis();
  bool connected = WiFi.status() == WL_CONNECTED;
  if (!connected && wifiWasConnected) {
    failAndStop("WIFI_LOST");
    receiverEnabled = false;
    lastReceiverMessageMs = 0;
    if (udpSocket >= 0) close(udpSocket);
    udpSocket = -1;
  }
  wifiWasConnected = connected;
  if (!connected && uint32_t(nowMs - lastReconnectMs) > 10000) {
    WiFi.reconnect();
    lastReconnectMs = nowMs;
  }
  openUdpSocket();
  if (connected && udpSocket >= 0 && uint32_t(nowMs - lastPingMs) >= 500) {
    PacketHeader ping = {PING, bootId, runId, nowMs, uint32_t(enabled), 0, 0};
    sendControlPacket(ping, nullptr, 0);
    lastPingMs = nowMs;
  }
}

void handleRadioPacket(const PacketHeader& header, const uint8_t* payload, size_t length) {
  if (header.kind == PONG && header.boot == bootId && length == 0 &&
      header.a <= 1 && header.b != 0) {
    if (receiverBootId != 0 && receiverBootId != header.b) failAndStop("PEER_RESTARTED");
    receiverBootId = header.b;
    receiverEnabled = header.a == 1;
    lastReceiverMessageMs = millis();
    if (enabled && runState == STREAMING && !receiverEnabled) failAndStop("RECEIVER_DISABLED");
    return;
  }
  if (header.boot != bootId || header.run != runId || runId == 0) return;

  if (header.kind == READY && enabled && runState == ARMED && length == 0 &&
      header.a == settingsHash(settings) && header.b == settings.mode &&
      header.value == PAYLOAD_RATE) {
    runState = STREAMING;
    startedUs = uint64_t(esp_timer_get_time());
    nextPacketUs = startedUs + PACKET_INTERVAL_US;
    sendState();
  } else if (header.kind == RESULT && waitingForFinalReport && length == 24 &&
             validFinalCounts(attemptedPackets, acceptedPackets, header.sequence,
                              header.sequence, header.value) &&
             header.value >= elapsedUs &&
             read64(payload) <= header.sequence * PAYLOAD_BYTES * 8) {
    waitingForFinalReport = false;
    Serial.printf("FINISHED|%lu\n", (unsigned long)runId);
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
    if (length > int(HEADER_BYTES + PAYLOAD_BYTES) || !haveReceiverAddress ||
        from.sin_addr.s_addr != receiverAddress.sin_addr.s_addr ||
        from.sin_port != receiverAddress.sin_port) continue;
    PacketHeader header = {};
    if (decodeHeader(incoming, size_t(length), header)) {
      handleRadioPacket(header, incoming + HEADER_BYTES, size_t(length) - HEADER_BYTES);
    }
  }
}

// -----------------------------------------------------------------------------
// USB status and measurements: the same v2 format as the tested GUI.
// -----------------------------------------------------------------------------
uint64_t runDurationUs() {
  if (runState == STREAMING && startedUs != 0) return uint64_t(esp_timer_get_time()) - startedUs;
  return elapsedUs;
}

const char* stateName() {
  switch (runState) {
    case IDLE: return "IDLE";
    case ARMED: return "ARMED";
    case STREAMING: return "LIVE";
    case FINAL: return "FINAL";
    default: return "PARTIAL";
  }
}

void sendHello() {
  Serial.printf("HELLO|2|STA|1000000|%s/%08lX\n",
                WiFi.macAddress().c_str(), (unsigned long)bootId);
}

void sendState() {
  Serial.printf("STATE|STA|%u|%u|%u|1000000|%lu|%u|%ld\n",
                unsigned(enabled), unsigned(WiFi.status() == WL_CONNECTED),
                unsigned(receiverIsAlive()), (unsigned long)runId,
                unsigned(runState == STREAMING),
                (long)(WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : 0));
}

void sendStatistics() {
  Serial.printf("STATS|STA|%lu|%s|%llu|%llu|%llu|0|0|0|0|0|0|%llu|%lu|0\n",
                (unsigned long)runId, stateName(),
                (unsigned long long)runDurationUs(), (unsigned long long)attemptedPackets,
                (unsigned long long)acceptedPackets, (unsigned long long)attemptedPackets,
                (unsigned long)transmitBitsPerSecond);
}

void reportOncePerSecond() {
  uint32_t nowMs = millis();
  uint32_t intervalMs = uint32_t(nowMs - lastReportMs);
  if (intervalMs < 1000) return;
  transmitBitsPerSecond = uint32_t(uint64_t(bytesSentThisSecond) * 8000 / intervalMs);
  bytesSentThisSecond = 0;
  lastReportMs = nowMs;
  sendState();
  sendStatistics();
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
