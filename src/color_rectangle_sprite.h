#include <TFT_eSPI.h>

class ColorRectangleSprite
{
private:
    TFT_eSPI &tft;
    TFT_eSprite sprite;
    int spriteWidth;
    int screenHeight;
    int screenWidth;
    int colorWidth;
    int const numberOfColors = 7;

    int rectColors[7];

    void drawColorRectangle(int position)
    {
        for (int i = 0; i <= numberOfColors - 1; i++)
        {
            sprite.fillRect((i * colorWidth) + position, screenHeight / 3, colorWidth, screenHeight / 3, this->rectColors[i]);
        }
    }

public:
    ColorRectangleSprite(TFT_eSPI &display, int rectColors[7] = nullptr) : tft(display), sprite(&tft)
    {
        if (rectColors != nullptr)
        {
            for (int i = 0; i < numberOfColors; i++)
            {
                this->rectColors[i] = rectColors[i];
            }
        }
        else
        {
            this->rectColors[0] = TFT_BLACK;
            this->rectColors[1] = TFT_RED;
            this->rectColors[2] = TFT_ORANGE;
            this->rectColors[3] = TFT_YELLOW;
            this->rectColors[4] = TFT_GREEN;
            this->rectColors[5] = TFT_BLUE;
            this->rectColors[6] = TFT_VIOLET;
        }

        screenWidth = tft.width();
        screenHeight = tft.height();
        spriteWidth = screenWidth * numberOfColors;
        colorWidth = spriteWidth / numberOfColors;

        sprite.createSprite(spriteWidth, screenHeight); // Create a sprite that is 7 times the width of the screen
    }

    void setPosition(float percent)
    {
        int position = -(percent * spriteWidth - screenWidth);
        // sprite.fillRect(0, 0, screenWidth, screenHeight, TFT_BLACK); // Clear the sprite
        sprite.drawString(String(percent), 0, 0, 7);
        drawColorRectangle(position); // Draw the color rectangle on the sprite
        sprite.pushSprite(0, 0);
    }
};