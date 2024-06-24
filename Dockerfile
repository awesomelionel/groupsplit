# Use the official Ruby image as the base
FROM ruby:3.0-slim

RUN apt-get update && apt-get install -y \
    build-essential \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install production dependencies.
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle install

# Copy local code to the container image.
COPY . .

# Expose port 4567 to the outside world
EXPOSE 8080

# Run the web service on container startup.
CMD ["ruby", "./main.rb"]