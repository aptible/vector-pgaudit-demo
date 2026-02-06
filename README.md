# Vector Log Aggregation for Aptible

A containerized Vector deployment that ingests logs from Aptible's HTTPS log drains, merges multi-line PostgreSQL audit logs, and forwards them to Datadog.

## Overview

This solution addresses a common issue where PostgreSQL audit logs (`pgaudit`) are split across multiple log lines due to embedded newlines in SQL queries. Vector intelligently merges these fragmented logs into complete entries before forwarding them to Datadog.

### Features

- **HTTPS Log Ingestion**: Receives logs from Aptible's HTTPS log drains
- **Multi-line Log Merging**: Automatically combines fragmented PostgreSQL audit logs
- **Datadog Integration**: Forwards processed logs to Datadog with structured metadata
- **Environment-based Configuration**: All sensitive values configured via environment variables

## Architecture

```
Aptible HTTPS Log Drain → Vector HTTP Server → Multi-line Merge → Datadog Logs
```

## Quick Start

### Prerequisites

- Docker
- Aptible CLI installed and configured
- Aptible account with HTTPS log drain configured
- Datadog account with API key

### Deployment Steps

1. **Clone or download this repository**

2. **Create an Aptible app**:
   ```bash
   aptible apps:create your-app-name
   ```
   Note the Git Remote URL provided (referred to as `$GIT_URL` below). You can also find this URL in the app header in the [Aptible Dashboard](https://www.aptible.com/docs/how-to-guides/app-guides/deploy-from-git) under "Git Remote".

3. **Set required environment variables**:
   ```bash
   aptible config:set DD_API_KEY=your-datadog-api-key --app your-app-name
   ```

4. **Add Git remote and deploy**:
   ```bash
   git add Dockerfile
   git commit -m "Add Dockerfile"
   git remote add aptible "$GIT_URL"
   git push aptible master
   ```

5. **Configure HTTPS log drain**:
   ```bash
   aptible log_drain:create:https \
     --app your-app-name \
     --url https://your-vector-app.on-aptible.com
   ```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DD_API_KEY` | Yes | - | Datadog API key for log ingestion |
| `DD_SITE` | No | `datadoghq.com` | Datadog site (e.g., `us3.datadoghq.com`, `eu.datadoghq.com`) |
| `VECTOR_PORT` | No | `8080` | HTTP port for Vector to listen on |

### Example Configuration

```bash
aptible config:set \
  DD_API_KEY=your-api-key \
  DD_SITE=us3.datadoghq.com \
  VECTOR_PORT=8080 \
  --app your-app-name
```

## How It Works

### Log Processing Pipeline

1. **Ingestion**: Vector receives JSON logs via HTTP POST from Aptible
2. **Classification**: Logs are classified as:
   - **AUDIT logs**: Multi-line PostgreSQL audit entries (start with `LOG:  AUDIT:`)
   - **Regular logs**: Standard PostgreSQL logs (checkpoints, etc.)
3. **Merging**: AUDIT logs are merged using Vector's `reduce` transform:
   - Detects AUDIT log start (`LOG:  AUDIT:` pattern)
   - Accumulates continuation lines (starting with tab characters)
   - Completes merge when `<not logged>` marker is found
4. **Enrichment**: Extracts AUDIT metadata (statement ID, command type, etc.)
5. **Forwarding**: Sends merged logs to Datadog with structured fields

### Log Format Examples

**Input (fragmented)**:
```json
{"log":"2026-02-05 17:42:00 UTC LOG:  AUDIT: SESSION,1,1,READ,SELECT,,,\"SELECT COUNT(*) \n","stream":"stderr","time":"..."}
{"log":"\t    AS total_events \n","stream":"stderr","time":"..."}
{"log":"\t    FROM fake_events\",<not logged>\n","stream":"stderr","time":"..."}
```

**Output (merged)**:
```json
{
  "log": "2026-02-05 17:42:00 UTC LOG:  AUDIT: SESSION,1,1,READ,SELECT,,,\"SELECT COUNT(*) \n\t    AS total_events \n\t    FROM fake_events\",<not logged>\n",
  "log_type": "pgaudit",
  "audit": {
    "timestamp": "2026-02-05 17:42:00 UTC",
    "audit_class": "SESSION",
    "class": "READ",
    "command": "SELECT",
    "statement_id": "1",
    "substatement_id": "1"
  }
}
```

## Testing

### Local Testing

1. **Build and run locally**:
   ```bash
   docker build -t vector-test:local .
   docker run -d --name vector-test \
     -p 8080:8080 \
     -e DD_API_KEY=test-key-12345 \
     vector-test:local
   ```

2. **Test with sample logs**:
   ```bash
   
   # Regular log
   curl -X POST http://localhost:8080 \
     -H "Content-Type: application/json" \
     -d '{"log":"2026-02-05 17:23:20 UTC LOG:  checkpoint complete\n","stream":"stderr","time":"2026-02-05T17:23:20Z"}'
   
   # Multi-line AUDIT log (submit all 3 parts in quick succession)
   # Part 1: AUDIT start line
   curl -X POST http://localhost:8080 \
     -H "Content-Type: application/json" \
     -d '{"log":"2026-02-05 17:42:00 UTC LOG:  AUDIT: SESSION,1,1,READ,SELECT,,,\"SELECT COUNT(*) \n","stream":"stderr","time":"2026-02-05T17:42:00Z"}'
   
   # Part 2: Continuation line
   curl -X POST http://localhost:8080 \
     -H "Content-Type: application/json" \
     -d '{"log":"\t    AS total_events \n","stream":"stderr","time":"2026-02-05T17:42:00Z"}'
   
   # Part 3: End line with <not logged>
   curl -X POST http://localhost:8080 \
     -H "Content-Type: application/json" \
     -d '{"log":"\t    FROM fake_events\",<not logged>\n","stream":"stderr","time":"2026-02-05T17:42:00Z"}'
   ```

3. **View logs**:
   ```bash
   docker logs vector-test
   ```

## Troubleshooting

### Health Check Failures

If you see `MethodNotAllowed` errors, ensure the Vector configuration doesn't restrict HTTP methods. The current configuration accepts both GET (health checks) and POST (logs).

### Logs Not Appearing in Datadog

1. **Verify API key**: Check that `DD_API_KEY` is set correctly
2. **Check Datadog site**: Ensure `DD_SITE` matches your Datadog region
3. **Review Vector logs**: Check container logs for Datadog connection errors
4. **Verify log drain**: Confirm Aptible log drain is configured and sending logs

### Multi-line Logs Not Merging

- Ensure logs follow the expected format:
  - AUDIT logs start with `LOG:  AUDIT:`
  - Continuation lines start with tab characters
  - AUDIT entries end with `<not logged>`
- Check that related log fragments have similar timestamps (within the merge window)

## Performance Considerations

- **Single Container**: This solution is designed for single-container deployment. Vector's `reduce` transform maintains state in memory. Scale to a single larger container as needed.
- **Throughput**: A single Vector instance can handle 10,000+ events/second easily
- **Memory**: Monitor container memory usage if processing very high volumes
- **Batch Settings**: Adjust `batch.max_events` and `batch.timeout_secs` in `vector.yaml` if needed

## File Structure

```
.
├── Dockerfile              # Container definition
├── vector.yaml            # Vector configuration
├── .dockerignore          # Docker build exclusions
├── test_commands.sh      # Test script
├── README.md             # This file
└── LICENSE.md            # License file
```

## Support

For issues related to:
- **Vector configuration**: See [Vector Documentation](https://vector.dev/docs/)
- **Aptible deployment**: See [Aptible Documentation](https://www.aptible.com/docs)
- **Datadog integration**: See [Datadog Logs Documentation](https://docs.datadoghq.com/logs/)

## License

See [LICENSE.md](LICENSE.md) for license information.
