#include <Arduino.h>
#include <arduinoFFT.h> // Include the FFT library

class ContactMicrophone
{
private:
    int micPin;
    const uint16_t samples = 1024;          // Number of samples for FFT
    const double samplingFrequency = 44100; // Sampling frequency (Hz)
    double vReal[1024];                     // Array to store real part of FFT result
    double vImag[1024];                     // Array to store imaginary part of FFT result
    ArduinoFFT<double> FFT;                 // Create an instance of the FFT class

public:
    ContactMicrophone(int pin)
    {
        micPin = pin;
        // pinMode(micPin, INPUT);
        adcAttachPin(micPin);
    }

    void begin()
    {
        analogReadResolution(12); // Set ADC resolution to 12 bits
    }

    int getPin()
    {
        return micPin;
    }
    int getRawValue()
    {
        return analogRead(micPin);
    }

    double getPitch()
    {
        // Collect samples from the microphone
        for (int i = 0; i < samples; i++)
        {
            vReal[i] = (double)analogRead(micPin) / 4095.0; // Scale the 12-bit ADC value to the range [0, 1]
            vImag[i] = 0;
        }

        // Perform FFT on the collected samples
        FFT.windowing(vReal, samples, FFT_WIN_TYP_HAMMING, FFT_FORWARD);
        FFT.compute(vReal, vImag, samples, FFT_FORWARD);
        FFT.complexToMagnitude(vReal, vImag, samples);

        // Find the peak frequency
        double peak = FFT.majorPeak(vReal, samples, samplingFrequency);
        return peak;
    }
};