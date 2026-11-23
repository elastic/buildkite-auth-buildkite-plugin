FROM buildkite/plugin-tester:v4.3.0

RUN adduser --disabled-password --gecos "" plugin-tester
USER plugin-tester
