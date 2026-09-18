#pragma once

#include <nlohmann/json.hpp>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>

namespace native_port {

using JsonRpcId = std::variant<std::int64_t, std::string>;

struct JsonRpcRequest final {
  std::optional<JsonRpcId> id;
  std::string method;
  nlohmann::json params{nlohmann::json::object()};

  [[nodiscard]] bool is_notification() const noexcept { return !id.has_value(); }
};

struct JsonRpcResponse final {
  JsonRpcId id;
  std::optional<nlohmann::json> result;
  std::optional<nlohmann::json> error;
};

class JsonRpcError final : public std::runtime_error {
 public:
  JsonRpcError(int code, std::string message);
  [[nodiscard]] int code() const noexcept { return code_; }

 private:
  int code_;
};

class JsonRpcCodec final {
 public:
  static constexpr std::size_t kDefaultMaximumFrameBytes = 1024U * 1024U;

  explicit JsonRpcCodec(std::size_t maximum_frame_bytes = kDefaultMaximumFrameBytes);

  [[nodiscard]] JsonRpcRequest parse_request(std::string_view payload) const;
  [[nodiscard]] JsonRpcResponse parse_response(std::string_view payload) const;
  [[nodiscard]] std::string serialize_request(const JsonRpcRequest& request) const;
  [[nodiscard]] std::string serialize_response(const JsonRpcResponse& response) const;

  [[nodiscard]] static nlohmann::json medal_success(nlohmann::json data);
  [[nodiscard]] static nlohmann::json medal_failure(std::string message);
  [[nodiscard]] static nlohmann::json error_object(int code, std::string message,
                                                   std::optional<nlohmann::json> data = std::nullopt);

 private:
  [[nodiscard]] nlohmann::json parse_frame(std::string_view payload) const;
  [[nodiscard]] static JsonRpcId parse_id(const nlohmann::json& id);
  [[nodiscard]] std::string serialize_checked(nlohmann::json value) const;

  std::size_t maximum_frame_bytes_;
};

}  // namespace native_port
