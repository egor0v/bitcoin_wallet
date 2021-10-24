FROM ruby:2.7-alpine
RUN apk add --no-cache g++ gcc make musl-dev && gem install eventmachine
RUN mkdir /usr/src/wallet
ADD . /usr/src/wallet/
WORKDIR /usr/src/wallet/
RUN bundle install