# Measurement report — platform comparison

Source: `docs/reports/measurements/smoke/raw.csv` — medians with IQR over the raw runs (SRQ3 measurement protocol, §6 reporting format).

## Component versions

- **docker compose**: Docker version 29.1.3 build 29.1.3-0ubuntu3~24.04.2 Docker Compose version 2.40.3+ds1-0ubuntu1~24.04.1; Ubuntu 24.04.4 LTS kernel 6.8.0-124-generic
- **podman kube play**: podman version 4.9.3; Ubuntu 24.04.4 LTS kernel 6.8.0-124-generic
- **k3s (PoC)**: k3s version v1.36.2+k3s1 (01b6f04a); Ubuntu 24.04.4 LTS kernel 6.8.0-134-generic

## D1 platform footprint

### `platform_rss_total` (M-PF-01, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 118.8 | 0 | 118.8 | 118.8 | 118.8 |
| podman kube play | 1 | 0 | 0 | 0 | 0 | 0 |
| k3s (PoC) | 1 | 1467.7 | 0 | 1467.7 | 1467.7 | 1467.7 |

- core+kube-system+argocd
- procs=
- procs=1839+1863

### `platform_rss_core` (M-PF-01a, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| k3s (PoC) | 1 | 1003.2 | 0 | 1003.2 | 1003.2 | 1003.2 |

- k3s+containerd+shims

### `platform_rss_kube_system` (M-PF-01b, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| k3s (PoC) | 1 | 243.2 | 0 | 243.2 | 243.2 | 243.2 |

- pod processes in kube-system

### `platform_rss_argocd` (M-PF-01c, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| k3s (PoC) | 1 | 221.3 | 0 | 221.3 | 221.3 | 221.3 |

- pod processes in argocd

### `platform_cpu_idle` (M-PF-02, pct)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 0.1 | 0 | 0.1 | 0.1 | 0.1 |
| podman kube play | 1 | 0 | 0 | 0 | 0 | 0 |
| k3s (PoC) | 1 | 12.09 | 0 | 12.09 | 12.09 | 12.09 |

- no platform processes (daemonless)
- pidstat 10s; ncpu=4; pids=2
- pidstat 10s; ncpu=4; pids=22

### `platform_disk_binaries` (M-PF-03a, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 178.9 | 0 | 178.9 | 178.9 | 178.9 |
| podman kube play | 1 | 61.9 | 0 | 61.9 | 61.9 | 61.9 |
| k3s (PoC) | 1 | 70.3 | 0 | 70.3 | 70.3 | 70.3 |

- dockerd+docker+containerd+shim+runc
- k3s single binary
- podman+conmon+netavark+aardvark+runtime

### `platform_disk_state` (M-PF-03b, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 2532 | 0 | 2532 | 2532 | 2532 |
| podman kube play | 1 | 1584 | 0 | 1584 | 1584 | 1584 |
| k3s (PoC) | 1 | 5344 | 0 | 5344 | 5344 | 5344 |

- /var/lib/containers (incl. images)
- /var/lib/docker + /var/lib/containerd (incl. images)
- /var/lib/rancher + /var/lib/kubelet + /etc/rancher (incl. images)

### `image_store` (M-PF-03c, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 0 | 0 | 0 | 0 | 0 |
| podman kube play | 1 | 1582 | 0 | 1582 | 1582 | 1582 |
| k3s (PoC) | 1 | 4385 | 0 | 4385 | 4385 | 4385 |

- containerd content+snapshots
- layer store

### `cold_start` (M-PF-04, s)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 1 | 0 | 1 | 1 | 1 |
| podman kube play | 1 | 0 | 0 | 0 | 0 | 0 |
| k3s (PoC) | 1 | 12.3 | 0 | 12.3 | 12.3 | 12.3 |

- daemonless engine; no platform service to start
- k3s-killall -> node Ready + kube-system/argocd deployments available (argocd controller at 0)
- systemctl start docker -> docker info OK

## D2 lifecycle timing

### `install_time` (M-LC-01, s)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 19.4 | 0 | 19.4 | 19.4 | 19.4 |
| podman kube play | 1 | 18.6 | 0 | 18.6 | 18.6 | 18.6 |
| k3s (PoC) | 1 | 22.9 | 0 | 22.9 | 22.9 | 22.9 |

- command -> tag 2.0.0 running + all endpoints 200

### `upgrade_time` (M-LC-02, s)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 4.1 | 0 | 4.1 | 4.1 | 4.1 |
| podman kube play | 1 | 3.9 | 0 | 3.9 | 3.9 | 3.9 |
| k3s (PoC) | 1 | 6.9 | 0 | 6.9 | 6.9 | 6.9 |

- command -> tag 2.0.1 running + all endpoints 200

### `rollback_time` (M-LC-03, s)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 4 | 0 | 4 | 4 | 4 |
| podman kube play | 1 | 4 | 0 | 4 | 4 | 4 |
| k3s (PoC) | 1 | 6.6 | 0 | 6.6 | 6.6 | 6.6 |

- command -> tag 2.0.0 running + all endpoints 200

## D3 workload performance

### `http_throughput` (M-WP-01, rps)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 10.03 | 0 | 10.03 | 10.03 | 10.03 |
| podman kube play | 1 | 10 | 0 | 10 | 10 | 10 |
| k3s (PoC) | 1 | 10.05 | 0 | 10.05 | 10.05 | 10.05 |

- target 10 rps for 20s

### `http_p50` (M-WP-02, ms)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 9.25 | 0 | 9.25 | 9.25 | 9.25 |
| podman kube play | 1 | 11.99 | 0 | 11.99 | 11.99 | 11.99 |
| k3s (PoC) | 1 | 7.49 | 0 | 7.49 | 7.49 | 7.49 |

### `http_p95` (M-WP-03, ms)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 35.32 | 0 | 35.32 | 35.32 | 35.32 |
| podman kube play | 1 | 34.23 | 0 | 34.23 | 34.23 | 34.23 |
| k3s (PoC) | 1 | 23.33 | 0 | 23.33 | 23.33 | 23.33 |

### `http_p99` (M-WP-03+, ms)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 50.53 | 0 | 50.53 | 50.53 | 50.53 |
| podman kube play | 1 | 42.11 | 0 | 42.11 | 42.11 | 42.11 |
| k3s (PoC) | 1 | 31.1 | 0 | 31.1 | 31.1 | 31.1 |

### `http_error_rate` (M-WP-04, ratio)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 0 | 0 | 0 | 0 | 0 |
| podman kube play | 1 | 0 | 0 | 0 | 0 | 0 |
| k3s (PoC) | 1 | 0 | 0 | 0 | 0 | 0 |

- of 200 requests; dropped=0
- of 201 requests; dropped=0

### `startup_time` (M-WP-05, s)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 2.9 | 0 | 2.9 | 2.9 | 2.9 |
| podman kube play | 1 | 3 | 0 | 3 | 3 | 3 |
| k3s (PoC) | 1 | 4 | 0 | 4 | 4 | 4 |

- docker start -> /q/health/ready 200
- pod creationTimestamp -> Ready condition (API timestamps)
- podman pod start -> /q/health/ready 200

### `workload_rss_total` (M-WP-06*, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 1438.5 | 0 | 1438.5 | 1438.5 | 1438.5 |
| podman kube play | 1 | 1406.4 | 0 | 1406.4 | 1406.4 | 1406.4 |
| k3s (PoC) | 1 | 1421.7 | 0 | 1421.7 | 1421.7 | 1421.7 |

- mid-load; all workload containers

## other

### `workload_rss_artemis` (—, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 264.3 | 0 | 264.3 | 264.3 | 264.3 |
| podman kube play | 1 | 244.5 | 0 | 244.5 | 244.5 | 244.5 |
| k3s (PoC) | 1 | 253.8 | 0 | 253.8 | 253.8 | 253.8 |

- mid-load; 

### `workload_rss_keycloak` (—, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 500.8 | 0 | 500.8 | 500.8 | 500.8 |
| podman kube play | 1 | 495.8 | 0 | 495.8 | 495.8 | 495.8 |
| k3s (PoC) | 1 | 503.3 | 0 | 503.3 | 503.3 | 503.3 |

- mid-load; 

### `workload_rss_management-service` (—, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 266.2 | 0 | 266.2 | 266.2 | 266.2 |
| k3s (PoC) | 1 | 262.8 | 0 | 262.8 | 262.8 | 262.8 |

- mid-load; 

### `workload_rss_management-service-management` (—, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| podman kube play | 1 | 261.4 | 0 | 261.4 | 261.4 | 261.4 |

- mid-load; 

### `workload_rss_postgres` (—, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 139 | 0 | 139 | 139 | 139 |
| podman kube play | 1 | 138.8 | 0 | 138.8 | 138.8 | 138.8 |
| k3s (PoC) | 1 | 139.5 | 0 | 139.5 | 139.5 | 139.5 |

- mid-load; 

### `workload_rss_submission-service` (—, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| docker compose | 1 | 268.2 | 0 | 268.2 | 268.2 | 268.2 |
| k3s (PoC) | 1 | 262.4 | 0 | 262.4 | 262.4 | 262.4 |

- mid-load; 

### `workload_rss_submission-service-submission` (—, MiB)

| platform | runs | median | IQR | min | max | raw |
|---|---|---|---|---|---|---|
| podman kube play | 1 | 266 | 0 | 266 | 266 | 266 |

- mid-load; 

