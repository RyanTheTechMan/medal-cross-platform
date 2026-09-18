#include "native_port/json_rpc.hpp"

#include <utility>

namespace native_port {

namespace {

nlohmann::json id_to_json(const JsonRpcId& id) {
  return std::visit([](const auto& value) { return nlohmann::json(value); }, id);
}

}  // namespace

JsonRpcError::JsonRpcError(int code, std::string message) : std::runtime_error(std::move(message)), code_(code) {}

JsonRpcCodec::JsonRpcCodec(std::size_t maximum_frame_bytes) : maximum_frame_bytes_(maximum_frame_bytes) {
  if (maximum_frame_bytes_ == 0U) {
    throw std::invalid_argument("maximum JSON-RPC frame size must be positive");
  }
}

JsonRpcRequest JsonRpcCodec::parse_request(std::string_view payload) const {
  const auto value = parse_frame(payload);
  if (!value.contains("method") || !value.at("method").is_string()) {
    throw JsonRpcError(-32600, "Invalid Request: method must be a string");
  }
  JsonRpcRequest request;
  request.method = value.at("method").get<std::string>();
  if (request.method.empty()) {
    throw JsonRpcError(-32600, "Invalid Request: method must not be empty");
  }
  if (value.contains("id") && !value.at("id").is_null()) {
    request.id = parse_id(value.at("id"));
  }
  if (value.contains("params")) {
    if (!value.at("params").is_object() && !value.at("params").is_array()) {
      throw JsonRpcError(-32602, "Invalid params");
    }
    request.params = value.at("params");
  }
  return request;
}

JsonRpcResponse JsonRpcCodec::parse_response(std::string_view payload) const {
  const auto value = parse_frame(payload);
  if (!value.contains("id") || value.at("id").is_null()) {
    throw JsonRpcError(-32600, "Invalid Response: id is required");
  }
  const bool has_result = value.contains("result");
  const bool has_error = value.contains("error");
  if (has_result == has_error) {
    throw JsonRpcError(-32600, "Invalid Response: exactly one of result or error is required");
  }
  JsonRpcResponse response{ .id = parse_id(value.at("id")) };
  if (has_result) {
    response.result = value.at("result");
  } else {
    if (!value.at("error").is_object() || !value.at("error").contains("code") ||
        !value.at("error").contains("message")) {
      throw JsonRpcError(-32600, "Invalid Response: malformed error object");
    }
    response.error = value.at("error");
  }
  return response;
}

std::string JsonRpcCodec::serialize_request(const JsonRpcRequest& request) const {
  if (request.method.empty()) {
    throw std::invalid_argument("JSON-RPC method must not be empty");
  }
  nlohmann::json value = { { "jsonrpc", "2.0" }, { "method", request.method }, { "params", request.params } };
  if (request.id) {
    value["id"] = id_to_json(*request.id);
  }
  return serialize_checked(std::move(value));
}

std::string JsonRpcCodec::serialize_response(const JsonRpcResponse& response) const {
  if (response.result.has_value() == response.error.has_value()) {
    throw std::invalid_argument("JSON-RPC response requires exactly one of result or error");
  }
  nlohmann::json value = { { "jsonrpc", "2.0" }, { "id", id_to_json(response.id) } };
  if (response.result) {
    value["result"] = *response.result;
  } else {
    value["error"] = *response.error;
  }
  return serialize_checked(std::move(value));
}

nlohmann::json JsonRpcCodec::medal_success(nlohmann::json data) {
  return { { "result", "success" }, { "errorMessage", nullptr }, { "data", std::move(data) } };
}

nlohmann::json JsonRpcCodec::medal_failure(std::string message) {
  return { { "result", "fail" }, { "errorMessage", std::move(message) }, { "data", nullptr } };
}

nlohmann::json JsonRpcCodec::error_object(int code, std::string message, std::optional<nlohmann::json> data) {
  nlohmann::json error = { { "code", code }, { "message", std::move(message) } };
  if (data) {
    error["data"] = std::move(*data);
  }
  return error;
}

nlohmann::json JsonRpcCodec::parse_frame(std::string_view payload) const {
  if (payload.empty() || payload.size() > maximum_frame_bytes_) {
    throw JsonRpcError(-32700, "Parse error: empty or oversized frame");
  }
  auto value = nlohmann::json::parse(payload, nullptr, false);
  if (value.is_discarded()) {
    throw JsonRpcError(-32700, "Parse error");
  }
  if (!value.is_object() || value.value("jsonrpc", "") != "2.0") {
    throw JsonRpcError(-32600, "Invalid Request: JSON-RPC 2.0 object required");
  }
  return value;
}

JsonRpcId JsonRpcCodec::parse_id(const nlohmann::json& id) {
  if (id.is_number_integer()) {
    return id.get<std::int64_t>();
  }
  if (id.is_string()) {
    return id.get<std::string>();
  }
  throw JsonRpcError(-32600, "Invalid Request: id must be an integer or string");
}

std::string JsonRpcCodec::serialize_checked(nlohmann::json value) const {
  auto encoded = value.dump();
  if (encoded.size() > maximum_frame_bytes_) {
    throw std::length_error("serialized JSON-RPC frame exceeds configured limit");
  }
  return encoded;
}

}  // namespace native_port
