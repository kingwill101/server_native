#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProxyServerHandle ProxyServerHandle;

typedef struct ServerNativeProxyConfig {
  const char *host;
  uint16_t port;
  const char *backend_host;
  uint16_t backend_port;
  uint8_t backend_kind;
  const char *backend_path;
  uint32_t backlog;
  uint8_t v6_only;
  uint8_t shared;
  uint8_t request_client_certificate;
  uint8_t http2;
  uint8_t http3;
  const char *tls_cert_path;
  const char *tls_key_path;
  const char *tls_cert_password;
  uint8_t benchmark_mode;
  const void *direct_request_callback;
} ServerNativeProxyConfig;

#ifdef __cplusplus
}
#endif
