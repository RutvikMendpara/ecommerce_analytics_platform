FROM quay.io/debezium/connect:3.2.0.Final

ARG S3_SINK_VERSION=10.6.7
RUN curl -sSL -o /tmp/s3.zip \
      https://hub-downloads.confluent.io/api/plugins/confluentinc/kafka-connect-s3/versions/${S3_SINK_VERSION}/confluentinc-kafka-connect-s3-${S3_SINK_VERSION}.zip \
    && unzip -q /tmp/s3.zip -d /kafka/connect \
    && rm /tmp/s3.zip

COPY --chown=kafka:kafka postgres-source.json s3-sink.json register.sh /kafka/connectors/

ENTRYPOINT ["/kafka/connectors/register.sh"]
