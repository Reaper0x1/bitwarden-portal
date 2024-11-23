# Use a Node.js base image
FROM alpine:latest

# Set working directory
WORKDIR /app

# Install required packages
RUN apk --no-cache add python3 curl bash ca-certificates openssl ncurses coreutils make gcc g++ libgcc linux-headers grep util-linux binutils findutils uuidgen nodejs npm wget unzip tar openssl jq bash

# Install Bitwarden CLI
RUN npm install -g @bitwarden/cli@2024.6.0

# Define a default cron schedule
ENV CRON_SCHEDULE="57 23 * * *"

# Create a cron job file with the defined schedule
RUN echo "$CRON_SCHEDULE root /app/backup.sh > /var/log/cron.log 2>&1" > /etc/crontabs/root

# Copy your script and encryption files to the container
COPY ./script.sh /app/backup.sh

COPY ./certs/* /usr/local/share/ca-certificates/
COPY ./certs/* /usr/share/ca-certificates/

RUN update-ca-certificates

#RUN cat /usr/local/share/ca-certificates/metaserver.local.crt >> /etc/ssl/certs/ca-certificates.crt && \
#    apk --no-cache add \
#    curl

# Make your script executable
RUN chmod +x /app/backup.sh

# Start cron and log output to console
#CMD ["sh", "-c", "echo \"$CRON_SCHEDULE /app/backup.sh > /proc/1/fd/1 2>&1\" > /etc/crontabs/root && crond -f -L /dev/stdout"]
CMD ["bash", "-c", "/app/backup.sh"]