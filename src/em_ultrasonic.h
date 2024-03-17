#define WINDOW_SIZE 5
class MySensor
{
private:
    uint8_t trigPin;
    uint8_t echoPin;
    double speed_of_sound = 0.034; // cm/microsecond
    float distances[WINDOW_SIZE];

    float calculateMovingAverage(float newValue)
    {
        static int index = 0;
        static float sum = 0;

        sum -= distances[index];
        sum += newValue;
        distances[index] = newValue;
        index = (index + 1) % WINDOW_SIZE;

        return sum / WINDOW_SIZE;
    }

public:
    MySensor(uint8_t trig, uint8_t echo) : trigPin(trig), echoPin(echo)
    {
        pinMode(trigPin, OUTPUT);
        pinMode(echoPin, INPUT);
    }

    float read()
    {
        digitalWrite(trigPin, LOW);
        delayMicroseconds(2);
        digitalWrite(trigPin, HIGH);
        delayMicroseconds(10);
        digitalWrite(trigPin, LOW);

        unsigned long duration = pulseIn(echoPin, HIGH);
        double distance = duration * speed_of_sound / 2;
        float smoothedDistance = calculateMovingAverage(distance);
        return smoothedDistance;
    }
};