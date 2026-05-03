# unkey-flue

Example [Flue](https://flue.dev) agent server, deployable to [Unkey Deploy](https://unkey.com/docs/build-and-deploy/overview).

Three working agents:

- `translate` — virtual sandbox, structured output via Valibot.
- `summarize` — virtual sandbox, uses a skill defined in `.flue/skills/`.
- `analyze` — virtual sandbox, uses a role defined in `.flue/roles/`.

## Quickstart

```bash
npm install
cp .env.example .env  # add OPENAI_API_KEY, ANTHROPIC_API_KEY
npm run dev
```

Then:

```bash
curl http://localhost:3583/agents/translate/test-1 \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello world","language":"French"}'
```

## Deploy

See [DEPLOY.md](DEPLOY.md) for the full guide. Short version:

```bash
docker build -t ghcr.io/your-org/unkey-flue:$(git rev-parse --short HEAD) .
docker push ghcr.io/your-org/unkey-flue:$(git rev-parse --short HEAD)
unkey deploy ghcr.io/your-org/unkey-flue:$(git rev-parse --short HEAD) \
  --project=unkey-flue --env=production
```

Or connect the repo via the Unkey dashboard and push to `main`.

## Layout

```
.flue/
  agents/      # one file per webhook endpoint
  roles/       # markdown role definitions
  skills/      # reusable agent tasks
Dockerfile     # multi-stage build for Unkey Deploy
.dockerignore
DEPLOY.md      # deployment guide
```
