// Wokwi custom chip: ST VL53L1X time-of-flight sensor (register-level emulation).
//
// Emulates enough of the VL53L1X I2C interface for the Pololu VL53L1X Arduino
// library, so the real SlidePod firmware (not a mock) runs against it:
//   - 16-bit register addresses, auto-increment reads and writes, address 0x29
//   - model ID 0xEACC, boot status, oscillator calibration values
//   - SOFT_RESET, SYSTEM__MODE_START (timed / single-shot / abort)
//   - measurements every SYSTEM__INTERMEASUREMENT_PERIOD / osc_calibrate_val ms
//   - result block at 0x0089 (range status 9 = valid, stream count, range in
//     the sensor's 2048/2011 scale), GPIO__TIO_HV_STATUS bit 0 = data ready,
//     SYSTEM__INTERRUPT_CLEAR
//   - XSHUT low = sensor off (NACKs, forgets its configuration)
//   - GPIO1 driven low while a result is waiting (the INT line)
//
// Not emulated: ROI geometry, signal strength vs distance, ambient light,
// crosstalk. Distance, noise and maximum range come from the part's controls.
//
// Build: see sim/wokwi-rev2/Makefile (clang --target=wasm32, no libc).

#include "wokwi-api.h"

#define REG_FILE_SIZE 1024   // all registers the driver touches are below 0x0200
#define REG_MASK (REG_FILE_SIZE - 1)

enum {
  SOFT_RESET = 0x0000,
  OSC_MEASURED__FAST_OSC__FREQUENCY = 0x0006,
  VHV_CONFIG__INIT = 0x000B,
  GPIO__TIO_HV_STATUS = 0x0031,
  RANGE_CONFIG__TIMEOUT_MACROP_A = 0x005E,
  RANGE_CONFIG__VCSEL_PERIOD_A = 0x0060,
  RANGE_CONFIG__TIMEOUT_MACROP_B = 0x0061,
  RANGE_CONFIG__VCSEL_PERIOD_B = 0x0063,
  SYSTEM__INTERMEASUREMENT_PERIOD = 0x006C,
  SYSTEM__INTERRUPT_CLEAR = 0x0086,
  SYSTEM__MODE_START = 0x0087,
  RESULT__RANGE_STATUS = 0x0089,
  RESULT__OSC_CALIBRATE_VAL = 0x00DE,
  FIRMWARE__SYSTEM_STATUS = 0x00E5,
  PHASECAL_RESULT__VCSEL_START = 0x00D8,
  IDENTIFICATION__MODEL_ID = 0x010F,
};

enum { MODE_IDLE, MODE_TIMED, MODE_SINGLE };

typedef struct {
  uint8_t regs[REG_FILE_SIZE];
  pin_t xshut;
  pin_t gpio1;
  uint32_t attr_distance;
  uint32_t attr_noise;
  uint32_t attr_max_range;
  timer_t timer;
  uint16_t ptr;          // register pointer
  uint8_t addr_bytes;    // address bytes received in the current write
  bool online;           // XSHUT high
  int mode;
  bool data_ready;
  uint8_t stream_count;
  uint32_t rng;
} chip_state_t;

static chip_state_t chip;

// clang may emit calls to these even without libc
void *memset(void *d, int c, unsigned long n) {
  uint8_t *p = (uint8_t *)d;
  while (n--) *p++ = (uint8_t)c;
  return d;
}
void *memcpy(void *d, const void *s, unsigned long n) {
  uint8_t *p = (uint8_t *)d;
  const uint8_t *q = (const uint8_t *)s;
  while (n--) *p++ = *q++;
  return d;
}

static uint8_t *reg(uint16_t a) { return &chip.regs[a & REG_MASK]; }
static void put16(uint16_t a, uint16_t v) { *reg(a) = v >> 8; *reg(a + 1) = v & 0xff; }
static uint16_t get16(uint16_t a) { return (uint16_t)(*reg(a) << 8 | *reg(a + 1)); }
static uint32_t get32(uint16_t a) { return (uint32_t)get16(a) << 16 | get16(a + 2); }

static void set_int(bool ready) {
  chip.data_ready = ready;
  uint8_t v = *reg(GPIO__TIO_HV_STATUS);
  // Pololu dataReady(): (TIO_HV_STATUS & 1) == 0 means a result is waiting.
  *reg(GPIO__TIO_HV_STATUS) = ready ? (v & ~1) : (v | 1);
  pin_write(chip.gpio1, ready ? LOW : HIGH);
}

static void reset_defaults(void) {
  memset(chip.regs, 0, sizeof chip.regs);
  *reg(IDENTIFICATION__MODEL_ID) = 0xEA;      // model ID 0xEACC
  *reg(IDENTIFICATION__MODEL_ID + 1) = 0xCC;
  *reg(IDENTIFICATION__MODEL_ID + 2) = 0x10;  // mask revision
  *reg(FIRMWARE__SYSTEM_STATUS) = 0x01;       // booted
  put16(OSC_MEASURED__FAST_OSC__FREQUENCY, 0xB2E0);  // non-zero: timing maths divide by it
  put16(RESULT__OSC_CALIBRATE_VAL, 500);      // ticks per ms for the inter-measurement period
  *reg(VHV_CONFIG__INIT) = 0x20;
  *reg(RANGE_CONFIG__VCSEL_PERIOD_A) = 0x0B;
  *reg(RANGE_CONFIG__VCSEL_PERIOD_B) = 0x09;
  put16(RANGE_CONFIG__TIMEOUT_MACROP_A, 0x01CC);
  put16(RANGE_CONFIG__TIMEOUT_MACROP_B, 0x01F5);
  *reg(PHASECAL_RESULT__VCSEL_START) = 0x0B;
  *reg(GPIO__TIO_HV_STATUS) = 0x03;
  chip.mode = MODE_IDLE;
  chip.stream_count = 0;
  chip.data_ready = false;
  timer_stop(chip.timer);
  pin_write(chip.gpio1, HIGH);
}

static float noise_unit(void) {
  chip.rng = chip.rng * 1664525u + 1013904223u;
  return (float)((chip.rng >> 8) & 0xFFFF) / 32767.5f - 1.0f;   // -1 .. 1
}

static void measure(void) {
  float d = attr_read_float(chip.attr_distance) + attr_read_float(chip.attr_noise) * noise_unit();
  float max_range = attr_read_float(chip.attr_max_range);
  if (d < 0) d = 0;

  uint8_t status = 9;                 // RANGECOMPLETE
  if (d > max_range) status = 4;      // MSRCNOTARGET -> SignalFail
  uint16_t raw = (uint16_t)(d * 2048.0f / 2011.0f + 0.5f);   // driver scales by 2011/2048

  uint16_t r = RESULT__RANGE_STATUS;
  *reg(r + 0) = status;
  *reg(r + 1) = 0;                    // report status
  *reg(r + 2) = chip.stream_count;    // first result after start is 0, like the real part
  put16(r + 3, 0x2000);               // effective SPADs (8.8 fixed point)
  put16(r + 5, status == 9 ? 0x0F00 : 0x0010);   // peak signal rate
  put16(r + 7, 0x0040);               // ambient rate
  put16(r + 9, 0x0010);               // sigma
  put16(r + 11, 0x0400);              // phase
  put16(r + 13, status == 9 ? raw : 0);
  put16(r + 15, status == 9 ? 0x0F00 : 0x0010);
  chip.stream_count = chip.stream_count == 255 ? 128 : chip.stream_count + 1;

  set_int(true);
  if (chip.mode == MODE_SINGLE) chip.mode = MODE_IDLE;
}

static void on_timer(void *user_data) {
  (void)user_data;
  if (chip.online && chip.mode != MODE_IDLE) measure();
}

static uint32_t period_us(void) {
  uint32_t ticks = get32(SYSTEM__INTERMEASUREMENT_PERIOD);
  uint32_t cal = get16(RESULT__OSC_CALIBRATE_VAL);
  uint32_t ms = cal ? ticks / cal : 0;
  if (ms < 5) ms = 20;
  return ms * 1000;
}

static void reg_write(uint16_t a, uint8_t v) {
  a &= REG_MASK;
  switch (a) {
    case SOFT_RESET:
      if (v & 1) reset_defaults();     // 0 = hold in reset, 1 = boot
      else { chip.mode = MODE_IDLE; timer_stop(chip.timer); }
      *reg(SOFT_RESET) = v;
      return;
    case GPIO__TIO_HV_STATUS:          // the driver writes 0x02 here; bit 0 stays ours
      *reg(a) = (v & ~1) | (chip.data_ready ? 0 : 1);
      return;
    case SYSTEM__INTERRUPT_CLEAR:
      if (v & 1) set_int(false);
      return;
    case SYSTEM__MODE_START:
      *reg(a) = v;
      if (v & 0x80) {                  // abort
        chip.mode = MODE_IDLE;
        timer_stop(chip.timer);
      } else if (v & 0x40) {           // timed (continuous)
        chip.mode = MODE_TIMED;
        chip.stream_count = 0;
        timer_start(chip.timer, period_us(), true);
      } else if (v & 0x10) {           // single shot
        chip.mode = MODE_SINGLE;
        timer_start(chip.timer, 20000, false);
      }
      return;
    default:
      *reg(a) = v;
  }
}

// ---- I2C -------------------------------------------------------------------

static bool on_i2c_connect(void *user_data, uint32_t address, bool read) {
  (void)user_data; (void)address; (void)read;
  chip.addr_bytes = 0;                 // a new transaction starts with the register address
  return chip.online;                  // NACK while XSHUT is low
}

static bool on_i2c_write(void *user_data, uint8_t data) {
  (void)user_data;
  if (chip.addr_bytes == 0) {
    chip.ptr = (uint16_t)data << 8;
    chip.addr_bytes = 1;
  } else if (chip.addr_bytes == 1) {
    chip.ptr |= data;
    chip.addr_bytes = 2;
  } else {
    reg_write(chip.ptr++, data);
  }
  return true;
}

static uint8_t on_i2c_read(void *user_data) {
  (void)user_data;
  return *reg(chip.ptr++);
}

static void on_i2c_disconnect(void *user_data) { (void)user_data; }

// ---- XSHUT -----------------------------------------------------------------

static void on_xshut(void *user_data, pin_t pin, uint32_t value) {
  (void)user_data; (void)pin;
  chip.online = value == HIGH;
  reset_defaults();                    // off: configuration lost; on: fresh boot
}

void chip_init(void) {
  chip.rng = 0x5EED1234u;
  chip.attr_distance = attr_init_float("distance", 120.0f);
  chip.attr_noise = attr_init_float("noise", 1.5f);
  chip.attr_max_range = attr_init_float("maxRange", 1300.0f);

  chip.gpio1 = pin_init("GPIO1", OUTPUT_HIGH);
  chip.xshut = pin_init("XSHUT", INPUT);

  const timer_config_t tcfg = {.user_data = &chip, .callback = on_timer};
  chip.timer = timer_init(&tcfg);

  reset_defaults();
  chip.online = pin_read(chip.xshut) == HIGH;

  const pin_watch_config_t wcfg = {.user_data = &chip, .edge = BOTH, .pin_change = on_xshut};
  pin_watch(chip.xshut, &wcfg);

  const i2c_config_t icfg = {
    .user_data = &chip,
    .address = 0x29,
    .scl = pin_init("SCL", INPUT),
    .sda = pin_init("SDA", INPUT),
    .connect = on_i2c_connect,
    .read = on_i2c_read,
    .write = on_i2c_write,
    .disconnect = on_i2c_disconnect,
  };
  i2c_init(&icfg);
}
