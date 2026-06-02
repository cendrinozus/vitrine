FROM nginx:alpine

COPY vitrine.html /usr/share/nginx/html/index.html
COPY img/ /usr/share/nginx/html/img/

EXPOSE 80 443
