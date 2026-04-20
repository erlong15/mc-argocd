locals {
  network_name = "argo-lab-net"
  subnet_name  = "argo-lab-subnet"
}

resource "yandex_vpc_network" "this" {
  name = local.network_name
}

resource "yandex_vpc_gateway" "egress_gateway" {
  name = "nat-gateway"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "private" {
  name       = "route-table-private"
  network_id = yandex_vpc_network.this.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.egress_gateway.id
  }
}

resource "yandex_vpc_subnet" "this" {
  name           = local.subnet_name
  zone           = var.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = [var.network_cidr]
  route_table_id = yandex_vpc_route_table.private.id
}

module "kube" {
  source       = "git::https://github.com/terraform-yc-modules/terraform-yc-kubernetes.git?ref=1.1.2"
  cluster_name = var.cluster_name
  network_id   = yandex_vpc_network.this.id

  enable_oslogin_or_ssh_keys = {
    enable-oslogin = "true"
    ssh-keys       = null
  }

  master_locations = [
    {
      zone      = var.zone
      subnet_id = yandex_vpc_subnet.this.id
    }
  ]

  master_maintenance_windows = [
    {
      day        = "monday"
      start_time = "20:00"
      duration   = "3h"
    }
  ]

  node_groups = {
    "argo-ng-01" = {
      description = "Demo node group for ArgoCD masterclass"
      node_cores  = var.node_cores
      node_memory = var.node_memory_gb
      preemptible = true
      nat         = true

      node_locations = [
        {
          zone      = var.zone
          subnet_id = yandex_vpc_subnet.this.id
        }
      ]

      auto_scale = {
        min     = var.node_autoscale_min
        max     = var.node_autoscale_max
        initial = var.node_autoscale_initial
      }
    }
  }
}
