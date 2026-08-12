# Metrics Methodology — Proving Work with Numbers

ibis ledger provides durable, git-tracked measurements. This doc explains
how to set up a metric-driven workflow.

## Why measure

AI agents declare "fixed" without proof. Human developers do too. A
measurement recorded in the ledger survives context resets — the next
session reads the trend, not a claim.

## The ledger

```bash
ibis ledger api-gateway 99.2 "uptime after retry fix"
ibis ledger api-gateway 98.7 "dipped after deploy"
ibis ledger api-gateway 99.8 "stable after rollback"
```

Each entry records: date, value, commit hash, note. The file lives at
`.ibis/ledger/<node>.tsv`, git-tracked.

View the trend:
```bash
ibis ledger api-gateway
```

## Setting up a metric-driven node

### 1. Choose what to measure

Pick a number that proves the node is healthy:
- **Uptime/availability** — percentage of successful health checks
- **Error rate** — percentage of requests that fail
- **Latency** — p50/p95/p99 response time
- **Coverage** — percentage of tests passing, code coverage
- **Throughput** — requests/sec, items/min processed

### 2. Automate the measurement

Write a script that produces the number:

```bash
#!/usr/bin/env bash
# measure-api-uptime.sh
total=$(grep -c 'api-gateway' /var/log/checks.log)
pass=$(grep -c 'PASS.*api-gateway' /var/log/checks.log)
echo "scale=1; $pass * 100 / $total" | bc
```

### 3. Wire it into the node's check=

The health check can record to the ledger:

```dot
apiGateway [
  check="bash measure-api-uptime.sh",
  doc=".ibis/docs/api-gateway.md",
  test="tests/ibis/api-gateway.sh"
];
```

### 4. Record at key moments

- After every fix: `ibis ledger <node> <value> "after <what you did>"`
- After every deploy: record the baseline
- After every incident: record the recovery

### 5. Use the trend as proof

When claiming work is "done":
- Show the before/after: "error rate 12% → 0.3% over 5 measurements"
- The ledger is in git — anyone can verify the history
- Link to the ledger in PRIORITIES.md when closing a priority

## Anti-patterns

- **Measuring once** — a single "it works" is not a trend
- **Measuring the container, not the data** — "container Up (healthy)" is
  not the same as "API returning correct results"
- **Unmeasured claims** — "fixed" without a number is a guess

## Integration with CI

Add to your CI pipeline:
```yaml
- run: |
    value=$(bash measure-api-uptime.sh)
    ibis ledger api-gateway "$value" "CI measurement"
    if [ "$(echo "$value < 95" | bc)" -eq 1 ]; then
      echo "FAIL: uptime below 95%"
      exit 1
    fi
```
