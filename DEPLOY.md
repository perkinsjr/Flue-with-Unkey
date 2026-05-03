# Deploy Agents on Unkey Deploy

Build Flue agents as a Node.js server and ship them to [Unkey Deploy](https://unkey.com/docs/build-and-deploy/overview) — Unkey's container platform with multi-region routing, automatic domains, instant rollbacks, and security via Sentinel. This guide walks you through preparing a Flue project for Unkey Deploy, writing the Dockerfile Unkey expects, and shipping with either GitHub or the `unkey` CLI.

This guide assumes you've worked through [Deploy Agents on Node.js](https://github.com/withastro/flue/blob/main/docs/deploy-node.md) — the agent code, sandboxes, roles, skills, and commands all work identically. What changes here is the surrounding container and deploy story.

## Why Unkey Deploy

Flue's Node.js target produces a plain Hono server. That means it runs anywhere Node runs, but Unkey Deploy gives you a few things you'd otherwise wire up by hand:

- **Multi-region** — your agent runs in every region you select, with traffic routed to the nearest healthy instance.
- **Sentinel** — drop in API key auth, rate limiting, and IP rules in front of `/agents/*` without touching your agent code.
- **Preview environments per branch** — every PR gets its own URL, so you can test agent changes against real traffic before promoting.
- **Instant rollbacks** — previous deployments stay warm; reverting is one click, no rebuild.

## Project layout

The repo in this directory is a working example. The shape:

```
.
├── .flue/
│   ├── agents/          # one file per webhook endpoint
│   │   ├── translate.ts
│   │   ├── summarize.ts
│   │   └── analyze.ts
│   ├── roles/
│   │   └── analyst.md
│   └── skills/
│       └── summarize/
│           └── SKILL.md
├── Dockerfile           # multi-stage: build → strip dev deps → runtime
├── .dockerignore
├── package.json
├── tsconfig.json
└── .env.example
```

If you already have a Flue project at the repo root (agents in `./agents/`), nothing changes — the Dockerfile copies the workspace directory you tell it to. The `.flue/` prefix is the convention this example uses.

## Hello World

A complete agent file — same shape you'd write for any Node deploy.

`.flue/agents/translate.ts`:

```typescript
import type { FlueContext } from '@flue/sdk/client';
import * as v from 'valibot';

export const triggers = { webhook: true };

export default async function ({ init, payload }: FlueContext) {
  const agent = await init({ model: 'openai/gpt-5.5' });
  const session = await agent.session();

  return await session.prompt(
    `Translate this to ${payload.language}: "${payload.text}"`,
    {
      result: v.object({
        translation: v.string(),
        confidence: v.picklist(['low', 'medium', 'high']),
      }),
    },
  );
}
```

Webhook agents are exposed at `/agents/<name>/<id>`. After deploy, this one is reachable at `https://<your-app>.unkey.app/agents/translate/<any-id>`.

## The Dockerfile

This is the file that matters most for Unkey Deploy. Unkey doesn't auto-detect runtimes or run buildpacks — it builds whatever Dockerfile you give it. Flue's Node target needs a multi-stage build because `flue build` externalizes your dependencies rather than bundling them, so the runtime image still needs `node_modules`.

```dockerfile
# syntax=docker/dockerfile:1.7

# ─── Build stage ─────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci

COPY tsconfig.json ./
COPY .flue ./.flue
RUN npx flue build --target node

RUN npm prune --omit=dev

# ─── Runtime stage ───────────────────────────────────────────────────────────
FROM node:22-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/.flue ./.flue
COPY package.json ./

USER node
EXPOSE 8080

CMD ["node", "dist/server.mjs"]
```

A few details that matter on Unkey:

- **Listen on `PORT`.** Unkey injects `PORT=8080` at runtime. Flue's built server already reads `process.env.PORT`, so you don't need to do anything — just don't override it.
- **Exec-form `CMD`.** Unkey sends `SIGTERM` for graceful shutdown. Exec form makes Node PID 1, so it actually receives the signal instead of a shell swallowing it.
- **Pinned base image.** `node:22-alpine` rather than `node:latest` — keeps builds reproducible and the image small.
- **Non-root user.** `USER node` is cheap defense in depth.
- **`.flue/` is copied into the runtime stage.** The agent reads roles, skills, and `AGENTS.md` from disk at request time; they aren't baked into `dist/`.

## Environment variables

Provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) and any other secrets your agents read are configured per-environment in the Unkey dashboard, then injected into the container at runtime. Locally, use `.env`:

```bash
cp .env.example .env
# fill in OPENAI_API_KEY=... etc.
```

For production, set them in **Project → App → Environment → Variables** in the Unkey dashboard.

### Build-time secrets

If your build needs a secret (private npm registry token, codegen against a real DB URL), Unkey mounts environment variables as a `.env` file at `/run/secrets/.env` during build. The Flue build doesn't normally need anything sensitive, but if yours does:

```dockerfile
ARG UNKEY_SECRETS_ID

RUN --mount=type=secret,id=${UNKEY_SECRETS_ID},target=/run/secrets/.env \
    set -a && . /run/secrets/.env && set +a && \
    npx flue build --target node
```

Declare `ARG UNKEY_SECRETS_ID` in every stage that mounts the secret — `ARG` values don't carry across stages. Don't pass secrets via plain `ARG` or `ENV` — they leak into `docker history` and the final image.

## Running locally

The container should run identically to your laptop:

```bash
npm install
npm run dev
# → flue dev --target node --env .env, on :3583
```

To test the production image end-to-end before pushing:

```bash
docker build -t unkey-flue .
docker run --rm -p 8080:8080 \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  unkey-flue

curl http://localhost:8080/health
curl http://localhost:8080/agents/translate/test-1 \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello world","language":"French"}'
```

## Deploying

Unkey Deploy gives you two paths. Pick one based on whether you want pushes to deploy automatically or want to drive deploys from CI yourself.

### Option A — GitHub integration

The fastest path. Connect the repo once and every push deploys.

1. **Create a project.** In the Unkey dashboard, click **New project** and pick a slug.
2. **Connect the repo.** Authorize the Unkey GitHub app, pick this repo.
3. **Confirm build settings.** Root directory `.`, Dockerfile `Dockerfile`, port `8080`. The defaults match what's in this guide.
4. **Add provider keys.** Under **Environment → Variables**, add `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and anything else your agents need.
5. **Push.** Push to your default branch and Unkey builds and deploys.

After the first push, the branch mapping is automatic:

| Branch | Environment | Domain |
| --- | --- | --- |
| Default branch (`main`) | Production | `<project>-<app>.unkey.app` |
| Any other branch | Preview | `<project>-<app>-git-<branch>.unkey.app` |

Each deploy also gets an immutable per-commit URL so you can pin a specific build. Pull requests from forks don't deploy automatically — a team member has to approve them.

### Option B — CLI

Useful if you build images in your own CI and just want Unkey to host them, or if you're not ready to give the Unkey GitHub app repo access.

```bash
unkey auth login

# Build and push to any registry you control.
docker build -t ghcr.io/your-org/unkey-flue:$(git rev-parse --short HEAD) .
docker push ghcr.io/your-org/unkey-flue:$(git rev-parse --short HEAD)

# Deploy.
unkey deploy ghcr.io/your-org/unkey-flue:$(git rev-parse --short HEAD) \
  --project=unkey-flue \
  --env=production
```

Or, with environment variables:

```bash
export UNKEY_ROOT_KEY=unkey_xxx
export UNKEY_PROJECT=unkey-flue
unkey deploy ghcr.io/your-org/unkey-flue:abc1234 --env=production
```

For monorepos with multiple deployable services in one project, add `--app=<slug>`. With a single app, the default `default` slug is fine.

### GitHub Actions

If you'd rather build in your own CI and have Unkey just host, the [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) in this repo shows the pattern: build → push to GHCR → `unkey deploy`.

## Sandbox strategy on Unkey Deploy

The Node.js sandbox progression carries over, but a couple of trade-offs change inside a managed container.

**Virtual sandbox** (`init({ model })` with no `sandbox` option) is the default and the right starting point. Each session gets an empty sandbox backed by [just-bash](https://github.com/vercel-labs/just-bash) — no container startup, fully isolated. This is what `translate.ts` and `summarize.ts` use.

**Local sandbox** (`init({ sandbox: 'local' })`) mounts the container's `process.cwd()` (which is `/app`) into the agent. This is fine if you want the agent to read your shipped roles, skills, and `AGENTS.md`, but remember: every session shares that filesystem. On Unkey Deploy each container instance also handles many concurrent requests, so don't use `'local'` for anything where one user's session shouldn't see another's writes. Prefer it for read-only workflows like static analysis against the bundled workspace.

**Remote sandbox** (Daytona, Cloudflare Sandboxes, etc.) is the right answer for multi-tenant agents that need a fresh isolated Linux environment per request. Costs more per session but gives you proper isolation. Add the connector with `flue add daytona`, then use it as shown in the Node.js guide. If you need credentials inside the remote sandbox, prefer a provider with egress proxy support — Cloudflare Sandboxes have this; Daytona currently doesn't.

The summary table:

| Sandbox | Startup | Isolation | Use on Unkey for |
| --- | --- | --- | --- |
| Virtual (default) | Milliseconds | Per-session | Stateless prompt → response agents |
| Local | Milliseconds | None — shared `/app` | Read-only access to bundled context |
| Remote (Daytona, etc.) | Seconds | Full per-session | Multi-tenant sandboxed code execution |

## Putting Sentinel in front of your agents

Sentinel runs before requests reach your container. The pattern that fits Flue best is to gate `/agents/*` behind Unkey API keys so callers need a valid key to invoke an agent — and you get rate limits, IP rules, and per-key analytics for free.

Configure Sentinel under **App → Sentinel** in the dashboard. The agent code stays unchanged — the auth check happens before your Node process sees the request, so a bad key never spends an LLM token.

If you'd rather authenticate inside the agent (custom logic, header-derived tenancy), do it there and leave Sentinel disabled — the two aren't mutually exclusive but Sentinel is the cheaper option for simple key-based gating.

## Health checks

Configure a GET health check against `/health` (which Flue's built server exposes by default) under **App → Settings → Health checks**. With the defaults — 30s interval, 5s timeout, 3 failure threshold — Unkey will mark an instance unhealthy and stop routing traffic to it within ~90 seconds of a real outage.

## Regions and resources

Pick regions under **App → Settings → Regions**. Pick the regions closest to where your agents' traffic originates — LLM latency dominates total response time, but the round trip from your container still adds up.

For resources, the defaults (1/4 vCPU, 256 MiB) are fine for prompt-and-response agents that mostly wait on the model. Bump CPU and memory if you're using the local sandbox heavily, doing post-processing, or running the agent against large payloads. The beta caps are 2 vCPU, 4 GiB, and 4 instances per region.

## Troubleshooting

**"Container exited immediately."** Check that your `CMD` is exec-form (`CMD ["node", "dist/server.mjs"]`, not `CMD node dist/server.mjs`). Shell-form prevents Node from receiving `SIGTERM` and also breaks some healthcheck timing.

**"Build succeeds but agent calls fail with 'no model configured'."** Provider env var (`OPENAI_API_KEY`, etc.) isn't set in the Unkey environment. Check **Environment → Variables**, redeploy, and confirm with `curl https://your-app.unkey.app/health` first to make sure the container is actually running.

**"Build context too large."** Add to `.dockerignore`. The included `.dockerignore` already excludes `node_modules`, `dist`, `.git`, and env files.

**"Agent works locally but not in production."** If your agent uses the local sandbox, confirm `.flue/` is being copied into the runtime stage of your Dockerfile (it is in this example). The bundled `dist/server.mjs` doesn't include roles, skills, or `AGENTS.md` — those are read from disk at request time.

## What's next

- Add more agents under `.flue/agents/`. Each file with `triggers = { webhook: true }` becomes its own endpoint automatically.
- Wire up session persistence (Postgres, Redis) via the `persist` option on `init()` so sessions survive container restarts.
- Drop in Sentinel for auth and rate limiting.
- Add a custom domain under **App → Settings → Domains** once you're past preview.
