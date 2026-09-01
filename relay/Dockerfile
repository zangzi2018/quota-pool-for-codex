FROM node:22-alpine
WORKDIR /app
COPY package.json ./
COPY vendor ./vendor
COPY src ./src
ENV HOST=0.0.0.0 PORT=8787
# Public containers must terminate TLS or sit behind a proxy:
# ENV TLS_CERT_PATH=/certs/fullchain.pem
# ENV TLS_KEY_PATH=/certs/privkey.pem
# ENV RELAY_ORIGIN=https://relay.example.com
# ENV RELAY_BEHIND_PROXY=1
# Trusted LAN only:
# ENV RELAY_ALLOW_CLEARTEXT=1
EXPOSE 8787
CMD ["node", "src/server.mjs"]

