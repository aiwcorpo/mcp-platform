# Loaded by run.sh only while `docker compose run --rm openbao-recover` runs (flag file /openbao/recovery/enabled, at most 10
# minutes old). Loopback of the openbao container: nothing else can reach it. Without the key share the endpoint gives no token.
listener "tcp" {
  address                                  = "127.0.0.1:8300"
  tls_disable                              = true
  disable_unauthed_generate_root_endpoints = false
}
