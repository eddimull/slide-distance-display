#include <Wire.h>
#include <VL53L0X.h>
class VL53L0XSensor
{
private:
    VL53L0X sensor;
    const int MAX_DISTANCE = 80; // Maximum distance in centimeters

public:
    VL53L0XSensor()
    {
        Wire.begin(18, 44);
        sensor.setTimeout(500);
        if (!sensor.init())
        {
            Serial.println("Failed to detect and initialize sensor!");
            while (1)
            {
            }
        }
        sensor.startContinuous();
    }

    float getDistance()
    {
        float distance = sensor.readRangeContinuousMillimeters() / 10.0;
        if (distance > MAX_DISTANCE)
        {
            distance = MAX_DISTANCE;
        }
        else if (distance < 0)
        {
            distance = 0;
        }
        return distance;
    }

    float getDistancePercent()
    {
        float distancePercent = getDistance() / MAX_DISTANCE;
        return distancePercent;
    }
};