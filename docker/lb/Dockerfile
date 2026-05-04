FROM eclipse-temurin:25-jre-noble
RUN groupadd -r xenticate && useradd -r -g xenticate xenticate
WORKDIR /app
COPY thales-transparent-lb.jar app.jar
RUN mkdir -p /var/log/xenticate && chown xenticate:xenticate /var/log/xenticate
USER xenticate
EXPOSE 8110
ENTRYPOINT ["java", \
  "-Xms256m", "-Xmx512m", \
  "-Djava.awt.headless=true", \
  "-jar", "/app/app.jar", \
  "--spring.config.location=/config/application.properties"]
