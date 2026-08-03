FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ./
RUN mkdir -p /data
ENV CONFIG_PATH=/data/config.json DEVICE_STORE_PATH=/data/devices.json PORT=8787
EXPOSE 8787
CMD ["node", "server.js"]
