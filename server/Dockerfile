FROM ruby:4.0-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential chromium imagemagick fonts-dejavu-core tzdata \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY app.rb dash.erb ./
CMD ["ruby", "app.rb"]
