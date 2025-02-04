terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  token     = var.yandex_token
  cloud_id  = var.yandex_cloud_id
  folder_id = var.yandex_folder_id
  zone      = "ru-central1-a"
}

# Генерация SSH ключей
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "local_file" "private_key" {
  content  = tls_private_key.ssh_key.private_key_pem
  filename = "${path.module}/id_rsa_new_bookstore_vm"
}

resource "local_file" "meta" {
  content  = <<-EOT
    #cloud-config
    users:
      - name: ipiris
        groups: sudo
        shell: /bin/bash
        sudo: 'ALL=(ALL) NOPASSWD:ALL'
        ssh_authorized_keys:
          - ${tls_private_key.ssh_key.public_key_openssh}
  EOT
  filename = "${path.module}/meta.txt"
}

resource "yandex_vpc_network" "new_bookstore_network" {
  name = "new-bookstore-network"
}

resource "yandex_vpc_subnet" "new_bookstore_subnet" {
  name           = "new-bookstore-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.new_bookstore_network.id
  v4_cidr_blocks = ["192.168.1.0/24"]
}

resource "yandex_compute_instance" "new_bookstore_vm" {
  depends_on = [local_file.meta]

  name        = "new-bookstore-vm"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = "fd86idv7gmqapoeiq5ld" # Ubuntu 22.04 LTS
      size     = 20
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.new_bookstore_subnet.id
    nat       = true
  }

  metadata = {
    user-data = "${file("${path.module}/meta.txt")}" # Используем cloud-init
  }
}

resource "null_resource" "configure_vm" {
  depends_on = [yandex_compute_instance.new_bookstore_vm]

  # Добавляем задержку перед выполнением remote-exec
  provisioner "local-exec" {
    command = "sleep 120" # Ждём 2 минуты, чтобы виртуальная машина успела загрузиться
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y docker.io",
      "sudo docker run -d -p 80:8080 --name new-bookstore-app jmix/jmix-bookstore"
    ]

    connection {
      type        = "ssh"
      user        = "ipiris"
      private_key = tls_private_key.ssh_key.private_key_pem
      host        = yandex_compute_instance.new_bookstore_vm.network_interface.0.nat_ip_address
    }
  }
}

output "ssh_connection_string" {
  value = "ssh -i id_rsa_new_bookstore_vm ipiris@${yandex_compute_instance.new_bookstore_vm.network_interface.0.nat_ip_address}"
}

output "web_app_url" {
  value = "http://${yandex_compute_instance.new_bookstore_vm.network_interface.0.nat_ip_address}"
}
