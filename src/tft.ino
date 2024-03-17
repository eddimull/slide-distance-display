#include "Arduino.h"
#include "TFT_eSPI.h" /* Please use the TFT library provided in the library. */
#include "pin_config.h"
#include "em_ultrasonic.h"
#include "OneButton.h"
#include "color_rectangle_sprite.h"

/* The product now has two screens, and the initialization code needs a small change in the new version. The LCD_MODULE_CMD_1 is used to define the
 * switch macro. */
#define LCD_MODULE_CMD_1
#define BUTTON_INPUT 0

TFT_eSPI tft = TFT_eSPI();
ColorRectangleSprite *colorRectangleSprite;
#define WAIT 5000
unsigned long targetTime = 0; // Used for testing draw times

#if defined(LCD_MODULE_CMD_1)
typedef struct
{
    uint8_t cmd;
    uint8_t data[14];
    uint8_t len;
} lcd_cmd_t;

lcd_cmd_t lcd_st7789v[] = {
    {0x11, {0}, 0 | 0x80},
    {0x3A, {0X05}, 1},
    {0xB2, {0X0B, 0X0B, 0X00, 0X33, 0X33}, 5},
    {0xB7, {0X75}, 1},
    {0xBB, {0X28}, 1},
    {0xC0, {0X2C}, 1},
    {0xC2, {0X01}, 1},
    {0xC3, {0X1F}, 1},
    {0xC6, {0X13}, 1},
    {0xD0, {0XA7}, 1},
    {0xD0, {0XA4, 0XA1}, 2},
    {0xD6, {0XA1}, 1},
    {0xE0, {0XF0, 0X05, 0X0A, 0X06, 0X06, 0X03, 0X2B, 0X32, 0X43, 0X36, 0X11, 0X10, 0X2B, 0X32}, 14},
    {0xE1, {0XF0, 0X08, 0X0C, 0X0B, 0X09, 0X24, 0X2B, 0X22, 0X43, 0X38, 0X15, 0X16, 0X2F, 0X37}, 14},
};
#endif
OneButton button(BUTTON_INPUT, true);
MySensor ultrasonic(12, 13); // An ultrasonic sensor HC-04

const int MAX_DISTANCE = 80; // Maximum distance in centimeters
const int NUM_READINGS = 5;  // Number of readings to average

float readings[NUM_READINGS]; // Array to store the readings
int readIndex = 0;            // Index of the current reading
int total = 0;                // Running total of readings
float average = 0;            // Calculated average distance

int backgroundColors[] = {TFT_BLACK, TFT_BLUE, TFT_RED, TFT_GREEN, TFT_CYAN, TFT_MAGENTA, TFT_YELLOW, TFT_WHITE};
int backgroundColorsIndex = 0;
int currentBackgroundColor = backgroundColors[backgroundColorsIndex];
String previousAverage = "";
String previousRatio = "";
void setup()
{
    pinMode(PIN_POWER_ON, OUTPUT);
    digitalWrite(PIN_POWER_ON, HIGH);

    Serial.begin(115200);
    Serial.println("Hello T-Display-S3");
    tft.begin();

#if defined(LCD_MODULE_CMD_1)
    for (uint8_t i = 0; i < (sizeof(lcd_st7789v) / sizeof(lcd_cmd_t)); i++)
    {
        tft.writecommand(lcd_st7789v[i].cmd);
        for (int j = 0; j < (lcd_st7789v[i].len & 0x7f); j++)
        {
            tft.writedata(lcd_st7789v[i].data[j]);
        }

        if (lcd_st7789v[i].len & 0x80)
        {
            delay(120);
        }
    }
#endif

    tft.setRotation(3);
    tft.setSwapBytes(false);

#if ESP_IDF_VERSION < ESP_IDF_VERSION_VAL(5, 0, 0)
    ledcSetup(0, 2000, 8);
    ledcAttachPin(PIN_LCD_BL, 0);
    ledcWrite(0, 255);
#else
    ledcAttach(PIN_LCD_BL, 200, 8);
    ledcWrite(PIN_LCD_BL, 255);
#endif
    button.attachClick(changeBackgroundColor);

    colorRectangleSprite = new ColorRectangleSprite(tft);
}
void changeBackgroundColor()
{
    backgroundColorsIndex++;
    if (backgroundColorsIndex >= sizeof(backgroundColors) / sizeof(int))
    {
        backgroundColorsIndex = 0;
    }
}
float positionPercent = 0;
void loop()
{
    // button.tick();
    // // if (currentBackgroundColor != backgroundColors[backgroundColorsIndex])
    // // {
    // //     currentBackgroundColor = backgroundColors[backgroundColorsIndex];
    // //     tft.fillScreen(currentBackgroundColor);
    // // }
    // targetTime = millis();
    // tft.setTextSize(3);
    // tft.setTextColor(TFT_GREEN, TFT_BLACK);
    double distance = ultrasonic.read();
    if (distance > MAX_DISTANCE)
    {
        return;
    }

    float ratio = distance / MAX_DISTANCE;
    // Serial.println(String(ratio));
    // // // Display the average distance on the TFT screen
    // // Write the new text
    // String averageStr = String(average) + " cm";
    // String ratioStr = String(static_cast<int>(ratio * 100)) + "%";
    // Only redraw the text if it's different from the previous text
    // if (averageStr != previousAverage)
    // {
    //     // Overwrite the old text with spaces
    //     tft.drawString("      ", 0, 0, 2);
    //     // Write the new text
    //     tft.drawString(averageStr, 0, 0, 2);
    //     // Store the new string for the next loop iteration
    //     previousAverage = averageStr;
    // }

    // if (ratioStr != previousRatio)
    // {
    //     // Overwrite the old text with spaces
    //     tft.drawRightString("       ", tft.width(), 0, 2);
    //     // Write the new text
    //     tft.drawRightString(ratioStr, tft.width(), 0, 2);
    //     // Store the new string for the next loop iteration
    //     previousRatio = ratioStr;
    // }
    // positionPercent += 0.01;
    // if (positionPercent >= 1)
    // {
    //     positionPercent = 0;
    // }

    colorRectangleSprite->setPosition(ratio);
}

// TFT Pin check
#if PIN_LCD_WR != TFT_WR ||     \
    PIN_LCD_RD != TFT_RD ||     \
    PIN_LCD_CS != TFT_CS ||     \
    PIN_LCD_DC != TFT_DC ||     \
    PIN_LCD_RES != TFT_RST ||   \
    PIN_LCD_D0 != TFT_D0 ||     \
    PIN_LCD_D1 != TFT_D1 ||     \
    PIN_LCD_D2 != TFT_D2 ||     \
    PIN_LCD_D3 != TFT_D3 ||     \
    PIN_LCD_D4 != TFT_D4 ||     \
    PIN_LCD_D5 != TFT_D5 ||     \
    PIN_LCD_D6 != TFT_D6 ||     \
    PIN_LCD_D7 != TFT_D7 ||     \
    PIN_LCD_BL != TFT_BL ||     \
    TFT_BACKLIGHT_ON != HIGH || \
    170 != TFT_WIDTH ||         \
    320 != TFT_HEIGHT
#error "Error! Please make sure <User_Setups/Setup206_LilyGo_T_Display_S3.h> is selected in <TFT_eSPI/User_Setup_Select.h>"
#error "Error! Please make sure <User_Setups/Setup206_LilyGo_T_Display_S3.h> is selected in <TFT_eSPI/User_Setup_Select.h>"
#error "Error! Please make sure <User_Setups/Setup206_LilyGo_T_Display_S3.h> is selected in <TFT_eSPI/User_Setup_Select.h>"
#error "Error! Please make sure <User_Setups/Setup206_LilyGo_T_Display_S3.h> is selected in <TFT_eSPI/User_Setup_Select.h>"
#endif

#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 0, 0)
#error "The current version is not supported for the time being, please use a version below Arduino ESP32 3.0"
#endif