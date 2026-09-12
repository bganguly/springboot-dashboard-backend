FROM eclipse-temurin:21-jdk-alpine@sha256:dfb58f010fc58c48069b670a924b8f08a99672932d37ec8c7e839a52c7e3226c AS builder
ARG BUILD_DATE=unknown
WORKDIR /app
COPY gradlew gradlew.bat* ./
COPY gradle/ gradle/
COPY build.gradle.kts settings.gradle.kts ./
RUN ./gradlew dependencies --no-daemon -q > /tmp/gradle-deps.log 2>&1 \
    && printf "Gradle deps resolved (%d lines)\n" "$(wc -l < /tmp/gradle-deps.log)" \
    || { cat /tmp/gradle-deps.log; exit 1; }
COPY src/ src/
RUN ./gradlew bootJar --no-daemon -q

FROM eclipse-temurin:21-jre-alpine@sha256:4cbffea0432e0209a002c816a9fad6557d83147e56d5df6a73cdeec3c03ea522 AS runner
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app && apk add --no-cache netcat-openbsd
COPY --from=builder /app/build/libs/*.jar app.jar
COPY docker-entrypoint.sh entrypoint.sh
RUN chmod +x entrypoint.sh
USER app
EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
