data "yandex_dns_zone" "parent" {
  name = var.dns_zone_name
}

resource "yandex_vpc_address" "ingress" {
  name = "${var.cluster_name}-ingress"

  external_ipv4_address {
    zone_id = var.zone
  }
}

resource "yandex_dns_recordset" "argocd" {
  zone_id = data.yandex_dns_zone.parent.id
  name    = "${var.domain}."
  type    = "A"
  ttl     = 300
  data    = [yandex_vpc_address.ingress.external_ipv4_address[0].address]
}
