# --- build stage ---
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B dependency:go-offline
COPY src ./src
RUN mvn -B clean package -DskipTests

# --- runtime stage ---
FROM eclipse-temurin:21-jre-alpine
# Picks up patched OS packages (e.g. libexpat, p11-kit CVEs) even if the
# upstream base image tag hasn't republished with them yet. Cheap, and this
# is exactly the kind of drift Trivy's scan is meant to catch.
RUN apk update && apk upgrade --no-cache
RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
COPY --from=build /build/target/*.jar app.jar
USER app
EXPOSE 8080 8081
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
