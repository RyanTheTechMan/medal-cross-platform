#include "native_port/capture_geometry.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace native_port {
namespace {

[[nodiscard]] std::size_t even_floor(double value) {
  auto result = static_cast<std::size_t>(std::max(2.0, std::floor(value)));
  result -= result % 2U;
  return std::max<std::size_t>(2U, result);
}

}  // namespace

CaptureGeometry fit_capture_geometry(double source_width_points, double source_height_points,
                                     double point_pixel_scale, std::size_t requested_width,
                                     std::size_t requested_height) {
  if (!std::isfinite(source_width_points) || !std::isfinite(source_height_points) ||
      !std::isfinite(point_pixel_scale) || source_width_points <= 0 ||
      source_height_points <= 0 || point_pixel_scale <= 0 || requested_width < 2 ||
      requested_height < 2 || requested_width % 2U != 0 || requested_height % 2U != 0) {
    throw std::invalid_argument("capture geometry requires positive source dimensions and an even output canvas");
  }

  CaptureGeometry result;
  result.source_width_points = source_width_points;
  result.source_height_points = source_height_points;
  result.point_pixel_scale = point_pixel_scale;
  result.source_width_pixels = static_cast<std::size_t>(
      std::max(2.0, std::round(source_width_points * point_pixel_scale)));
  result.source_height_pixels = static_cast<std::size_t>(
      std::max(2.0, std::round(source_height_points * point_pixel_scale)));
  result.requested_width = requested_width;
  result.requested_height = requested_height;
  result.encoded_width = requested_width;
  result.encoded_height = requested_height;

  const auto scale = std::min(static_cast<double>(requested_width) /
                                  static_cast<double>(result.source_width_pixels),
                              static_cast<double>(requested_height) /
                                  static_cast<double>(result.source_height_pixels));
  result.fitted_content_width = std::min(requested_width,
                                         even_floor(static_cast<double>(result.source_width_pixels) * scale));
  result.fitted_content_height = std::min(requested_height,
                                          even_floor(static_cast<double>(result.source_height_pixels) * scale));
  result.horizontal_padding = requested_width - result.fitted_content_width;
  result.vertical_padding = requested_height - result.fitted_content_height;
  return result;
}

}  // namespace native_port
