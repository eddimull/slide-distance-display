#define WINDOW_SIZE 5 // Number of readings to average

class MovingAverageFilter
{
public:
    MovingAverageFilter() : numReadings(0), insertIdx(0), total(0) {}

    float process(float newReading)
    {
        if (numReadings < WINDOW_SIZE)
        {
            // We haven't filled up our window yet, so just accumulate
            readings[numReadings++] = newReading;
            total += newReading;
        }
        else
        {
            // Window is full, so subtract the oldest reading and add the new one
            total = total - readings[insertIdx] + newReading;
            readings[insertIdx] = newReading;
            insertIdx = (insertIdx + 1) % WINDOW_SIZE;
        }
        return total / numReadings;
    }

private:
    float readings[WINDOW_SIZE];
    int numReadings;
    int insertIdx;
    float total;
};