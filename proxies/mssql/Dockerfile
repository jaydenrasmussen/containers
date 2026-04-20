FROM nginx:alpine
ENV LISTEN_PORT=1433
ENV UPSTREAM_HOST=127.0.0.1
ENV UPSTREAM_PORT=1433
ENV RESOLVER_ADDRESS=169.254.169.253
COPY nginx.conf.template /nginx.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
