job "traefik" {
  datacenters = ["dc1"]
  type = "service"

  group "traefik" {
    count = 1

    network {
      port "http" {
        static = "80"
      }
      port "https" {
        static = "443"
      }
      port "dashboard" {
        static = "8080"
      }
    }

    service {
      provider = "consul"
      name = "${NOMAD_JOB_NAME}"
      port = "https"

      tags = [
        "traefik.enable=true",

        # http to https redirect
        "traefik.http.routers.http-catch.entrypoints=http",
        "traefik.http.routers.http-catch.rule=HostRegexp(`{host:.+}`)",
        "traefik.http.routers.http-catch.middlewares=redirect-to-https",
        "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https",

        # https router
        "traefik.http.routers.traefik-router.entrypoints=https",
        "traefik.http.routers.traefik-router.rule=Host(`[[ .app.traefik.domain ]].[[ .common.domain ]]`)",
        "traefik.http.routers.traefik-router.service=api@internal",

        "traefik.http.routers.traefik-router.tls=true",
        # Comment out the below line after first run of traefik to force the use of wildcard certs
        # "traefik.http.routers.traefik-router.tls.certResolver=dns-dgo"
        "traefik.http.routers.traefik-router.tls.domains[0].main=[[ .common.domain ]]"
        "traefik.http.routers.traefik-router.tls.domains[0].sans=*.[[ .common.domain ]]"
      ]

      check {
        type     = "tcp"
        port     = "http"
        interval = "30s"
        timeout  = "5s"

        success_before_passing   = "3"
        failures_before_critical = "3"
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image = "traefik:v2.6.1"
        ports = ["http", "https", "dashboard"]
        network_mode = "host"

        volumes = [
          "local/traefik.yml:/traefik.yml",
          "local/rules:/rules",
          "secrets/tls:/tls",
          "[[ .app.traefik.volumes.acme ]]:/acme",
        ]

        labels = {
          "diun.enable" = "false"
        }
      }

      env {
        DO_AUTH_TOKEN = "[[ .app.traefik.do_token ]]"
      }

      template {
        data = <<EOF
global:
  checkNewVersion: true
  sendAnonymousUsage: false

api:
  insecure: false
  dashboard: true

ping: {}

log:
  level: "DEBUG"

# accessLog:
#   filePath: "/traefik.log"
#   filters:
#     statusCodes: "400-499"

entrypoints:
  http:
    address: ":{{ env "NOMAD_PORT_http" }}"
  https:
    address: ":{{ env "NOMAD_PORT_https" }}"

providers:
  consulCatalog:
    endpoint:
      scheme: "https"
      address: "[[ .app.traefik.provider.address ]]"
      tls:
        # create cert for traefik to consul TLS
        # must be renewed
        ca: "tls/traefik-client.dc1.consul-ca.crt"
        cert: "tls/traefik-client.dc1.consul-cert.crt"
        key: "tls/traefik-client.dc1.consul-key.pem"
    exposedByDefault: false

  file:
    directory: "/rules"

certificatesResolvers:
  dns-dgo:
    acme:
      email: "[[ .app.traefik.acme.email ]]"
      storage: "acme/acme.json"
      caServer: "[[ .app.traefik.acme.caServer ]]"
      dnsChallenge:
        provider: digitalocean
        resolvers: "1.1.1.1:53,1.0.0.1:53"
EOF
        destination = "${NOMAD_TASK_DIR}/traefik.yml"
      }

      template {
        data = <<EOF
http:
  routers:
    proxmox-https:
      entryPoints:
        - https
      rule: "Host(`[[ .app.proxmox.domain ]].[[ .common.domain ]]`)"
      tls: {}
      middlewares:
        - default-headers
      service: proxmox

    pihole:
      entryPoints:
        - https
      rule: "Host(`[[ .app.pihole.domain ]].[[ .common.domain ]]`)"
      tls: {}
      middlewares:
        - default-headers
        - addprefix-pihole
      service: pihole

  services:
    pihole:
      loadBalancer:
        servers:
          - url: "https://[[ .app.pihole.ip ]]"
        passHostHeader: true

  serversTransports:
    insecureTransport:
      insecureSkipVerify: true

  middlewares:
    addprefix-pihole:
      addPrefix:
        prefix: "/admin"

    default-headers:
      headers:
        frameDeny: true
        sslRedirect: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
EOF
        destination = "${NOMAD_TASK_DIR}/rules/rules.yml"
      }

      template {
        data = <<EOF
{{ with secret "pki_int/issue/cluster" "common_name=traefik-client.dc1.consul" }}
{{ .Data.certificate }}
{{ end }}
EOF
        destination = "${NOMAD_SECRETS_DIR}/tls/traefik-client.dc1.consul-cert.crt"
        perms = "0600"
        change_mode = "restart"
      }

      template {
        data = <<EOF
{{ with secret "pki_int/issue/cluster" "common_name=traefik-client.dc1.consul" }}
{{ .Data.private_key }}
{{ end }}
EOF
        destination = "${NOMAD_SECRETS_DIR}/tls/traefik-client.dc1.consul-key.pem"
        perms = "0400"
        change_mode = "restart"
      }
      template {
        data = <<EOF
{{ with secret "pki_int/issue/cluster" "common_name=traefik-client.dc1.consul" }}
{{ .Data.issuing_ca }}
{{ end }}
EOF
        destination = "${NOMAD_SECRETS_DIR}/tls/traefik-client.dc1.consul-ca.crt"
        perms = "0640"
        change_mode = "restart"
      }

      resources {
        cpu    = 35
        memory = 128
      }
    }
  }
}
