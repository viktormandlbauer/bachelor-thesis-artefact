# Multi-stage build: compiles inside the image so `docker compose up --build` works
# without a host JDK/Maven. Tests are skipped here; they need Docker (Dev Services)
# and run on the host via `mvn test`.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
COPY src src
RUN --mount=type=cache,target=/root/.m2 mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/target/quarkus-app/ /app/
EXPOSE 8081
USER 1001
ENTRYPOINT ["java", "-jar", "/app/quarkus-run.jar"]
