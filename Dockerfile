FROM timberio/vector:latest-debian

# Copy Vector configuration file
COPY vector.yaml /etc/vector/vector.yaml

# Expose the HTTP port (default 8080, configurable via VECTOR_PORT env var)
EXPOSE 8080

# Run Vector with the configuration file
CMD ["vector", "--config", "/etc/vector/vector.yaml"]
