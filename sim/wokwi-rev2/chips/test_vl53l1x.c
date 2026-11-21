// Native test for vl53l1x.chip.c: fakes the Wokwi API and replays the register traffic
// of the Pololu VL53L1X driver (init, Short/15 ms/19 ms start, read, abort).
//   make -C sim/wokwi-rev2 test
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define chip_init chip_init_impl
#include "vl53l1x.chip.c"
#undef chip_init

// ---- fake Wokwi API -----------------------------------------------------------
static i2c_config_t g_i2c;
static timer_config_t g_timer;
static bool g_timer_running;
static uint32_t g_timer_period;
static uint32_t g_pins[8];
static float g_attr[8];
static int g_nattr;
static pin_watch_config_t g_watch;

pin_t pin_init(const char *name, uint32_t mode) {
  static int n;
  (void)name;
  g_pins[n] = (mode == OUTPUT_HIGH || mode == INPUT) ? HIGH : LOW;
  return n++;
}
uint32_t pin_read(pin_t p) { return g_pins[p]; }
void pin_write(pin_t p, uint32_t v) { g_pins[p] = v; }
bool pin_watch(pin_t p, const pin_watch_config_t *c) { (void)p; g_watch = *c; return true; }
uint32_t attr_init_float(const char *name, float def) { (void)name; g_attr[g_nattr] = def; return g_nattr++; }
float attr_read_float(uint32_t id) { return g_attr[id]; }
timer_t timer_init(const timer_config_t *c) { g_timer = *c; return 1; }
void timer_start(const timer_t t, uint32_t us, bool repeat) { (void)t; (void)repeat; g_timer_running = true; g_timer_period = us; }
void timer_stop(const timer_t t) { (void)t; g_timer_running = false; }
i2c_dev_t i2c_init(const i2c_config_t *c) { g_i2c = *c; return 1; }
// unused by the chip but declared in the header
uint32_t attr_init(const char *n, uint32_t d) { (void)n; (void)d; return 0; }
uint32_t attr_read(uint32_t id) { (void)id; return 0; }
void pin_mode(pin_t p, uint32_t v) { (void)p; (void)v; }
void pin_watch_stop(pin_t p) { (void)p; }
float pin_adc_read(pin_t p) { (void)p; return 0; }
float pin_dac_write(pin_t p, float v) { (void)p; return v; }
void timer_start_ns_d(const timer_t t, double n, bool r) { (void)t; (void)n; (void)r; }
double get_sim_nanos_d(void) { return 0; }

// ---- driver-style register access -------------------------------------------------
static bool wr(uint16_t reg_addr, const uint8_t *data, int n) {
  if (!g_i2c.connect(g_i2c.user_data, 0x29, false)) return false;
  g_i2c.write(g_i2c.user_data, reg_addr >> 8);
  g_i2c.write(g_i2c.user_data, reg_addr & 0xff);
  for (int i = 0; i < n; i++) g_i2c.write(g_i2c.user_data, data[i]);
  g_i2c.disconnect(g_i2c.user_data);
  return true;
}
static void rd(uint16_t reg_addr, uint8_t *out, int n) {
  wr(reg_addr, NULL, 0);
  g_i2c.connect(g_i2c.user_data, 0x29, true);
  for (int i = 0; i < n; i++) out[i] = g_i2c.read(g_i2c.user_data);
  g_i2c.disconnect(g_i2c.user_data);
}
static uint8_t rd8(uint16_t a) { uint8_t b; rd(a, &b, 1); return b; }
static uint16_t rd16(uint16_t a) { uint8_t b[2]; rd(a, b, 2); return b[0] << 8 | b[1]; }
static void wr8(uint16_t a, uint8_t v) { wr(a, &v, 1); }
static void wr32(uint16_t a, uint32_t v) { uint8_t b[4] = {v >> 24, v >> 16, v >> 8, v}; wr(a, b, 4); }

static uint16_t read_range(uint8_t *status, uint8_t *stream) {
  uint8_t r[17];
  rd(RESULT__RANGE_STATUS, r, 17);
  *status = r[0];
  *stream = r[2];
  uint16_t raw = r[13] << 8 | r[14];
  wr8(SYSTEM__INTERRUPT_CLEAR, 1);
  return (uint16_t)(((uint32_t)raw * 2011 + 0x400) / 0x800);   // Pololu getRangingData()
}

int main(void) {
  chip_init_impl();

  // XSHUT low: sensor must NACK
  g_watch.pin_change(g_watch.user_data, chip.xshut, LOW);
  assert(!wr(0x010F, NULL, 0));
  g_watch.pin_change(g_watch.user_data, chip.xshut, HIGH);

  // init()
  assert(rd16(IDENTIFICATION__MODEL_ID) == 0xEACC);
  wr8(SOFT_RESET, 0);
  wr8(SOFT_RESET, 1);
  assert(rd8(FIRMWARE__SYSTEM_STATUS) & 1);
  assert(rd16(OSC_MEASURED__FAST_OSC__FREQUENCY) != 0);
  uint16_t osc_cal = rd16(RESULT__OSC_CALIBRATE_VAL);
  assert(osc_cal != 0);
  wr8(GPIO__TIO_HV_STATUS, 0x02);
  assert((rd8(GPIO__TIO_HV_STATUS) & 1) == 1);          // not ready yet

  // startContinuous(19)
  wr32(SYSTEM__INTERMEASUREMENT_PERIOD, 19 * osc_cal);
  wr8(SYSTEM__INTERRUPT_CLEAR, 1);
  wr8(SYSTEM__MODE_START, 0x40);
  assert(g_timer_running && g_timer_period == 19000);

  g_attr[chip.attr_noise] = 0;                           // deterministic
  g_attr[chip.attr_distance] = 250;
  uint8_t st, sc;
  g_timer.callback(g_timer.user_data);
  assert((rd8(GPIO__TIO_HV_STATUS) & 1) == 0);           // dataReady()
  assert(g_pins[chip.gpio1] == LOW);                     // INT asserted
  uint16_t mm = read_range(&st, &sc);
  assert(st == 9 && sc == 0);                            // first reading: stream 0 (driver: no wrap check)
  assert((rd8(GPIO__TIO_HV_STATUS) & 1) == 1 && g_pins[chip.gpio1] == HIGH);
  g_timer.callback(g_timer.user_data);
  mm = read_range(&st, &sc);
  printf("distance 250 mm -> driver reads %u mm (status %u, stream %u)\n", mm, st, sc);
  assert(st == 9 && sc == 1 && mm >= 249 && mm <= 251);

  // beyond max range -> signal fail
  g_attr[chip.attr_distance] = 1350;
  g_timer.callback(g_timer.user_data);
  read_range(&st, &sc);
  assert(st == 4);

  // abort
  wr8(SYSTEM__MODE_START, 0x80);
  assert(!g_timer_running);

  printf("vl53l1x chip: all checks passed\n");
  return 0;
}
