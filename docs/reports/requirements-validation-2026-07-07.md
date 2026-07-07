# Requirements-catalogue validation — 2026-07-07

Automated execution of the acceptance criteria from *SRQ1 – Requirements
Catalogue* against the running POC cluster (`scripts/validate-requirements.sh`).

- Cluster: k3s v1.36.2+k3s1 on case-poc (aarch64), node IP 192.168.252.5
- Repository state: 5b172c5 Fix validation harness races; add preStop drain to service pods (branch phase2)
- Verdicts: PASS / FAIL = acceptance criterion; MEASURED = TBM value recorded
  (thresholds are finalised from these first controlled runs, per catalogue §3);
  JUSTIFIED = Should-requirement not implemented, justification recorded.

| Requirement | Verdict | Evidence |
|---|---|---|
| REQ-F-002 | PASS | Deployment/Service/ConfigMap/Secret/PVC all live in case-poc (19 objects applied via GitOps) |
| REQ-F-005 | PASS | pod with failing readiness probe excluded from endpoints (0 ready endpoints after 20s) |
| REQ-F-006 | PASS | pod saw 'GREETING=value-one' before and 'GREETING=value-two' after ConfigMap update + restart, no image rebuild |
| REQ-F-008 | PASS | pod in req-test resolved and reached kubernetes.default.svc.cluster.local:443 (service in another namespace) |
| REQ-F-007 | PASS | case d7ef9c3c-9bf0-40f3-afe6-204a1cf2572f readable after deleting every app pod (data on PVCs: case-poc-anonymous-case-poc-artemis-data=Bound case-poc-anonymous-case-poc-postgres-data=Bound ) |
| REQ-F-001 | PASS | helm install of the multi-service chart completed; all pods Ready (release req, ns req-helm) |
| REQ-O-003 | MEASURED | helm install -> all pods Ready: 26s (images pre-imported; TBM threshold 180s => within) |
| REQ-F-003 | PASS | helm upgrade rolled the services with 0 non-200 of 31 probes against /q/health/live through the ingress |
| REQ-O-004 | MEASURED | helm upgrade -> all pods Ready: 7s (TBM threshold 180s => within) |
| REQ-F-004 | PASS | helm rollback restored revision 1 (now at release revision 3); application answered 201 post-rollback |
| REQ-O-005 | MEASURED | helm rollback -> all pods Ready: 9s (TBM threshold 120s => within) |
| REQ-F-009 | PASS | install/upgrade/rollback/status executed with v3.19.0+g3d8990f and Client Version: v1.36.2+k3s1; no vendor CLI involved (GitOps path: git + Argo CD) |
| REQ-F-010 | JUSTIFIED | no registry deployed: service images are distributed by import into the node's containerd (scripts/images-import.sh), which provides the air-gap property (imagePullPolicy: IfNotPresent, no external pull at runtime); a registry adds no validation value on a single node and is documented as rollout-phase work (application-architecture/future.md) |
| REQ-G-001 | PASS | SA with no (Cluster)RoleBinding: 'can-i list pods -A' => no, 'can-i get nodes' => no |
| REQ-G-002 | PASS | create+delete of audit-probe-1783408565 present in audit.log (5 entries, path /var/lib/rancher/k3s/server/logs/audit.log) |
| REQ-G-003 | PASS | deny-egress NetworkPolicy enforced (probe: before=OPEN after=CLOSED); app namespace allow-list holds (submission pod: PG_OPEN API_CLOSED ) |
| REQ-G-004 | PASS | API server presents auto-provisioned TLS cert on 6443 (subject=O = k3s, CN = k3s notAfter=Jul  6 22:28:52 2027 GMT ); kubeconfig pins the cluster CA |
| REQ-G-005 | PASS | chart templates 0 Secret objects; 3 runtime Secrets generated at bootstrap (scripts/secrets-bootstrap.sh); no credential literals in deploy/ (Keycloak demo users are documented synthetic fixtures) |
| REQ-G-006 | PASS | pod with runAsUser: 0 rejected at admission: violates PodSecurity "restricted:latest": runAsNonRoot != true (pod or container "main" must set securityContext.runAsNonRoot=true) |
| REQ-G-007 | PASS | deploy/ history in git (last: 5b172c5 Fix validation harness races; add preStop drain to service pods); Argo CD selfHeal=true reverts out-of-band mutations; API changes in audit.log (see REQ-G-002) |
| REQ-G-008 | PASS | API server /metrics serves Prometheus format; app /q/metrics exposes 67 metric families (micrometer); kubectl logs streams pod logs |
| REQ-O-001 | MEASURED | k3s RSS 962MiB + containerd/shims 466MiB; kube-system pods 75Mi, argocd pods 227Mi; idle CPU 4.2% (VM 4 vCPU) — TBM baseline recorded; catalogue threshold (512MB/5%) to be refined against it |
| REQ-O-006 | PASS | bring-up fully scripted (vm-up.sh -> ansible -> images-import.sh -> argocd-install.sh); latest scratch rebuild log: docs/reports/rebuild-2026-07-07.md |
| REQ-O-007 | PASS | all steps executed by one operator from docs/k8s-poc.md; no undocumented manual step required for this validation run |
| REQ-O-008 | PASS | all platform/workload config in git (deploy/ tree, 0 uncommitted changes); Argo CD app status: Synced (cluster state follows the repository) |
| REQ-O-002 | MEASURED | k3s restart -> node Ready + coredns/traefik/metrics-server available: 10s; app workload re-ready: 10s (TBM threshold 300s => within; VM boot excluded — k3s is a systemd unit) |

Requirements without an automatable criterion in this run: none — all 26
catalogue entries above. FAIL count: 0.
