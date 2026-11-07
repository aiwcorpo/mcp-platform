# Single node with Raft storage on the volume openbao-data, TLS with a certificate of the internal CA, reachable only on the
# "secrets" network. The server starts sealed; the openbao-unseal service unseals it (README, OpenBao after a restart).
ui = false
# Raft storage does not use mlock-able memory; the flag also drops the need for the IPC_LOCK capability.
disable_mlock = true
api_addr = "https://openbao.internal:8200"
# Loopback only: there is no second node.
cluster_addr = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/openbao/file"
  node_id = "platform-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/openbao/tls/tls.crt"
  tls_key_file    = "/openbao/tls/tls.key"
  tls_min_version = "tls12"
}

# OpenBao 2.x enables audit devices only declaratively. Values in the log are HMAC-ed.
audit "file" "stdout" {
  options {
    file_path = "stdout"
  }
}
