#include <TFT_eSPI.h>

class ColorRectangleSprite
{
private:
    TFT_eSPI &tft;
    TFT_eSprite sprite;
    TFT_eSprite textSprite;
    int spriteWidth;
    int screenHeight;
    int screenWidth;
    int colorWidth;
    int maxDistance = 80;
    int prevTargetColorIndex = -1;
    int const numberOfColors = 7;
    float prevSpeed = 0;
    float currentPosition = 0;
    float prevSlideDistance = 0;
    unsigned long prevTime = 0;

    int rectColors[7];

    void drawColorRectangle(int position)
    {
        for (int i = 0; i <= numberOfColors - 1; i++)
        {
            sprite.fillRect((i * colorWidth) + position, 0, colorWidth, 50, this->rectColors[i]);
        }
    }

    float calculateSpeed(float slideDistance, int targetColorIndex)
    {
        static float prevSlideDistance = 0;
        static unsigned long prevTime = 0;
        static int prevTargetColorIndex = -1;
        static float prevSpeed = 0;

        float speed = 0;
        unsigned long currentTime = millis();
        float timeDelta = (currentTime - prevTime) / 1000.0; // Convert milliseconds to seconds

        if (timeDelta > 0)
        {
            float distanceTraveled = abs(slideDistance - prevSlideDistance);
            speed = (distanceTraveled / timeDelta) / 10; // Calculate speed in cm/s
        }

        if (targetColorIndex != prevTargetColorIndex)
        {
            prevTargetColorIndex = targetColorIndex;
            prevSpeed = speed;
        }
        else
        {
            speed = prevSpeed;
        }

        prevSlideDistance = slideDistance;
        prevTime = currentTime;

        return speed;
    }

public:
    ColorRectangleSprite(TFT_eSPI &display, int MAX_DISTANCE = 80, int rectColors[7] = nullptr) : tft(display), sprite(&tft), textSprite(&tft)
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

        int screenHeight = tft.width(); // the screen is rotated, so width is the height
        int screenWidth = tft.height();
        spriteWidth = screenWidth * numberOfColors;
        colorWidth = spriteWidth / numberOfColors;
        this->setMaxDistance(MAX_DISTANCE);
        sprite.createSprite(spriteWidth, screenHeight); // Create a sprite that is 7 times the width of the screen
        sprite.setColorDepth(8);
        sprite.fillSprite(TFT_BLACK); // Fill the sprite with black

        textSprite.createSprite(screenWidth, 50); // Adjust the size as needed
        textSprite.setColorDepth(8);
        textSprite.setTextColor(TFT_WHITE); // Set the text color
        textSprite.setTextSize(2);          // Set the text size
    }

    void setMaxDistance(int maxDistance)
    {
        maxDistance = maxDistance;
    }

    void showStats(float slideDistance, int positionNumber, float speed)
    {
        slideDistance = constrain(slideDistance, 0, maxDistance);
        int slideDistanceInt = static_cast<int>(slideDistance);
        // Create a string in the format "slideDistanceInt / maxDistance"
        String debugString = String(slideDistanceInt) + " / " + String(static_cast<int>(maxDistance));
        String positionString = "Pos: " + String(positionNumber + 1);
        String speedString = "CM/s: " + String(speed, 1);
        textSprite.fillSprite(TFT_BLACK); // Clear the sprite before drawing the new string
        // Draw the position string on the sprite
        textSprite.drawString(debugString, 0, 0, 2);
        textSprite.drawString(positionString, 0, 25, 2);
        textSprite.drawString(speedString, 160, 25, 2);
        textSprite.pushSprite(0, 0);
    }

    void setPosition(float slideDistance)
    {
        // first position is never going to be 0, so add a first position negative buffer.
        slideDistance = constrain(slideDistance - 10, 0, maxDistance);
        float targetPercent = slideDistance / maxDistance;

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
        float transitionSpeed = 0.5; // Adjust this value to change the speed of the transition
        currentPosition = currentPosition * (1 - transitionSpeed) + targetPosition * transitionSpeed;
        // Draw the color rectangle at the currentPosition
        drawColorRectangle(static_cast<int>(currentPosition));
        // Push the sprite to the screen
        sprite.pushSprite(0, 100);
        float speed = calculateSpeed(slideDistance, targetColorIndex);

        showStats(slideDistance, targetColorIndex, speed);
    }
};