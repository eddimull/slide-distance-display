class Calibration
{
private:
    float minBoundary;
    float maxBoundary;

public:
    Calibration(float min = 0.0f, float max = 1.0f) : minBoundary(min), maxBoundary(max) {}

    void setMin(float min)
    {
        minBoundary = min;
    }

    void setMax(float max)
    {
        maxBoundary = max;
    }

    float getMin() const
    {
        return minBoundary;
    }

    float getMax() const
    {
        return maxBoundary;
    }

    float getRange() const
    {
        return maxBoundary - minBoundary;
    }

    float normalize(float value) const
    {
        return (value - minBoundary) / getRange();
    }

    float denormalize(float value) const
    {
        return value * getRange() + minBoundary;
    }
};