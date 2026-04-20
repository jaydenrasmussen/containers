FROM nginx:alpine
ENV LISTEN_PORT=80
ENV OLD_API_HOST=127.0.0.1
ENV OLD_API_PORT=8080
ENV OLD_API_WEIGHT=50
ENV NEW_API_HOST=127.0.0.1
ENV NEW_API_PORT=8081
ENV NEW_API_WEIGHT=50
ENV RESOLVER_ADDRESS=169.254.169.253
COPY nginx.conf.template /nginx.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
