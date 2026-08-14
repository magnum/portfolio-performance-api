FROM ruby:3.4-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends build-essential libxml2-dev libxslt1-dev \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
ENV BUNDLE_WITHOUT=test
RUN bundle install

COPY . .

EXPOSE 9292
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
