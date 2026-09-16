FROM node:22-alpine
WORKDIR /app
COPY --chown=node:node package.json ./
COPY --chown=node:node vendor ./vendor
COPY --chown=node:node src ./src
RUN mkdir -p /app/state && chown node:node /app/state
USER node
ENV HOST=0.0.0.0 PORT=8787
# Public containers must terminate TLS or sit behind a proxy.
# Do not publish port 8787 on the public internet when RELAY_BEHIND_PROXY=1;
# only the TLS proxy should be able to reach this process.
# ENV TLS_CERT_PATH=/certs/fullchain.pem
# ENV TLS_KEY_PATH=/certs/privkey.pem
# ENV RELAY_ORIGIN=https://relay.example.com
# ENV RELAY_BEHIND_PROXY=1
# Trusted LAN only:
# ENV RELAY_ALLOW_CLEARTEXT=1
EXPOSE 8787
CMD ["node", "src/server.mjs"]

