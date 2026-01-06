FROM ruby:3.4.7-slim-bookworm

RUN apt update && apt --fix-missing install -y build-essential libssl-dev libyaml-dev wget pkg-config libclang-dev \
     && rm -rf /var/lib/apt/lists/*

RUN wget -O- https://sh.rustup.rs | sh -s -- -y

ENV PATH="/root/.cargo/bin:${PATH}"

RUN rustup default stable

WORKDIR /app

COPY Gemfile Gemfile.lock /app/

RUN bundle install --jobs $(nproc) --retry=3 \
     && bundle clean --force

COPY . /app

ENV RUBY_YJIT_ENABLE=1

CMD ["ruby", "bot.rb"]