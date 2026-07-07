# Application pods for the podman kube play platform. __TAG__ is rendered
# by measure/measure-lifecycle.sh (sed) before `podman kube play`; upgrade
# and rollback are `play --replace` of this file with a different tag —
# podman has no rolling-update primitive, so the replacement downtime is
# part of the measured result (protocol Q-02/Q-03).
#
# Env matches measure/compose/docker-compose.yml; DNS names (artemis,
# postgres, keycloak) resolve to the infra pods on measure-net. There is no
# depends_on equivalent: the pods crash-loop (restartPolicy Always) until
# the backing services accept connections, so M-LC-01 measures convergence
# — the same semantic as pod restarts under Kubernetes.
apiVersion: v1
kind: Pod
metadata:
  name: submission-service
  labels:
    app: measure-submission
spec:
  restartPolicy: Always
  containers:
    - name: submission-service
      image: localhost/case-poc/submission-service:__TAG__
      env:
        - name: AMQP_HOST
          value: artemis
        - name: AMQP_PORT
          value: "5672"
        - name: AMQP_USERNAME
          value: artemis
        - name: AMQP_PASSWORD
          value: artemis
        - name: DB_URL
          value: jdbc:postgresql://postgres:5432/case_poc
        - name: DB_USERNAME
          value: submission_service
        - name: DB_PASSWORD
          value: submission_service
        - name: QUARKUS_OTEL_SDK_DISABLED
          value: "true"
      ports:
        - containerPort: 8080
          hostPort: 8080
      resources:
        limits:
          memory: 512Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: management-service
  labels:
    app: measure-management
spec:
  restartPolicy: Always
  containers:
    - name: management-service
      image: localhost/case-poc/management-service:__TAG__
      env:
        - name: AMQP_HOST
          value: artemis
        - name: AMQP_PORT
          value: "5672"
        - name: AMQP_USERNAME
          value: artemis
        - name: AMQP_PASSWORD
          value: artemis
        - name: DB_URL
          value: jdbc:postgresql://postgres:5432/case_poc
        - name: DB_USERNAME
          value: management_service
        - name: DB_PASSWORD
          value: management_service
        - name: QUARKUS_OIDC_AUTH_SERVER_URL
          value: http://keycloak:8080/realms/case-poc
        - name: QUARKUS_OIDC_TOKEN_ISSUER
          value: http://localhost:8180/realms/case-poc
        - name: QUARKUS_OTEL_SDK_DISABLED
          value: "true"
      ports:
        - containerPort: 8081
          hostPort: 8081
      resources:
        limits:
          memory: 512Mi
