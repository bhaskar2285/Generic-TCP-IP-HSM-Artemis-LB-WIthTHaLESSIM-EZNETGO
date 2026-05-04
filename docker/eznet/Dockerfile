FROM eclipse-temurin:25-jre-noble
RUN groupadd -r xenticate && useradd -r -g xenticate xenticate
RUN mkdir -p /eznet/config /eznet/tmp /var/log/xenticate && chown -R xenticate:xenticate /eznet /var/log/xenticate
WORKDIR /eznet
COPY eznet-tcp2jms.war /app/app.war
USER xenticate
EXPOSE 9100
ENTRYPOINT ["java", \
  "-Xms128m", "-Xmx384m", \
  "-Djava.awt.headless=true", \
  "-Dsun.net.http.allowRestrictedHeaders=true", \
  "-Djava.io.tmpdir=/eznet/tmp", \
  "-Deznet.root=/eznet", \
  "-Deznet.config.path=/eznet/config", \
  "-Deznet.log.path=/var/log/xenticate", \
  "-jar", "/app/app.war"]
