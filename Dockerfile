# syntax=docker/dockerfile:1.7

# ─── Build stage ─────────────────────────────────────────────────────────────
FROM node:22-alpine AS builder
WORKDIR /app

# Install all deps (including @flue/cli devDep) with cache-friendly ordering.
COPY package.json package-lock.json* ./
RUN npm ci

# Compile the workspace into ./dist.
COPY tsconfig.json ./
COPY .flue ./.flue
RUN npx flue build --target node

# Strip dev dependencies for the runtime image.
RUN npm prune --omit=dev

# ─── Runtime stage ───────────────────────────────────────────────────────────
FROM node:22-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/.flue ./.flue
COPY package.json ./

# Drop root. Unkey injects PORT at runtime; the Flue server reads it directly.
USER node
EXPOSE 8080

CMD ["node", "dist/server.mjs"]
