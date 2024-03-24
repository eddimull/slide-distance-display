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
    int maxDistance;
    int const numberOfColors = 7;
    float currentPosition = 0;

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
        sprite.setColorDepth(8);
    }

    void setMaxDistance(int maxDistance)
    {
        this->maxDistance = maxDistance;
    }

    void setPosition(float targetPercent)
    {
        sprite.drawString(String(targetPercent), 0, 0, 7);
        // Ensure targetPercent is between 0.0 and 1.0
        targetPercent = max(0.0f, min(targetPercent, 1.0f));

        // Calculate the target index of the rectColors array based on the targetPercent value
        float targetColorIndexFloat = targetPercent * numberOfColors;
        int targetColorIndex = static_cast<int>(targetColorIndexFloat);

        // Clamp the targetColorIndex between 0 and numberOfColors - 1
        targetColorIndex = max(0, min(targetColorIndex, numberOfColors - 1));

        // Calculate the distance between the targetColorIndexFloat and the nearest integer values
        float lowerDiff = targetColorIndexFloat - static_cast<int>(targetColorIndexFloat);
        float upperDiff = static_cast<int>(targetColorIndexFloat + 1) - targetColorIndexFloat;

        // Define the dead zone threshold
        float deadZoneThreshold = 0.2f; // Adjust this value to change the size of the dead zone

        // Check if the targetColorIndexFloat is within the dead zone
        if (lowerDiff < deadZoneThreshold || upperDiff < deadZoneThreshold)
        {
            // If within the dead zone, snap to the nearest color position
            targetColorIndex = round(targetColorIndexFloat);
        }

        // Calculate the target position based on the targetColorIndex
        float targetPosition = -(targetColorIndex * colorWidth);

        // Use lerp to smoothly transition the currentPosition to the targetPosition
        float speed = 0.5; // Adjust this value to change the speed of the transition
        currentPosition = currentPosition * (1 - speed) + targetPosition * speed;

        // Draw the color rectangle at the currentPosition
        drawColorRectangle(static_cast<int>(currentPosition));

        // Push the sprite to the screen
        sprite.pushSprite(0, 0);
    }
};