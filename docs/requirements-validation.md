# Requirements-catalogue validation — method

How the enterprise requirements catalogue (thesis: *SRQ1 – Requirements
Catalogue*) is validated against the running POC cluster. The automated
executor is [`scripts/validate-requirements.sh`](../scripts/validate-requirements.sh);
each run writes a dated evidence report to `docs/reports/requirements-validation-<date>.md`.
This file documents the mapping and the dispositions that are *not* plain
pass/fail, so the reports stay self-explanatory.

Run (app deployed and healthy):

```bash
multipass exec case-poc-cp -- sudo bash /repo/scripts/validate-requirements.sh
```

## Verdict semantics

| Verdict | Meaning |
|---|---|
| PASS / FAIL | The catalogue's acceptance criterion was executed literally. |
| MEASURED | TBM (to-be-measured) requirement: the value is recorded and compared informationally against the catalogue's provisional threshold. Per catalogue §3, thresholds are finalised from these first controlled runs and fixed before the validation runs that count. |
| JUSTIFIED | Should-priority requirement intentionally not implemented; the catalogue requires the absence to be justified, and the justification is recorded in the report row. |

## How each requirement is checked

| Requirement | Check (all executed by the script unless noted) |
|---|---|
| REQ-F-001 | `helm install` of the chart into a throwaway namespace (`req-helm`) with `--wait`; all pods Ready. |
| REQ-F-002 | Deployment/Service/ConfigMap/Secret/PVC all live in `case-poc` (applied via GitOps). |
| REQ-F-003 | Continuous probe of `/q/health/live` through the ingress (5/s) while `helm upgrade` rolls both service deployments; PASS = zero non-200. |
| REQ-F-004 | `helm rollback` to revision 1 with `--wait`; the API must answer afterwards. |
| REQ-F-005 | Deployment with an always-failing readiness probe + Service; PASS = 0 ready endpoints. |
| REQ-F-006 | ConfigMap value flipped, pod restarted (`rollout restart`); PASS = pod logs show the new value, no image rebuild. |
| REQ-F-007 | Create a case through the API, delete **all** app pods (incl. PostgreSQL/Artemis), wait for recovery; PASS = case readable with its token (data on the PVCs). |
| REQ-F-008 | Pod in `req-test` resolves and TCP-reaches `kubernetes.default.svc.cluster.local:443` (service in another namespace). |
| REQ-F-009 | Evidence row: every lifecycle operation in this repo uses `kubectl`/`helm` (plus git for GitOps); versions recorded. |
| REQ-F-010 | JUSTIFIED (Should): image import into containerd provides the air-gap property on a single node (`imagePullPolicy: IfNotPresent`, no runtime pull); a registry is rollout-phase work (`application-architecture/future.md`). |
| REQ-O-001 | MEASURED: RSS of k3s + containerd processes, `kubectl top` sums for kube-system/argocd, idle CPU via `vmstat`. |
| REQ-O-002 | MEASURED: `systemctl restart k3s` → node Ready + coredns/traefik/metrics-server available (VM boot excluded; k3s is a systemd unit). |
| REQ-O-003/004/005 | MEASURED: wall-clock of the F-001/F-003/F-004 helm operations. |
| REQ-O-006 | Bring-up fully scripted (`vm-up.sh` → Ansible → `images-import.sh` → `argocd-install.sh`); proven by scratch rebuilds (see `docs/reports/rebuild-*`). |
| REQ-O-007 | Evidence row: the validation run itself is executed by one operator from the runbook. |
| REQ-O-008 | `deploy/` tree in git + Argo CD Application status `Synced` with `selfHeal: true`. |
| REQ-G-001 | `kubectl auth can-i` as an unbound ServiceAccount → `no` for cluster-scoped and cross-namespace reads. |
| REQ-G-002 | Create/delete a marker object; both operations found in `/var/lib/rancher/k3s/server/logs/audit.log`. |
| REQ-G-003 | Generic: deny-egress NetworkPolicy flips a probe pod's connectivity OPEN→CLOSED. In-app: submission pod reaches PostgreSQL (allowed) but not the API server (not allow-listed) — the chart is deny-by-default in both directions. |
| REQ-G-004 | `openssl s_client` against `:6443` presents the auto-provisioned serving certificate. |
| REQ-G-005 | `helm template` renders **0** Secret objects; the three runtime Secrets exist in-cluster (created by `scripts/secrets-bootstrap.sh`); `git grep` finds no credential assignment under `deploy/`. |
| REQ-G-006 | Pod spec with `runAsUser: 0` is rejected at admission by the cluster-wide restricted Pod Security Standard. |
| REQ-G-007 | `deploy/` git history + Argo CD `selfHeal` (out-of-band mutations reverted) + REQ-G-002's audit log. |
| REQ-G-008 | API server `/metrics` (Prometheus format), app `/q/metrics` (micrometer), `kubectl logs` on an app pod. |

## Dispositions worth spelling out

- **Keycloak demo users** (`staff`/`intern` with fixture passwords) are part of
  the checked-in realm import. They are synthetic workload test data — the
  403-path of the demo depends on them — not infrastructure credentials, and
  are therefore out of REQ-G-005's scope. All infrastructure credentials
  (broker, database superuser + per-service logins, Keycloak admin) are
  generated at bootstrap and exist only as in-cluster Secrets.
- **REQ-F-004 and GitOps**: the production deployment path is Argo CD
  (rollback = `git revert` + sync). The catalogue's criterion is exercised
  literally with plain `helm` in a throwaway namespace so that both rollback
  mechanisms are demonstrated without the two fighting over one release.
- **Out-of-scope constraints** (catalogue §5) remain out of scope: the
  workload's Keycloak is an application component, not platform IdP
  federation (API-server OIDC stays unconfigured).
