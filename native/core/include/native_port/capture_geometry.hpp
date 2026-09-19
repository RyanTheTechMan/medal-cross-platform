#pragma once

#include <cstddef>

namespace native_port {

struct CaptureGeometry final {
  double source_width_points{0};
  double source_height_points{0};
  double point_pixel_scale{1};
  std::size_t source_width_pixels{0};
  std::size_t source_height_pixels{0};
  std::size_t requested_width{0};
  std::size_t requested_height{0};
  std::size_t encoded_width{0};
  std::size_t encoded_height{0};
  std::size_t fitted_content_width{0};
  std::size_t fitted_content_height{0};
  std::size_t horizontal_padding{0};
  std::size_t vertical_padding{0};
};

// Medal's Resolution setting describes the final encoded canvas. The source is
// aspect-fitted into that exact even-sized canvas; the remaining area is
// letterbox/pillarbox padding supplied by ScreenCaptureKit.
[[nodiscard]] CaptureGeometry fit_capture_geometry(double source_width_points,
                                                   double source_height_points,
                                                   double point_pixel_scale,
                                                   std::size_t requested_width,
                                                   std::size_t requested_height);

}  // namespace native_port
