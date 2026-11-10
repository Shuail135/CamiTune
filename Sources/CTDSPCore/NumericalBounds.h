#ifndef CTDSP_NUMERICAL_BOUNDS_H
#define CTDSP_NUMERICAL_BOUNDS_H

#include <algorithm>
#include <cmath>

namespace ctdsp::bounds {
// Outward bounds leave the render thread's rounding mode and histories alone.
inline double upper(double value) { return std::nextafter(value, HUGE_VAL); }
inline double lower(double value) { return std::nextafter(value, -HUGE_VAL); }
inline double upperAdd(double a, double b) {
    if (a == 0) return b;
    if (b == 0) return a;
    return upper(a + b);
}
inline double upperMultiply(double a, double b) {
    if (a == 0 || b == 0) return 0;
    return upper(a * b);
}
inline double upperNorm(double a, double b) {
    const double largest = std::max(a, b);
    if (largest == 0 || !std::isfinite(largest)) return largest;
    const double ratio = upper(std::min(a, b) / largest);
    return upperMultiply(largest, upper(std::sqrt(upperAdd(1, upperMultiply(ratio, ratio)))));
}

// A retained interval no longer than one lap lies in these two maxima. The
// resource owner supplies its lap boundary, so no second cursor can disagree.
struct HistoryPeak {
    double current = 0, previous = 0;
    void record(double value, bool beginsLap) {
        if (beginsLap) { previous = current; current = 0; }
        current = std::max(current, std::abs(value));
    }
    double peak() const { return std::max(current, previous); }
};
}
#endif
