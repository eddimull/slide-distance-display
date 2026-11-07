"""SlidePod circuit definition: the single source for the schematic, netlist, PCB and BOM.

Each part: ref, lib_id, value, footprint, pin->net map, block, extra fields.
Pins absent from the map get a no-connect flag.
"""

R0402 = "Resistor_SMD:R_0402_1005Metric"
C0402 = "Capacitor_SMD:C_0402_1005Metric"
C0603 = "Capacitor_SMD:C_0603_1608Metric"


class Part:
    def __init__(self, ref, lib_id, value, footprint, pins, block, lcsc="", dnp=False, note=""):
        self.ref, self.lib_id, self.value, self.footprint = ref, lib_id, value, footprint
        self.pins, self.block, self.lcsc, self.dnp, self.note = pins, block, lcsc, dnp, note


PARTS = []


def P(*a, **k):
    PARTS.append(Part(*a, **k))


# JLC Basic passives (checked on jlcpcb.com/partdetail, 2026-11). Keep values to this list
# where possible: each value outside it is an Extended part with a setup fee.
LCSC_R0402 = {"33": "C25105", "1k": "C11702", "3.3k": "C25890", "4.7k": "C25900", "5.1k": "C25905",
              "10k": "C25744", "47k": "C25792", "100k": "C25741", "1M": "C26083"}
LCSC_C = {("10n", C0402): "C15195", ("100n", C0402): "C1525", ("1u", C0402): "C52923",
          ("4.7u", C0603): "C19666", ("10u", C0603): "C19702"}


def R(ref, val, a, b, block, **k):
    k.setdefault("lcsc", LCSC_R0402.get(val, ""))
    P(ref, "Device:R", val, R0402, {"1": a, "2": b}, block, **k)


def C(ref, val, a, b, block, fp=C0402, **k):
    k.setdefault("lcsc", LCSC_C.get((val, fp), ""))
    P(ref, "Device:C", val, fp, {"1": a, "2": b}, block, **k)


# ---------------------------------------------------------------- USB / charger / power
P("J1", "Connector:USB_C_Receptacle_USB2.0_16P", "USB-C",
  "Connector_USB:USB_C_Receptacle_HRO_TYPE-C-31-M-12",
  {**{p: "GND" for p in ("A1", "A12", "B1", "B12", "S1")},
   **{p: "VBUS" for p in ("A4", "A9", "B4", "B9")},
   "A5": "CC1", "B5": "CC2", "A6": "USB_DP", "B6": "USB_DP", "A7": "USB_DM", "B7": "USB_DM"},
  "power", lcsc="C165948")
R("R1", "5.1k", "CC1", "GND", "power")
R("R2", "5.1k", "CC2", "GND", "power")
P("U6", "Power_Protection:USBLC6-2SC6", "USBLC6-2SC6", "Package_TO_SOT_SMD:SOT-23-6",
  {"1": "USB_DM", "6": "USB_DM", "3": "USB_DP", "4": "USB_DP", "5": "VBUS", "2": "GND"},
  "power", lcsc="C7519")

P("U3", "Battery_Management:MCP73831-2-OT", "MCP73831-2", "Package_TO_SOT_SMD:SOT-23-5",
  {"4": "VBUS", "2": "GND", "3": "VBAT", "5": "PROG", "1": "CHG_STAT"}, "power", lcsc="C424093")
C("C1", "4.7u", "VBUS", "GND", "power", fp=C0603)
C("C2", "4.7u", "VBAT", "GND", "power", fp=C0603)
R("R3", "3.3k", "PROG", "GND", "power", note="I_chg = 1000/R = ~300 mA")
R("R4", "1k", "VBUS", "CHG_LED_A", "power")
P("D3", "Device:LED", "CHG red", "LED_SMD:LED_0603_1608Metric",
  {"2": "CHG_LED_A", "1": "CHG_STAT"}, "power", lcsc="C2286")

P("J2", "Connector_Generic:Conn_01x02", "LiPo 1S", "Connector_JST:JST_PH_S2B-PH-SM4-TB_1x02-1MP_P2.00mm_Horizontal",
  {"1": "VBAT", "2": "GND"}, "power", lcsc="C295747",
  note="Check battery lead polarity, JST-PH vendors differ")

# Power path: VBUS via Schottky, battery via P-FET (off while VBUS present)
P("D2", "Device:D_Schottky", "B5819W", "Diode_SMD:D_SOD-123", {"1": "VSYS_IN", "2": "VBUS"}, "power",
  lcsc="C8598")
P("Q1", "Transistor_FET:AO3401A", "AO3401A", "Package_TO_SOT_SMD:SOT-23",
  {"1": "VBUS", "2": "VSYS_IN", "3": "VBAT"}, "power", lcsc="C15127")
R("R5", "100k", "VBUS", "GND", "power", note="Q1 gate pull-down")
P("SW3", "Switch:SW_SPDT", "MSK12C02", "Button_Switch_SMD:SW_SPDT_Shouhan_MSK12C02",
  {"1": "VSYS_IN", "2": "VSYS"}, "power", lcsc="C431540")

P("U4", "Regulator_Linear:ME6211C33M5", "ME6211C33", "Package_TO_SOT_SMD:SOT-23-5",
  {"1": "VSYS", "3": "VSYS", "2": "GND", "5": "+3V3"}, "power", lcsc="C82942")
C("C3", "10u", "VSYS", "GND", "power", fp=C0603)
C("C4", "10u", "+3V3", "GND", "power", fp=C0603)

R("R6", "1M", "VBAT", "VBAT_SENSE", "power")
R("R7", "1M", "VBAT_SENSE", "GND", "power")
C("C5", "100n", "VBAT_SENSE", "GND", "power")
R("R8", "100k", "VBUS", "VBUS_SENSE", "power")
R("R9", "100k", "VBUS_SENSE", "GND", "power", note="5 V -> 2.5 V")

# ---------------------------------------------------------------- MCU
esp = {"3": "+3V3", "45": "EN", "4": "BOOT",
       "5": "PIEZO_ADC", "6": "VBAT_SENSE", "8": "TOF_INT", "9": "TOF_XSHUT",
       "12": "I2C_SDA", "13": "I2C_SCL", "14": "VBUS_SENSE",
       "15": "LED_R", "16": "LED_G", "17": "LED_B",
       "23": "USB_DM", "24": "USB_DP", "39": "U0TXD", "40": "U0RXD"}
for g in [1, 2] + list(range(42, 44)) + list(range(46, 66)):
    esp[str(g)] = "GND"
P("U1", "RF_Module:ESP32-S3-MINI-1", "ESP32-S3-MINI-1-N8", "RF_Module:ESP32-S2-MINI-1",
  esp, "mcu", lcsc="C2913206")
C("C6", "10u", "+3V3", "GND", "mcu", fp=C0603)
C("C7", "100n", "+3V3", "GND", "mcu")
C("C8", "100n", "+3V3", "GND", "mcu")
R("R10", "10k", "+3V3", "EN", "mcu")
C("C9", "1u", "EN", "GND", "mcu")
R("R11", "10k", "+3V3", "BOOT", "mcu")
P("SW1", "Switch:SW_Push", "RESET", "Button_Switch_SMD:SW_Push_1P1T_XKB_TS-1187A",
  {"1": "EN", "2": "GND"}, "mcu", lcsc="C318884")
P("SW2", "Switch:SW_Push", "BOOT", "Button_Switch_SMD:SW_Push_1P1T_XKB_TS-1187A",
  {"1": "BOOT", "2": "GND"}, "mcu", lcsc="C318884")

# Status indicator: three discrete 0603 LEDs, anodes to 3V3, cathodes sunk by GPIOs (active-low).
# A combined RGB package was dropped: no JLC common-anode part had a pinout we could verify.
LED0603 = "LED_SMD:LED_0603_1608Metric"
P("LED1", "Device:LED", "red", LED0603, {"2": "+3V3", "1": "LED_RK"}, "mcu", lcsc="C2286")
P("LED2", "Device:LED", "green", LED0603, {"2": "+3V3", "1": "LED_GK"}, "mcu", lcsc="C12624",
  note="KENTO KT-0603G, Extended (no Basic green 0603 at JLC)")
P("LED3", "Device:LED", "blue", LED0603, {"2": "+3V3", "1": "LED_BK"}, "mcu", lcsc="C2288",
  note="KENTO KT-0603B, Extended (no Basic blue 0603 at JLC)")
R("R12", "1k", "LED_RK", "LED_R", "mcu", note="red Vf~2.0 V: ~1.3 mA")
R("R13", "33", "LED_GK", "LED_G", "mcu")
R("R14", "33", "LED_BK", "LED_B", "mcu")

# ---------------------------------------------------------------- ToF
P("U2", "Sensor_Distance:VL53L1CXV0FY1", "VL53L1CX", "Sensor_Distance:ST_VL53L1x",
  {"11": "+3V3", "1": "+3V3", "2": "GND", "3": "GND", "4": "GND", "6": "GND", "12": "GND",
   "9": "I2C_SDA", "10": "I2C_SCL", "5": "TOF_XSHUT", "7": "TOF_INT"}, "tof", lcsc="C190004")
C("C10", "100n", "+3V3", "GND", "tof", note="at AVDDVCSEL")
C("C11", "4.7u", "+3V3", "GND", "tof", fp=C0603)
C("C12", "100n", "+3V3", "GND", "tof", note="at AVDD")
R("R15", "4.7k", "+3V3", "I2C_SDA", "tof")
R("R16", "4.7k", "+3V3", "I2C_SCL", "tof")
R("R17", "10k", "+3V3", "TOF_XSHUT", "tof")
R("R18", "10k", "+3V3", "TOF_INT", "tof")

# ---------------------------------------------------------------- Piezo front end
P("J3", "Connector_Generic:Conn_01x02", "PIEZO", "Connector_Wire:SolderWire-0.1sqmm_1x02_P3.6mm_D0.4mm_OD1mm",
  {"1": "PIEZO_P", "2": "GND"}, "piezo")
R("R19", "1M", "PIEZO_P", "VBIAS", "piezo", note="with ~15 nF piezo: HP corner ~10 Hz")
R("R20", "1k", "PIEZO_P", "OPA_IN", "piezo")
P("D1", "Diode:BAT54S", "BAT54S", "Package_TO_SOT_SMD:SOT-23",
  {"1": "GND", "2": "+3V3", "3": "OPA_IN"}, "piezo", lcsc="C47546")
R("R21", "100k", "+3V3", "VBIAS", "piezo")
R("R22", "100k", "VBIAS", "GND", "piezo")
C("C13", "10u", "VBIAS", "GND", "piezo", fp=C0603)
P("U5", "Amplifier_Operational:MCP6001-OT", "MCP6001", "Package_TO_SOT_SMD:SOT-23-5",
  {"3": "OPA_IN", "4": "OPA_FB", "1": "OPA_OUT", "5": "+3V3", "2": "GND"}, "piezo", lcsc="C116490")
C("C14", "100n", "+3V3", "GND", "piezo")
R("R23", "100k", "OPA_OUT", "OPA_FB", "piezo", note="Rf: gain = 1 + Rf/Rg")
R("R24", "47k", "OPA_OUT", "OPA_FB", "piezo", dnp=True, note="Rf alt, fit in parallel to drop gain")
R("R25", "10k", "OPA_FB", "OPA_RG", "piezo")
C("C15", "1u", "OPA_RG", "VBIAS", "piezo")
R("R26", "1k", "OPA_OUT", "PIEZO_ADC", "piezo")
C("C16", "10n", "PIEZO_ADC", "GND", "piezo")

# ---------------------------------------------------------------- Test points
for i, net in enumerate(["+3V3", "VSYS", "VBAT", "GND", "PIEZO_ADC", "U0TXD", "U0RXD"], 1):
    P(f"TP{i}", "Connector:TestPoint", net, "TestPoint:TestPoint_Pad_D1.0mm", {"1": net}, "test")

# Nets that need a PWR_FLAG (driven only by passive pins)
PWR_FLAGS = ["GND", "VBUS", "VSYS"]

BLOCK_TITLES = {"power": "USB-C, charger, power path, 3.3 V", "mcu": "ESP32-S3-MINI-1, buttons, RGB LED",
                "tof": "VL53L1X time-of-flight", "piezo": "Piezo contact-pickup front end",
                "test": "Test points"}
