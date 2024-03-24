class ScreenState
{
public:
    virtual ~ScreenState() = default;
    virtual void handleInput() = 0;
    virtual void update() = 0;
    virtual void render() = 0;
};

class ScreenContext
{
private:
    ScreenState *state;

public:
    ScreenContext(ScreenState *state) : state(state) {}

    void setState(ScreenState *newState)
    {
        delete state;
        state = newState;
    }

    void handleInput()
    {
        state->handleInput();
    }

    void update()
    {
        state->update();
    }

    void render()
    {
        state->render();
    }
};

class MenuState : public ScreenState
{
public:
    void handleInput() override
    {
        // Handle input for menu
    }

    void update() override
    {
        // Update menu state
    }

    void render() override
    {
        // Render menu
    }
};

#include "moving_average_filter.h"
#include "color_rectangle_sprite.h"
class GameState : public ScreenState
{
private:
    TFT_eSPI &tft;
    ColorRectangleSprite colorRectangleSprite;
    VL53L0X *sensor;
    MovingAverageFilter filter;
    int MAX_DISTANCE = 80;

public:
    GameState(TFT_eSPI &tft, VL53L0X *sensor)
        : tft(tft), sensor(sensor), colorRectangleSprite(tft) {}
    void handleInput() override
    {
        // Handle input for game
    }

    void update() override
    {
        // Update game state
    }

    void render() override
    {
        float distance = sensor->readRangeContinuousMillimeters();
        distance = constrain(distance, 0, MAX_DISTANCE * 10);

        if (sensor->timeoutOccurred())
        {
            Serial.println("Timeout");
        }
        else
        {
            float smoothedDistance = filter.process(distance) / 10.0;
            colorRectangleSprite.setPosition(smoothedDistance / MAX_DISTANCE);
        }
    }
};