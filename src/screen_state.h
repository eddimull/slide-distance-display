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
#include <SimpleKalmanFilter.h>
#include <VL53L0X.h>
class GameState : public ScreenState
{
private:
    TFT_eSPI &tft;
    ColorRectangleSprite colorRectangleSprite;
    VL53L0X *sensor;
    MovingAverageFilter filter;
    SimpleKalmanFilter simpleKalmanFilter;
    float slideDistance;
    float rawDistance;
    int MAX_DISTANCE = 80;

public:
    GameState(TFT_eSPI &tft, VL53L0X *sensor)
        : tft(tft),
          sensor(sensor),
          simpleKalmanFilter(2, 2, 0.17),
          colorRectangleSprite(tft, MAX_DISTANCE) {}
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
        rawDistance = sensor->readRangeContinuousMillimeters() / 10.0;

        if (sensor->timeoutOccurred())
        {
            Serial.println("Timeout");
        }
        else
        {

            slideDistance = simpleKalmanFilter.updateEstimate(rawDistance);
            colorRectangleSprite.setPosition(slideDistance);
        }
    }
};