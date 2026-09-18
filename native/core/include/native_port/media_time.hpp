#pragma once

#include <compare>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace native_port {

struct Rational final {
  std::int32_t numerator{1};
  std::int32_t denominator{1};

  Rational() = default;
  Rational(std::int32_t numerator_value, std::int32_t denominator_value)
      : numerator(numerator_value), denominator(denominator_value) {
    if (numerator <= 0 || denominator <= 0) {
      throw std::invalid_argument("time base numerator and denominator must be positive");
    }
  }

  auto operator<=>(const Rational&) const = default;
};

struct MediaTime final {
  std::int64_t value{0};
  Rational time_base{};

  [[nodiscard]] long double seconds() const noexcept {
    return static_cast<long double>(value) * static_cast<long double>(time_base.numerator) /
           static_cast<long double>(time_base.denominator);
  }
};

[[nodiscard]] inline std::int64_t rescale(MediaTime source, Rational destination) {
  const auto scaled = static_cast<long double>(source.value) *
                      static_cast<long double>(source.time_base.numerator) *
                      static_cast<long double>(destination.denominator) /
                      (static_cast<long double>(source.time_base.denominator) *
                       static_cast<long double>(destination.numerator));
  if (scaled > static_cast<long double>(std::numeric_limits<std::int64_t>::max()) ||
      scaled < static_cast<long double>(std::numeric_limits<std::int64_t>::min())) {
    throw std::overflow_error("media timestamp rescale overflow");
  }
  return static_cast<std::int64_t>(scaled);
}

}  // namespace native_port
